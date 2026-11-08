# Scripts

Operator utilities. Imperative by design: Vault seed/nuke, credential rotation, certificate seeding, Harbor jar seeding, and redeploy.

`seed-vault.sh` generates/validates the Istio CA bundle; `rotate-cred.sh istio/ca` renews its intermediate and verifies live Secret delivery before rolling istiod. Root replacement is a separate explicit operation. See the [CA rotation commands](../README.md#rotate-the-istio-ca).

Run the CA lifecycle regression tests with `python3 -B -m unittest discover -s scripts/tests -v`. They use real OpenSSL with isolated Vault/Kubernetes fakes, plus a disposable loopback Vault dev server for AppRole ACL verification when the Vault binary is available. They never contact the homelab cluster or its Vault. Requirements: Bash, Python 3, OpenSSL, jq and the same yq used by the scripts.
