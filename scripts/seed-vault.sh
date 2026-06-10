#!/usr/bin/env bash
# One-time Vault seeding: enable KV v2 at homelab/, enable AppRole auth,
# create role `homelab`, write the read policy, and populate KV paths from
# either an operator-supplied secrets file or interactive prompts.
# Idempotent: re-running with an unchanged source file is a no-op.
#
# Prereqs:
#   - vault CLI on PATH
#   - VAULT_ADDR and VAULT_TOKEN exported (token must be able to enable
#     auth methods and write KV)
#
# Value resolution order per (path, field):
#   1. Existing value already in Vault (keeps re-runs idempotent)
#   2. Default in scripts/vault-secrets.template.yaml `values:` block
#   3. Auto-generated random secret (32 random bytes, url-safe base64 with
#      padding — 44 chars, valid input for cryptography.fernet.Fernet)
#
# Externally minted credentials (entries marked `generate: false`) must be
# written to Vault with `vault kv put` before this script runs.

set -euo pipefail

: "${VAULT_ADDR:?VAULT_ADDR must be set}"
: "${VAULT_TOKEN:?VAULT_TOKEN must be set}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
TEMPLATE="${SCRIPT_DIR}/vault-secrets.template.yaml"

POLICY_NAME="homelab-read"
ROLE_NAME="homelab"
KV_MOUNT="homelab"
APPROLE_MOUNT="approle"

ensure_kv_mount() {
  if ! vault secrets list -format=json | jq -e --arg m "${KV_MOUNT}/" '.[$m] // empty' >/dev/null; then
    echo ">>> Enabling KV v2 at ${KV_MOUNT}/"
    vault secrets enable -path="${KV_MOUNT}" -version=2 kv
  else
    echo ">>> KV v2 already mounted at ${KV_MOUNT}/"
  fi
}

ensure_approle_mount() {
  if ! vault auth list -format=json | jq -e --arg m "${APPROLE_MOUNT}/" '.[$m] // empty' >/dev/null; then
    echo ">>> Enabling AppRole auth at ${APPROLE_MOUNT}/"
    vault auth enable -path="${APPROLE_MOUNT}" approle
  else
    echo ">>> AppRole already enabled at ${APPROLE_MOUNT}/"
  fi
}

write_policy() {
  echo ">>> Writing policy ${POLICY_NAME}"
  vault policy write "${POLICY_NAME}" - <<EOF
path "${KV_MOUNT}/data/*"     { capabilities = ["read"] }
path "${KV_MOUNT}/metadata/*" { capabilities = ["list"] }
EOF
}

ensure_role() {
  echo ">>> Ensuring AppRole role ${ROLE_NAME} exists"
  vault write "auth/${APPROLE_MOUNT}/role/${ROLE_NAME}" \
    token_policies="${POLICY_NAME}" \
    token_ttl=1h \
    token_max_ttl=4h \
    secret_id_ttl=0 \
    secret_id_num_uses=0
}

# Walk the template, emitting "path field generate" triples. `generate` is
# "true" by default; entries that set `generate: false` (e.g. externally minted
# credentials like Harbor robots) must be populated from vault or the secrets
# file and will fail the run rather than fall through to random generation.
extract_template_entries() {
  yq -r '
    .secrets[] as $s
    | (if $s.generate == false then "false" else "true" end) as $g
    | $s.fields[]? as $f
    | "\($s.path) \($f) \($g)"
  ' "${TEMPLATE}"
}

# Fetch the default value baked into the template's `values:` block.
fetch_from_template() {
  local path="$1" field="$2"
  yq -r --arg p "${path}" --arg f "${field}" \
    '.secrets[]? | select(.path == $p) | .values[$f] // empty' \
    "${TEMPLATE}"
}

# Fetch the current value already stored in Vault, if any.
fetch_from_vault() {
  local path="$1" field="$2"
  vault kv get -field="${field}" "${KV_MOUNT}/${path}" 2>/dev/null || true
}

# 32 random bytes encoded as url-safe base64 (44 chars including '=' padding).
# Padding is preserved so cryptography.fernet.Fernet accepts the value as-is
# for Airflow's fernet key; other consumers treat it as an opaque string.
generate_random() {
  openssl rand -base64 32 | tr -d '\n' | tr '/+' '_-'
}

resolve_value() {
  local path="$1" field="$2" generate="$3" value
  for src in fetch_from_vault fetch_from_template; do
    value="$("${src}" "${path}" "${field}")"
    if [[ -n "${value}" ]]; then
      printf '%s' "${value}"
      return
    fi
  done
  if [[ "${generate}" == "false" ]]; then
    local example="vault kv put ${KV_MOUNT}/${path}"
    local f
    while read -r f; do
      [[ -z "${f}" ]] && continue
      example+=" ${f}='<value>'"
    done < <(yq -r --arg p "${path}" '.secrets[]? | select(.path == $p) | .fields[]' "${TEMPLATE}")
    echo "Error: ${KV_MOUNT}/${path} field '${field}' is marked generate=false and has no value yet." >&2
    echo "       Write all fields to Vault in a single command (kv put replaces the whole secret), then re-run:" >&2
    echo "         ${example}" >&2
    return 1
  fi
  generate_random
}

write_kv_entries() {
  local current_path="" payload=() value
  while read -r path field generate; do
    if [[ "${path}" != "${current_path}" ]]; then
      if [[ -n "${current_path}" ]]; then
        echo ">>> Writing ${KV_MOUNT}/${current_path}"
        vault kv put "${KV_MOUNT}/${current_path}" "${payload[@]}"
      fi
      current_path="${path}"
      payload=()
    fi
    value="$(resolve_value "${path}" "${field}" "${generate}")"
    payload+=("${field}=${value}")
  done < <(extract_template_entries)
  if [[ -n "${current_path}" ]]; then
    echo ">>> Writing ${KV_MOUNT}/${current_path}"
    vault kv put "${KV_MOUNT}/${current_path}" "${payload[@]}"
  fi
}

main() {
  ensure_kv_mount
  ensure_approle_mount
  write_policy
  ensure_role
  write_kv_entries
  echo
  echo "Seeding complete."
  echo "Next: continue with the first-time bootstrap section in README.md (terraform apply, then ansible bootstrap-k8s.yml)."
}

main "$@"
