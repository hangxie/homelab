"""Audit CA distribution and pod inventory; separate TLS probes check availability."""

import hashlib
import json
import os
import re
import ssl
import sys
import urllib.request

NAMESPACE = os.environ.get("POSTGRES_NAMESPACE", "postgres-cluster")
CLUSTER = os.environ.get("POSTGRES_CLUSTER", "postgres-cluster")
ACCOUNT = "/var/run/secrets/kubernetes.io/serviceaccount"
SOURCE_CA = "/source/ca.crt"


class AuditError(ValueError):
    pass


def fingerprints(pem):
    blocks = re.findall(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", pem, re.S)
    if not blocks:
        raise AuditError("empty or malformed CA bundle")
    return {hashlib.sha256(ssl.PEM_cert_to_DER_cert(block)).hexdigest() for block in blocks}


def api_get(path):
    with open(f"{ACCOUNT}/token", encoding="utf-8") as source:
        token = source.read().strip()
    request = urllib.request.Request("https://kubernetes.default.svc" + path,
                                     headers={"Authorization": f"Bearer {token}"})
    context = ssl.create_default_context(cafile=f"{ACCOUNT}/ca.crt")
    with urllib.request.urlopen(request, context=context, timeout=5) as response:
        return json.load(response)


def audit(get=api_get, source_pem=None):
    if source_pem is None:
        with open(SOURCE_CA, encoding="utf-8") as source:
            source_pem = source.read()
    bundle = get("/apis/trust.cert-manager.io/v1alpha1/bundles/postgres-server-ca")
    if not any(condition["type"] == "Synced" and condition["status"] == "True"
               and condition.get("observedGeneration", 0) >= bundle["metadata"]["generation"]
               for condition in bundle.get("status", {}).get("conditions", [])):
        raise AuditError("Bundle is not Synced at its current generation")
    expected = set()
    found_source = False
    for source in bundle["spec"]["sources"]:
        if source.get("secret") == {"name": f"{CLUSTER}-ca", "key": "ca.crt"}:
            expected |= fingerprints(source_pem)
            found_source = True
        elif "inLine" in source:
            expected |= fingerprints(source["inLine"])
        else:
            raise AuditError("unsupported Bundle source; review the audit before changing CA ownership")
    if not found_source:
        raise AuditError("Bundle no longer references the CNPG CA")
    selector = bundle["spec"]["target"]["namespaceSelector"]
    expressions = selector.get("matchExpressions", [])
    if (selector.get("matchLabels") or len(expressions) != 1
            or expressions[0].get("key") != "kubernetes.io/metadata.name"
            or expressions[0].get("operator") != "In"):
        raise AuditError("unsupported Bundle namespace selector")
    clients = sorted(set(expressions[0]["values"]))
    if NAMESPACE not in clients:
        raise AuditError("administrative CA target namespace is missing")
    errors = []
    for namespace in clients:
        try:
            target = get(f"/api/v1/namespaces/{namespace}/configmaps/postgres-server-ca")
            if fingerprints(target["data"]["ca.crt"]) != expected:
                errors.append(f"{namespace}: CA fingerprint mismatch")
        except (OSError, ValueError, KeyError):
            errors.append(f"{namespace}: CA ConfigMap missing, malformed or unreadable")
    cluster = get(f"/apis/postgresql.cnpg.io/v1/namespaces/{NAMESPACE}/clusters/{CLUSTER}")
    wanted = {CLUSTER: cluster["spec"]["instances"]}
    for suffix in ("rw", "ro"):
        name = f"{CLUSTER}-pooler-{suffix}"
        pooler = get(f"/apis/postgresql.cnpg.io/v1/namespaces/{NAMESPACE}/poolers/{name}")
        wanted[name] = pooler["spec"]["instances"]
    observed = dict.fromkeys(wanted, 0)
    # Match Alloy discovery, including unready Running pods: availability is
    # checked independently by the per-pod TLS probes.
    for pod in get(f"/api/v1/namespaces/{NAMESPACE}/pods")["items"]:
        metadata, status = pod["metadata"], pod.get("status", {})
        ports = [port.get("containerPort") for container in pod.get("spec", {}).get("containers", [])
                 for port in container.get("ports", [])]
        if (metadata.get("deletionTimestamp") or status.get("phase") != "Running"
                or not status.get("podIP") or 5432 not in ports):
            continue
        labels = metadata.get("labels", {})
        name = labels.get("cnpg.io/poolerName")
        if name in wanted:
            observed[name] += 1
        elif labels.get("cnpg.io/cluster") == CLUSTER:
            observed[CLUSTER] += 1
    for name, count in wanted.items():
        if observed[name] != count:
            errors.append(f"{name}: found {observed[name]} TLS pods, expected {count}")
    if errors:
        raise AuditError("; ".join(errors))
    return len(clients)


if __name__ == "__main__":
    try:
        print(f"PostgreSQL trust audit passed for {audit()} namespaces and the configured TLS pod inventory")
    except AuditError as error:
        print(f"PostgreSQL trust audit failed: {error}", file=sys.stderr)
        sys.exit(1)
    except Exception as error:
        # API failures must fail the Job without logging credential-bearing responses.
        print(f"PostgreSQL trust audit failed: {type(error).__name__}", file=sys.stderr)
        sys.exit(1)
