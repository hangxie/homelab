#!/usr/bin/env bash
# Tear down the Vault state created by scripts/seed-vault.sh so the next
# `seed-vault.sh` run starts from a clean slate. This DESTROYS every KV
# entry under `homelab/`, so all auto-generated and externally minted
# credentials (Harbor robot, HuggingFace token, Cloudflare token, etc.) will
# need to be re-supplied before the next seed.
#
# Leaves the AppRole auth mount itself in place — it may be shared with
# other consumers. Only the cluster-scoped `homelab` role and the
# `homelab-read` policy are removed.
#
# Prereqs:
#   - vault CLI on PATH
#   - VAULT_ADDR and VAULT_TOKEN exported (token must be able to disable
#     secret engines, delete approle roles, and delete policies)

set -euo pipefail

: "${VAULT_ADDR:?VAULT_ADDR must be set}"
: "${VAULT_TOKEN:?VAULT_TOKEN must be set}"

POLICY_NAME="homelab-read"
ROLE_NAME="homelab"
KV_MOUNT="homelab"
APPROLE_MOUNT="approle"

confirm() {
  cat <<EOF
About to remove from ${VAULT_ADDR}:
  - KV mount    ${KV_MOUNT}/        (DESTROYS all secrets under this path)
  - AppRole role auth/${APPROLE_MOUNT}/role/${ROLE_NAME}
  - Policy      ${POLICY_NAME}

The AppRole auth mount at ${APPROLE_MOUNT}/ is left alone in case other
roles share it.

EOF
  read -r -p "Type 'nuke' to proceed: " ack < /dev/tty
  [[ "${ack}" == "nuke" ]] || { echo "Aborted." >&2; exit 1; }
}

disable_kv_mount() {
  if vault secrets list -format=json | jq -e --arg m "${KV_MOUNT}/" '.[$m] // empty' >/dev/null; then
    echo ">>> Disabling KV mount ${KV_MOUNT}/ (destroys all data)"
    vault secrets disable "${KV_MOUNT}/"
  else
    echo ">>> KV mount ${KV_MOUNT}/ already absent"
  fi
}

delete_approle_role() {
  if vault read "auth/${APPROLE_MOUNT}/role/${ROLE_NAME}" >/dev/null 2>&1; then
    echo ">>> Deleting AppRole role ${ROLE_NAME}"
    vault delete "auth/${APPROLE_MOUNT}/role/${ROLE_NAME}"
  else
    echo ">>> AppRole role ${ROLE_NAME} already absent"
  fi
}

delete_policy() {
  if vault policy read "${POLICY_NAME}" >/dev/null 2>&1; then
    echo ">>> Deleting policy ${POLICY_NAME}"
    vault policy delete "${POLICY_NAME}"
  else
    echo ">>> Policy ${POLICY_NAME} already absent"
  fi
}

main() {
  confirm
  disable_kv_mount
  delete_approle_role
  delete_policy
  echo
  echo "Vault state for this cluster removed."
  echo "Next: pre-load externally minted creds (Harbor, HuggingFace, Cloudflare) and re-run scripts/seed-vault.sh."
}

main "$@"
