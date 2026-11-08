#!/usr/bin/env python3
"""Verify the actual AppRole ACL against a disposable loopback Vault server."""

import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time
import unittest


@unittest.skipUnless(all(shutil.which(t) for t in ('vault', 'openssl', 'jq', 'yq')), 'Vault/OpenSSL/jq/yq required')
class VaultCAPolicyTest(unittest.TestCase):
    def test_cluster_identity_reads_signing_bundle_but_not_operator_roots(self):
        with tempfile.TemporaryDirectory(prefix='homelab-vault-acl-') as directory:
            path = Path(directory)
            with socket.socket() as listener:
                listener.bind(('127.0.0.1', 0))
                port = listener.getsockname()[1]
            address = f'http://127.0.0.1:{port}'
            env = dict(os.environ, VAULT_ADDR=address, VAULT_TOKEN='isolated-ca-test-root',
                       VAULT_SKIP_VERIFY='false', TMPDIR=directory)
            # Never inherit a production proxy/namespace or write ~/.vault-token.
            for name in ('VAULT_NAMESPACE', 'VAULT_AGENT_ADDR', 'VAULT_PROXY_ADDR',
                         'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy', 'all_proxy'):
                env.pop(name, None)
            with (path / 'server.log').open('w') as log:
                server = subprocess.Popen(
                    ['vault', 'server', '-dev', '-dev-no-store-token',
                     '-dev-root-token-id=isolated-ca-test-root', f'-dev-listen-address=127.0.0.1:{port}'],
                    env=env, stdout=log, stderr=subprocess.STDOUT)
                try:
                    def vault(*args, token=None, ok=True):
                        command_env = dict(env, VAULT_TOKEN=token or env['VAULT_TOKEN'])
                        result = subprocess.run(['vault', *args], env=command_env, capture_output=True,
                                                text=True, timeout=30)
                        self.assertEqual(result.returncode == 0, ok, result.stderr)
                        if not ok:
                            self.assertIn('403', result.stderr, 'expected an ACL denial, not another CLI/server error')
                        return result.stdout

                    deadline = time.monotonic() + 15
                    while True:
                        result = subprocess.run(['vault', 'status'], env=env, capture_output=True, timeout=5)
                        if result.returncode == 0:
                            break
                        if server.poll() is not None or time.monotonic() >= deadline:
                            self.fail('isolated Vault dev server did not start')
                        time.sleep(0.1)

                    seed = Path(__file__).resolve().parents[1] / 'seed-vault.sh'
                    result = subprocess.run(['bash', str(seed), '--only', 'istio/ca'], env=env,
                                            capture_output=True, text=True, timeout=60)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertNotIn('PRIVATE KEY-----', result.stdout + result.stderr)
                    signing = json.loads(vault('kv', 'get', '-mount=homelab', '-format=json', 'istio/ca'))
                    self.assertEqual(set(signing['data']['data']),
                                     {'ca-cert.pem', 'ca-key.pem', 'root-cert.pem', 'cert-chain.pem'})
                    renewal = subprocess.run(['bash', str(seed), '--regenerate', '--only', 'istio/ca'], env=env,
                                             capture_output=True, text=True, timeout=60)
                    self.assertEqual(renewal.returncode, 0, renewal.stderr)
                    roots = json.loads(vault('kv', 'list', '-mount=homelab', '-format=json', 'operator/istio-roots'))
                    self.assertEqual(len(roots), 1)
                    root_path = 'operator/istio-roots/' + roots[0]
                    root = json.loads(vault('kv', 'get', '-mount=homelab', '-format=json', root_path))
                    self.assertEqual(set(root['data']['data']), {'root-cert.pem', 'root-key.pem'})

                    # Authenticate exactly as External Secrets does, rather than
                    # merely inspecting policy text or inventing a test policy.
                    role = json.loads(vault('read', '-format=json', 'auth/approle/role/homelab/role-id'))['data']['role_id']
                    secret = json.loads(vault('write', '-f', '-format=json', 'auth/approle/role/homelab/secret-id'))['data']['secret_id']
                    token = json.loads(vault('write', '-format=json', 'auth/approle/login',
                                             f'role_id={role}', f'secret_id={secret}'))['auth']['client_token']
                    readable = json.loads(vault('kv', 'get', '-mount=homelab', '-format=json', 'istio/ca', token=token))
                    self.assertNotIn('root-key.pem', readable['data']['data'])
                    previous = json.loads(vault('kv', 'get', '-mount=homelab', '-version=1', '-format=json', 'istio/ca', token=token))
                    self.assertNotIn('root-key.pem', previous['data']['data'])
                    for args in (
                        ('kv', 'get', '-mount=homelab', root_path),
                        ('kv', 'get', '-mount=homelab', '-version=1', root_path),
                        ('kv', 'metadata', 'get', '-mount=homelab', root_path),
                        ('kv', 'list', '-mount=homelab', 'operator/istio-roots'),
                        ('kv', 'list', '-mount=homelab', 'operator/'),
                    ):
                        vault(*args, token=token, ok=False)
                    # Other application credentials retain the existing policy.
                    vault('kv', 'put', '-mount=homelab', 'test/application', 'password=isolated-fixture')
                    vault('kv', 'get', '-mount=homelab', 'test/application', token=token)
                finally:
                    server.terminate()
                    try:
                        server.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        server.kill()
                        server.wait(timeout=5)


if __name__ == '__main__':
    unittest.main()
