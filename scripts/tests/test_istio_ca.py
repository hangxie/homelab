#!/usr/bin/env python3
"""Exercise the real CA scripts/OpenSSL against isolated Vault/Kubernetes fakes."""

import json
import hashlib
import ssl
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SCRIPTS = Path(__file__).resolve().parents[1]
TEMPLATE = """secrets:
  - path: istio/ca
    generator: istio-ca
    fields: [ca-cert.pem, ca-key.pem, root-cert.pem, cert-chain.pem]
  - path: redis/default
    fields: [password]
"""

FAKE = r'''#!/usr/bin/env python3
import base64, json, os, sys
from pathlib import Path
args = sys.argv[1:]
state = Path(os.environ['CA_TEST_STATE'])
db = json.loads(state.read_text()) if state.exists() else {}
events = Path(os.environ['CA_TEST_EVENTS'])
def event(text):
    with events.open('a') as f: f.write(text + '\n')
def save(): state.write_text(json.dumps(db))
def option(name, default=None):
    return next((a.split('=', 1)[1] for a in args if a.startswith(name + '=')), default)
if Path(sys.argv[0]).name == 'vault':
    if args[:2] == ['secrets', 'list']:
        print('{"homelab/": {}}'); sys.exit()
    if args[:2] == ['auth', 'list']:
        print('{"approle/": {}}'); sys.exit()
    if args[0] in ('policy', 'write'): sys.exit()
    if args[:3] == ['kv', 'metadata', 'get']:
        if os.environ.get('CA_TEST_VAULT_ERROR'):
            print('Error: 403 permission denied', file=sys.stderr); sys.exit(2)
        path = args[-1].removeprefix('homelab/')
        if path not in db:
            print('No value found at homelab/metadata/istio/ca', file=sys.stderr); sys.exit(2)
        print(json.dumps({'data': {'current_version': db[path]['version']}})); sys.exit()
    if args[:2] == ['kv', 'get']:
        path = args[-1].removeprefix('homelab/')
        if path not in db or os.environ.get('CA_TEST_DELETED'):
            print('No value found at homelab/data/' + path, file=sys.stderr); sys.exit(2)
        field = option('-field')
        if field:
            print(db[path]['data'].get(field, ''), end='')
        else:
            print(json.dumps({'data': {'metadata': {'version': db[path]['version']}, 'data': db[path]['data']}}))
        sys.exit()
    if args[:2] == ['kv', 'put']:
        path_index = next(i for i in range(2, len(args)) if not args[i].startswith('-'))
        path = args[path_index].removeprefix('homelab/')
        version = db.get(path, {}).get('version', 0)
        cas = option('-cas')
        conflict = os.environ.get('CA_TEST_CAS_FAIL') or (path == 'istio/ca' and os.environ.get('CA_TEST_SIGNING_CAS_FAIL'))
        if cas is not None and (int(cas) != version or conflict):
            print('check-and-set parameter did not match current version', file=sys.stderr); sys.exit(2)
        data = {}
        for item in args[path_index + 1:]:
            key, value = item.split('=', 1)
            data[key] = Path(value[1:]).read_text() if value.startswith('@') else value
        db[path] = {'version': version + 1, 'data': data}; save(); event('write ' + path)
        print('Success'); sys.exit()
    raise SystemExit('unexpected fake Vault command: ' + repr(args))
if args[0] == 'version': print('{}'); sys.exit()
if args[:2] == ['config', 'current-context']: print('isolated-test'); sys.exit()
if 'get' in args:
    resource = args[args.index('get') + 1]
    if resource == 'namespaces,pods':
        enrolled = os.environ.get('CA_TEST_ENROLLED')
        items = []
        if enrolled == '1':
            items = [{'kind': 'Namespace', 'metadata': {'name': 'app', 'labels': {'istio.io/dataplane-mode': 'ambient'}}}]
        elif enrolled in ('sidecar', 'native-sidecar'):
            containers = 'initContainers' if enrolled == 'native-sidecar' else 'containers'
            items = [{'kind': 'Pod', 'metadata': {'namespace': 'app'}, 'spec': {containers: [{'name': 'istio-proxy'}]}}]
        print(json.dumps({'items': items})); sys.exit()
    if resource == 'secret':
        data = {k: base64.b64encode(v.encode()).decode() for k, v in db['istio/ca']['data'].items() if k != 'root-key.pem'}
        if os.environ.get('CA_TEST_STALE_SECRET'): data['ca-cert.pem'] = base64.b64encode(b'stale').decode()
        if os.environ.get('CA_TEST_EXTRA_SECRET_FIELD'): data['root-key.pem'] = base64.b64encode(b'unexpected').decode()
        print(json.dumps({'data': data})); sys.exit()
    if resource in ('externalsecret', 'deployment'): print('{}'); sys.exit()
    if resource == 'externalsecrets':
        print(json.dumps({'items': [{'metadata': {'namespace': 'redis', 'name': 'redis'},
                                    'spec': {'data': [{'remoteRef': {'key': 'redis/default'}}]}}]})); sys.exit()
    print('{"items": []}'); sys.exit()
if 'annotate' in args: event('refresh'); sys.exit()
if 'rollout' in args:
    event(' '.join(args[args.index('rollout'): ]))
    if 'status' in args and os.environ.get('CA_TEST_ROLLOUT_FAIL'): sys.exit(1)
    sys.exit()
raise SystemExit('unexpected fake kubectl command: ' + repr(args))
'''


class IstioCATest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        for tool in ('bash', 'openssl', 'jq', 'yq'):
            if not shutil.which(tool):
                raise unittest.SkipTest(f'{tool} required')
        cls.fixture = tempfile.TemporaryDirectory(prefix='istio-ca-test-')
        cls.base = Path(cls.fixture.name)
        (cls.base / 'bin').mkdir()
        (cls.base / 'scripts').mkdir()
        for script in ('seed-vault.sh', 'rotate-cred.sh'):
            shutil.copy2(SCRIPTS / script, cls.base / 'scripts' / script)
        (cls.base / 'scripts/vault-secrets.template.yaml').write_text(TEMPLATE)
        for tool in ('vault', 'kubectl'):
            path = cls.base / 'bin' / tool
            path.write_text(FAKE)
            path.chmod(0o700)
        # Generate one real cryptographic fixture for failure/idempotence tests.
        cls.fixture_env = cls.environment(cls.base)
        result = cls.invoke(cls.fixture_env, 'seed-vault.sh', '--only', 'istio/ca')
        if result.returncode:
            raise RuntimeError(result.stdout + result.stderr)
        cls.initial = json.loads(Path(cls.fixture_env['CA_TEST_STATE']).read_text())

    @classmethod
    def tearDownClass(cls):
        cls.fixture.cleanup()

    @classmethod
    def environment(cls, directory):
        temp = directory / 'tmp'
        temp.mkdir(exist_ok=True)
        return dict(os.environ, PATH=f'{cls.base / "bin"}:{os.environ["PATH"]}',
                    VAULT_ADDR='https://test.invalid', VAULT_TOKEN='isolated-test-token',
                    CA_TEST_STATE=str(directory / 'state.json'), CA_TEST_EVENTS=str(directory / 'events'),
                    TMPDIR=str(temp), SYNC_TIMEOUT='0')

    @classmethod
    def invoke(cls, env, script, *args, input=''):
        return subprocess.run(['bash', str(cls.base / 'scripts' / script), *args],
                              input=input, text=True, capture_output=True, env=env, timeout=60)

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(dir=self.base)
        self.env = self.environment(Path(self.directory.name))
        self.write_state(self.initial)

    def tearDown(self):
        self.assertEqual(list(Path(self.env['TMPDIR']).iterdir()), [], 'private temporary files leaked')
        self.directory.cleanup()

    @staticmethod
    def root_path(certificate):
        fingerprint = hashlib.sha256(ssl.PEM_cert_to_DER_cert(certificate)).hexdigest()
        return 'operator/istio-roots/' + fingerprint

    def state(self):
        return json.loads(Path(self.env['CA_TEST_STATE']).read_text())

    def write_state(self, value):
        Path(self.env['CA_TEST_STATE']).write_text(json.dumps(value))

    def events(self):
        p = Path(self.env['CA_TEST_EVENTS'])
        return p.read_text() if p.exists() else ''

    def run_script(self, script, *args, ok=True, input='', **environment):
        result = self.invoke(dict(self.env, **environment), script, *args, input=input)
        self.assertEqual(result.returncode == 0, ok, result.stdout + result.stderr)
        self.assertNotIn('PRIVATE KEY-----', result.stdout + result.stderr)
        return result

    def test_seed_creates_and_preserves_bundle(self):
        self.write_state({})
        self.run_script('seed-vault.sh', '--only', 'istio/ca')
        original = self.state()['istio/ca']
        self.assertEqual(original['version'], 1)
        self.assertEqual(len(original['data']), 4)
        self.assertNotIn('root-key.pem', original['data'])
        self.assertEqual(len(self.state()[self.root_path(original['data']['root-cert.pem'])]['data']), 2)
        self.run_script('seed-vault.sh', '--only', 'istio/ca')
        self.assertEqual(self.state()['istio/ca'], original)
        self.run_script('seed-vault.sh', '--regenerate')
        self.assertEqual(self.state()['istio/ca'], original)

    def test_missing_ca_rotation_is_refused_but_broad_seeding_can_create_it(self):
        self.write_state({})
        self.run_script('seed-vault.sh', '--regenerate', '--only', 'istio/ca', ok=False)
        self.assertEqual(self.state(), {})
        self.run_script('seed-vault.sh', '--regenerate')
        self.assertEqual(self.state()['istio/ca']['version'], 1)

    def test_explicit_intermediate_and_root_rotation(self):
        original = self.state()['istio/ca']['data']
        self.run_script('seed-vault.sh', '--regenerate', '--only', 'istio/ca')
        renewed = self.state()['istio/ca']['data']
        self.assertEqual(self.state()[self.root_path(original['root-cert.pem'])], self.initial[self.root_path(original['root-cert.pem'])])
        for key in ('root-cert.pem',):
            self.assertEqual(original[key], renewed[key])
        for key in ('ca-cert.pem', 'ca-key.pem', 'cert-chain.pem'):
            self.assertNotEqual(original[key], renewed[key])
        self.run_script('seed-vault.sh', '--regenerate', '--only', 'istio/ca', '--rotate-istio-root')
        self.assertNotEqual(renewed['root-cert.pem'], self.state()['istio/ca']['data']['root-cert.pem'])

    def test_invalid_bundle_is_never_repaired_or_replaced(self):
        for change in ('missing', 'wrong-key', 'wrong-chain'):
            state = json.loads(json.dumps(self.initial))
            data = state['istio/ca']['data']
            if change == 'missing': del data['ca-key.pem']
            elif change == 'wrong-key': data['ca-key.pem'] = state[self.root_path(data['root-cert.pem'])]['data']['root-key.pem']
            else: data['cert-chain.pem'] = data['root-cert.pem'] + data['root-cert.pem']
            self.write_state(state)
            self.run_script('seed-vault.sh', '--regenerate', '--only', 'istio/ca', ok=False)
            self.assertEqual(self.state(), state)

    def test_legacy_combined_bundle_and_missing_operator_roots_fail_closed(self):
        for change in ('legacy', 'missing-root', 'missing-key', 'wrong-root'):
            state = json.loads(json.dumps(self.initial))
            signing = state['istio/ca']['data']
            root_path = self.root_path(signing['root-cert.pem'])
            root = state[root_path]['data']
            if change == 'legacy': signing['root-key.pem'] = root['root-key.pem']
            elif change == 'missing-root': del state[root_path]
            elif change == 'missing-key': del root['root-key.pem']
            else: root['root-cert.pem'] = signing['ca-cert.pem']
            self.write_state(state)
            self.run_script('seed-vault.sh', '--regenerate', '--only', 'istio/ca', ok=False)
            self.assertEqual(self.state(), state)

    def test_failed_root_publication_keeps_active_trust_and_old_root_record(self):
        self.run_script('seed-vault.sh', '--regenerate', '--only', 'istio/ca', '--rotate-istio-root',
                        ok=False, CA_TEST_SIGNING_CAS_FAIL='1')
        state = self.state()
        self.assertEqual(state['istio/ca'], self.initial['istio/ca'])
        old_root_path = self.root_path(state['istio/ca']['data']['root-cert.pem'])
        self.assertEqual(state[old_root_path], self.initial[old_root_path])
        self.assertEqual(len([p for p in state if p.startswith('operator/istio-roots/')]), 2)

    def test_vault_errors_deleted_versions_and_cas_conflict_fail_closed(self):
        for flag in ('CA_TEST_VAULT_ERROR', 'CA_TEST_DELETED', 'CA_TEST_CAS_FAIL'):
            self.run_script('seed-vault.sh', '--regenerate', '--only', 'istio/ca', ok=False, **{flag: '1'})
            self.assertEqual(self.state(), self.initial)

    def test_unselected_ca_and_default_rotation_dry_run_do_not_change_it(self):
        self.run_script('seed-vault.sh', '--regenerate', '--only', 'redis/default')
        self.assertEqual(self.state()['istio/ca'], self.initial['istio/ca'])
        self.run_script('rotate-cred.sh', '--dry-run')
        self.run_script('rotate-cred.sh', '--dry-run', 'istio/ca')
        self.assertEqual(self.state()['istio/ca'], self.initial['istio/ca'])
        self.assertNotIn('rollout restart', self.events())

    def test_rotation_verifies_delivery_before_rolling_istiod(self):
        self.run_script('rotate-cred.sh', '--yes', 'istio/ca')
        events = self.events()
        self.assertLess(events.index('write istio/ca'), events.index('refresh'))
        self.assertLess(events.index('refresh'), events.index('rollout restart deployment/istiod'))
        self.assertNotIn('daemonset/ztunnel', events)
        self.assertEqual(self.state()['istio/ca']['data']['root-cert.pem'], self.initial['istio/ca']['data']['root-cert.pem'])

    def test_stale_delivery_aborts_without_restart(self):
        self.run_script('rotate-cred.sh', '--yes', 'istio/ca', ok=False, CA_TEST_STALE_SECRET='1')
        self.assertIn('write istio/ca', self.events())
        self.assertNotIn('rollout restart', self.events())

    def test_root_key_in_delivered_secret_is_rejected(self):
        self.run_script('rotate-cred.sh', '--yes', 'istio/ca', ok=False, CA_TEST_EXTRA_SECRET_FIELD='1')
        self.assertNotIn('rollout restart', self.events())

    def test_rollout_failure_is_not_reported_as_success(self):
        result = self.run_script('rotate-cred.sh', '--yes', 'istio/ca', ok=False, CA_TEST_ROLLOUT_FAIL='1')
        self.assertIn('rollout status deployment/istiod', self.events())
        self.assertNotIn('rollout ready', result.stdout)

    def test_expired_intermediate_can_be_renewed_but_short_lived_root_cannot(self):
        directory = Path(self.directory.name) / 'certs'
        directory.mkdir()
        original = self.state()['istio/ca']['data']
        material = dict(original, **self.state()[self.root_path(original['root-cert.pem'])]['data'])
        for key, value in material.items():
            (directory / key).write_text(value)
        def openssl(*args):
            subprocess.run(['openssl', *args], cwd=directory, check=True, capture_output=True)
        (directory / 'extensions.cnf').write_text(
            '[req]\ndistinguished_name=dn\n[dn]\nCN=Test\n'
            '[ca]\nbasicConstraints=critical,CA:true\nkeyUsage=critical,keyCertSign,cRLSign\n')
        openssl('req', '-new', '-key', 'ca-key.pem', '-out', 'ca.csr', '-subj', '/CN=Expired Intermediate')
        (directory / 'issued').mkdir()
        (directory / 'index').touch()
        (directory / 'serial').write_text('1234\n')
        (directory / 'signer.cnf').write_text(
            '[ca]\ndefault_ca=signer\n[signer]\ndatabase=index\nserial=serial\n'
            'new_certs_dir=issued\ncertificate=root-cert.pem\nprivate_key=root-key.pem\n'
            'default_md=sha256\npolicy=policy\nx509_extensions=extensions\n'
            '[policy]\ncommonName=supplied\n[extensions]\nbasicConstraints=critical,CA:true\n'
            'keyUsage=critical,keyCertSign,cRLSign\n')
        openssl('ca', '-batch', '-notext', '-config', 'signer.cnf', '-in', 'ca.csr', '-out', 'ca-cert.pem',
                '-startdate', '20200101000000Z', '-enddate', '20210101000000Z')
        state = self.state()
        state['istio/ca']['data']['ca-cert.pem'] = (directory / 'ca-cert.pem').read_text()
        state['istio/ca']['data']['cert-chain.pem'] = state['istio/ca']['data']['ca-cert.pem'] + original['root-cert.pem']
        self.write_state(state)
        self.run_script('seed-vault.sh', '--only', 'istio/ca', ok=False)
        self.assertEqual(self.state(), state)
        self.run_script('seed-vault.sh', '--regenerate', '--only', 'istio/ca')
        openssl('req', '-new', '-x509', '-key', 'root-key.pem', '-days', '2',
                '-subj', '/O=Homelab/CN=Homelab Root CA', '-config', 'extensions.cnf', '-extensions', 'ca', '-out', 'root-cert.pem')
        state = self.state()
        state['istio/ca']['data']['root-cert.pem'] = (directory / 'root-cert.pem').read_text()
        state[self.root_path(state['istio/ca']['data']['root-cert.pem'])] = {
            'version': 1, 'data': {'root-cert.pem': state['istio/ca']['data']['root-cert.pem'],
                                  'root-key.pem': material['root-key.pem']}}
        state['istio/ca']['data']['cert-chain.pem'] = state['istio/ca']['data']['ca-cert.pem'] + state['istio/ca']['data']['root-cert.pem']
        self.write_state(state)
        result = self.run_script('seed-vault.sh', '--regenerate', '--only', 'istio/ca', ok=False)
        self.assertIn('root must outlive', result.stderr)
        self.assertEqual(self.state(), state)

    def test_root_rotation_is_explicit_and_refuses_enrolled_mesh(self):
        self.run_script('rotate-cred.sh', '--rotate-istio-root', '--yes', 'istio/ca', ok=False)
        self.run_script('rotate-cred.sh', '--rotate-istio-root', ok=False)
        self.run_script('rotate-cred.sh', '--yes', 'istio/ca', 'redis/default', ok=False)
        self.run_script('seed-vault.sh', '--rotate-istio-root', ok=False)
        for kind in ('1', 'sidecar', 'native-sidecar'):
            self.run_script('rotate-cred.sh', '--rotate-istio-root', 'istio/ca', ok=False,
                            input='y\nREPLACE ISTIO ROOT\n', CA_TEST_ENROLLED=kind)
        self.assertEqual(self.state(), self.initial)
        self.assertNotIn('write istio/ca', self.events())

    def test_root_rotation_on_unenrolled_cluster_rolls_proxies(self):
        self.run_script('rotate-cred.sh', '--rotate-istio-root', 'istio/ca', input='y\nREPLACE ISTIO ROOT\n')
        self.assertNotEqual(self.state()['istio/ca']['data']['root-cert.pem'], self.initial['istio/ca']['data']['root-cert.pem'])
        events = self.events()
        self.assertLess(events.index('rollout status deployment/istiod'), events.index('rollout restart daemonset/ztunnel'))


if __name__ == '__main__':
    unittest.main()
