"""Test trust drift and missing TLS replica detection without Kubernetes access."""

import base64
import copy
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("audit", ROOT / "gitops/platform/postgres-cluster/trust-audit.py")
audit = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(audit)


def pem(value):
    return "-----BEGIN CERTIFICATE-----\n" + base64.b64encode(value).decode() + "\n-----END CERTIFICATE-----\n"


class TrustAuditTest(unittest.TestCase):
    def setUp(self):
        self.ca, self.old_ca = pem(b"current certificate"), pem(b"old overlap certificate")
        self.objects = {
            "/apis/trust.cert-manager.io/v1alpha1/bundles/postgres-server-ca": {
                "metadata": {"generation": 2},
                "status": {"conditions": [{"type": "Synced", "status": "True", "observedGeneration": 2}]},
                "spec": {"sources": [{"secret": {"name": "postgres-cluster-ca", "key": "ca.crt"}}],
                         "target": {"namespaceSelector": {"matchExpressions": [{"key": "kubernetes.io/metadata.name", "operator": "In", "values": ["postgres-cluster", "grafana"]}]}}}},
            "/apis/postgresql.cnpg.io/v1/namespaces/postgres-cluster/clusters/postgres-cluster": {"spec": {"instances": 3}},
            "/api/v1/namespaces/postgres-cluster/pods": {"items": []},
        }
        for namespace in ("postgres-cluster", "grafana"):
            self.objects[f"/api/v1/namespaces/{namespace}/configmaps/postgres-server-ca"] = {"data": {"ca.crt": self.ca}}
        for name, count, label in [("postgres-cluster", 3, "cnpg.io/cluster"), ("postgres-cluster-pooler-rw", 2, "cnpg.io/poolerName"), ("postgres-cluster-pooler-ro", 2, "cnpg.io/poolerName")]:
            if "pooler" in name:
                self.objects[f"/apis/postgresql.cnpg.io/v1/namespaces/postgres-cluster/poolers/{name}"] = {"spec": {"instances": count}}
            for number in range(count):
                self.objects["/api/v1/namespaces/postgres-cluster/pods"]["items"].append({
                    "metadata": {"name": f"{name}-{number}", "labels": {label: name}},
                    "status": {"phase": "Running", "podIP": f"10.0.0.{number + 1}"},
                    "spec": {"containers": [{"ports": [{"containerPort": 5432}]}]}})
        self.bundle = self.objects["/apis/trust.cert-manager.io/v1alpha1/bundles/postgres-server-ca"]

    def run_audit(self):
        return audit.audit(get=self.objects.__getitem__, source_pem=self.ca)

    def test_complete_distribution_and_inventory(self):
        self.assertEqual(self.run_audit(), 2)

    def test_missing_or_stale_namespace_trust(self):
        path = "/api/v1/namespaces/grafana/configmaps/postgres-server-ca"
        self.objects[path]["data"]["ca.crt"] = self.old_ca
        with self.assertRaisesRegex(audit.AuditError, "grafana: CA fingerprint mismatch"):
            self.run_audit()
        del self.objects[path]
        with self.assertRaisesRegex(audit.AuditError, "grafana: CA ConfigMap missing"):
            self.run_audit()

    def test_explicit_overlap_is_order_independent(self):
        self.bundle["spec"]["sources"].append({"inLine": self.old_ca})
        for namespace in ("postgres-cluster", "grafana"):
            self.objects[f"/api/v1/namespaces/{namespace}/configmaps/postgres-server-ca"]["data"]["ca.crt"] = self.old_ca + self.ca + self.ca
        self.assertEqual(self.run_audit(), 2)
        self.bundle["spec"]["sources"].pop()
        with self.assertRaisesRegex(audit.AuditError, "fingerprint mismatch"):
            self.run_audit()

    def test_stale_bundle_status_fails(self):
        self.bundle["metadata"]["generation"] = 3
        with self.assertRaisesRegex(audit.AuditError, "current generation"):
            self.run_audit()

    def test_missing_or_unprobeable_pooler_replica_fails(self):
        pods = self.objects["/api/v1/namespaces/postgres-cluster/pods"]["items"]
        original = copy.deepcopy(pods[-1])
        for change in ({"phase": "Pending"}, {"podIP": ""}):
            pods[-1] = copy.deepcopy(original)
            pods[-1]["status"].update(change)
            with self.assertRaisesRegex(audit.AuditError, "pooler-ro: found 1 TLS pods, expected 2"):
                self.run_audit()
        pods.pop()
        with self.assertRaisesRegex(audit.AuditError, "pooler-ro: found 1 TLS pods, expected 2"):
            self.run_audit()

    def test_unknown_source_and_selector_fail_closed(self):
        self.bundle["spec"]["sources"].append({"useDefaultCAs": True})
        with self.assertRaisesRegex(audit.AuditError, "unsupported Bundle source"):
            self.run_audit()
        self.bundle["spec"]["sources"].pop()
        self.bundle["spec"]["target"]["namespaceSelector"] = {"matchLabels": {"app": "database"}}
        with self.assertRaisesRegex(audit.AuditError, "namespace selector"):
            self.run_audit()


if __name__ == "__main__":
    unittest.main()
