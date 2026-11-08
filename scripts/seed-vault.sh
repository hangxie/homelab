#!/usr/bin/env bash
# One-time Vault seeding: enable KV v2 at homelab/, enable AppRole auth,
# create role `homelab`, write the read policy, and populate template KV paths.
# Existing credentials are preserved; the CA bundle is validated without writes.
#
# Prereqs:
#   - vault, jq, yq and openssl on PATH
#   - VAULT_ADDR and VAULT_TOKEN exported (token must be able to enable
#     auth methods and write KV)
#
# Value resolution order per (path, field):
#   1. Existing value already in Vault (keeps re-runs idempotent)
#   2. Default in scripts/vault-secrets.template.yaml `values:` block
#   3. Auto-generated random secret; set
#      `format: hex` in the template for consumers that require a hex string
#      (e.g. JupyterHub's cookie_secret / CryptKeeper.keys)
#
# Externally minted credentials (entries marked `generate: false`) must be
# written to Vault with `vault kv put` before this script runs.
#
# --regenerate: skip step 1 (the Vault lookup) for generatable entries so any
# secret that would otherwise be auto-generated is minted fresh, overwriting the
# existing Vault value. Entries with a non-empty template default (e.g.
# usernames) keep that default; externally minted `generate: false` credentials
# (HuggingFace, Harbor, Cloudflare) are never touched.
#
# --only <path>: restrict the KV writes to the named template paths (repeatable).
# The mount/AppRole/policy setup still runs -- it is idempotent. Used by
# scripts/rotate-cred.sh so credential rotation reuses this generator rather
# than growing a second one.
# Istio CA bundles use a path-level generator instead of per-field randomness.
# Only explicit --regenerate --only istio/ca renews the intermediate; the root
# is preserved unless --rotate-istio-root is also explicitly selected.

set -euo pipefail

# Private keys must never be expanded into a shell trace.
if [[ "$-" == *x* ]]; then
  echo 'Error: disable shell tracing before seeding credentials.' >&2
  exit 1
fi

REGENERATE=false
ROTATE_ISTIO_ROOT=false
ONLY_PATHS=()

usage() {
  cat >&2 <<EOF
Usage: ${0##*/} [--regenerate] [--only <path>]...

  --regenerate   Regenerate auto-generated secrets even when they already have a
                 value in Vault. Externally minted credentials (generate: false)
                 and template-pinned values are left unchanged.

                 This overwrites live secrets: each 'vault kv put' bumps the KV
                 version, so on a running cluster the dependent ExternalSecrets
                 must re-sync and their consuming pods restart before the new
                 values take effect. scripts/rotate-cred.sh does that part.

  --only <path>  Only write this template path (repeatable). Everything else in
                 the template is left alone.

Istio CA: ordinary runs create a missing bundle or validate/preserve it.
--regenerate preserves it unless --only istio/ca is explicitly selected; that
renews the intermediate/key under the existing root. --rotate-istio-root also
replaces the root, and requires --regenerate --only istio/ca (alone). This only
updates Vault; use rotate-cred.sh for live delivery. Root replacement requires
a separate maintenance plan for enrolled meshes; see README.md.
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --regenerate) REGENERATE=true ;;
      --rotate-istio-root) ROTATE_ISTIO_ROOT=true ;;
      --only)
        [[ $# -ge 2 ]] || { echo "Error: --only needs a path" >&2; usage; exit 1; }
        ONLY_PATHS+=("$2"); shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Error: unknown argument '$1'" >&2; usage; exit 1 ;;
    esac
    shift
  done
}

# Fail loudly on a typo rather than silently writing nothing.
validate_only_paths() {
  if [[ "${ROTATE_ISTIO_ROOT}" == true ]]; then
    if [[ "${REGENERATE}" != true || ${#ONLY_PATHS[@]} -ne 1 || "${ONLY_PATHS[0]:-}" != istio/ca ]]; then
      echo 'Error: --rotate-istio-root requires --regenerate --only istio/ca, alone.' >&2
      exit 1
    fi
  fi
  (( ${#ONLY_PATHS[@]} )) || return 0
  local p
  for p in "${ONLY_PATHS[@]}"; do
    if ! yq -e --arg p "${p}" '.secrets[] | select(.path == $p)' "${TEMPLATE}" >/dev/null 2>&1; then
      echo "Error: --only '${p}' is not a path in ${TEMPLATE##*/}" >&2
      exit 1
    fi
  done
}

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
# Operator-only material must never be readable by the cluster AppRole.
path "${KV_MOUNT}/data/operator"       { capabilities = ["deny"] }
path "${KV_MOUNT}/data/operator/*"     { capabilities = ["deny"] }
path "${KV_MOUNT}/metadata/operator"   { capabilities = ["deny"] }
path "${KV_MOUNT}/metadata/operator/*" { capabilities = ["deny"] }
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

# Walk the template, emitting "path field generate format" quads. `generate` is
# "true" by default; entries that set `generate: false` (e.g. externally minted
# credentials like Harbor robots) must be populated from vault or the secrets
# file and will fail the run rather than fall through to random generation.
# `format` defaults to "password"; set `format: fernet` for Fernet keys,
# `format: hex` for consumers that require a hex-encoded secret, or
# `format: key32` for a 32-character key.
extract_template_entries() {
  local only_json='[]'
  if (( ${#ONLY_PATHS[@]} )); then
    only_json="$(printf '%s\n' "${ONLY_PATHS[@]}" | jq -R . | jq -s -c .)"
  fi
  yq -r --argjson only "${only_json}" '
    .secrets[] as $s
    | select(($only | length) == 0 or ($only | index($s.path)))
    | select($s.generator != "istio-ca")
    | (if $s.generate == false then "false" else "true" end) as $g
    | ($s.format // "password") as $fmt
    | $s.fields[]? as $f
    | "\($s.path) \($f) \($g) \($fmt)"
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

# 30 random bytes encoded as url-safe base64 (40 chars, no '=' padding).
# 30 bytes is a multiple of 3, so base64 encoding needs no padding — the result
# is double-click selectable as a single token.
generate_random() {
  openssl rand -base64 30 | tr -d '\n' | tr '/+' '_-'
}

# Fernet key: exactly 32 random bytes encoded as url-safe base64 (44 chars).
# 32 bytes is NOT a multiple of 3, so one '=' padding char is required.
# cryptography.fernet.Fernet decodes the key and requires exactly 32 bytes.
generate_fernet_key() {
  openssl rand -base64 32 | tr -d '\n' | tr '/+' '_-'
}

# 32 random bytes as a lowercase hex string (64 chars, always even length).
generate_hex() {
  openssl rand -hex 32 | tr -d '\n'
}

# 24 random bytes encoded as url-safe base64 (exactly 32 chars, no padding),
# for consumers that need a 32-character key (e.g. Zitadel's masterkey).
generate_key32() {
  openssl rand -base64 24 | tr -d '\n' | tr '/+' '_-'
}

# CA fields are interdependent. Read one KV version, validate the complete
# signing bundle, then create/replace atomically with CAS. Root keys are stored
# in immutable, operator-only records addressed by the public root fingerprint.
# Publishing that record first means a failed signing-bundle write leaves the
# active root unchanged; it can only leave an unused protected root record.
# A subshell contains the
# private temporary directory and its cleanup trap, including on failure.
write_istio_ca() (
  set -euo pipefail
  umask 077
  local ca_dir version=0 exists=false renew=false field kind cert root_id root_path new_root=false
  ca_dir="$(mktemp -d "${TMPDIR:-/tmp}/homelab-istio-ca.XXXXXX")"
  trap 'rm -rf -- "${ca_dir}"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  if vault kv metadata get -mount="${KV_MOUNT}" -format=json istio/ca > "${ca_dir}/metadata.json" 2> "${ca_dir}/error"; then
    exists=true
    # A deleted/destroyed version is not permission to invent a new identity.
    vault kv get -mount="${KV_MOUNT}" -format=json istio/ca > "${ca_dir}/before.json"
    version="$(jq -er '.data.metadata.version | numbers' "${ca_dir}/before.json")"
    if jq -e '.data.data | has("root-key.pem")' "${ca_dir}/before.json" >/dev/null; then
      echo 'Error: legacy istio/ca contains a root private key; operator remediation and historical-version cleanup are required (see README.md).' >&2
      exit 1
    fi
    for field in ca-cert.pem ca-key.pem root-cert.pem cert-chain.pem; do
      jq -ej --arg field "${field}" '.data.data[$field] | select(type == "string" and length > 0)' \
        "${ca_dir}/before.json" > "${ca_dir}/${field}" \
        || { echo "Error: istio/ca has a missing/invalid ${field}; refusing partial repair." >&2; exit 1; }
    done
    root_id="$(openssl x509 -in "${ca_dir}/root-cert.pem" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':' | tr '[:upper:]' '[:lower:]')"
    root_path="operator/istio-roots/${root_id}"
    vault kv get -mount="${KV_MOUNT}" -format=json "${root_path}" > "${ca_dir}/root.json"
    jq -ej '.data.data["root-key.pem"] | select(type == "string" and length > 0)' \
      "${ca_dir}/root.json" > "${ca_dir}/root-key.pem"
    jq -ej '.data.data["root-cert.pem"] | select(type == "string" and length > 0)' \
      "${ca_dir}/root.json" > "${ca_dir}/stored-root-cert.pem"
    openssl x509 -in "${ca_dir}/root-cert.pem" -outform DER > "${ca_dir}/public-root.der"
    openssl x509 -in "${ca_dir}/stored-root-cert.pem" -outform DER > "${ca_dir}/stored-root.der"
    cmp -s "${ca_dir}/public-root.der" "${ca_dir}/stored-root.der" \
      || { echo 'Error: operator root record does not match the signing bundle.' >&2; exit 1; }
  elif ! grep -q '^No value found at ' "${ca_dir}/error"; then
    echo 'Error: cannot read istio/ca metadata; refusing to treat a Vault error as an absent CA.' >&2
    cat "${ca_dir}/error" >&2
    exit 1
  fi

  if [[ "${REGENERATE}" == true ]] && (( ${#ONLY_PATHS[@]} )) && printf '%s\n' "${ONLY_PATHS[@]}" | grep -qxF istio/ca; then
    renew=true
  fi

  validate_bundle() {
    local stem
    for stem in root ca; do
      [[ "$(grep -c '^-----BEGIN CERTIFICATE-----' "${ca_dir}/${stem}-cert.pem")" == 1 ]] || return 1
      openssl pkey -in "${ca_dir}/${stem}-key.pem" -check -noout >/dev/null || return 1
      openssl pkey -in "${ca_dir}/${stem}-key.pem" -pubout -outform DER > "${ca_dir}/key.der" || return 1
      openssl x509 -in "${ca_dir}/${stem}-cert.pem" -pubkey -noout \
        | openssl pkey -pubin -outform DER > "${ca_dir}/cert.der" || return 1
      cmp -s "${ca_dir}/key.der" "${ca_dir}/cert.der" \
        || { echo "Error: istio/ca ${stem} key/certificate mismatch." >&2; return 1; }
      openssl x509 -in "${ca_dir}/${stem}-cert.pem" -noout -text > "${ca_dir}/cert.txt" || return 1
      grep -q 'CA:TRUE' "${ca_dir}/cert.txt" || return 1
      grep -q 'Certificate Sign' "${ca_dir}/cert.txt" || return 1
    done
    openssl verify -no_check_time -CAfile "${ca_dir}/root-cert.pem" "${ca_dir}/root-cert.pem" >/dev/null || return 1
    openssl verify -no_check_time -CAfile "${ca_dir}/root-cert.pem" "${ca_dir}/ca-cert.pem" >/dev/null || return 1
    # Check both entries of the delivered chain, not just the signing cert.
    awk -v dir="${ca_dir}" '/-----BEGIN CERTIFICATE-----/ {n++} n {print > (dir "/chain-" n ".pem")} END {if (n != 2) exit 1}' \
      "${ca_dir}/cert-chain.pem" || return 1
    for kind in '1 ca' '2 root'; do
      read -r field cert <<< "${kind}"
      openssl x509 -in "${ca_dir}/chain-${field}.pem" -outform DER > "${ca_dir}/chain.der" || return 1
      openssl x509 -in "${ca_dir}/${cert}-cert.pem" -outform DER > "${ca_dir}/cert.der" || return 1
      cmp -s "${ca_dir}/chain.der" "${ca_dir}/cert.der" || return 1
    done
  }

  if [[ "${exists}" == true ]]; then
    validate_bundle || { echo 'Error: invalid istio/ca bundle; refusing replacement.' >&2; exit 1; }
    if [[ "${renew}" != true ]]; then
      openssl verify -CAfile "${ca_dir}/root-cert.pem" "${ca_dir}/ca-cert.pem" >/dev/null
      echo '>>> Validated existing Istio CA; preserving its Vault version'
      return 0
    fi
  elif [[ "${renew}" == true ]]; then
    echo 'Error: cannot rotate a missing Istio CA; seed it without --regenerate first.' >&2
    exit 1
  fi

  cat > "${ca_dir}/ca.cnf" <<'EOF'
[req]
distinguished_name = dn
prompt = no
[dn]
O = Homelab
[root_ca]
basicConstraints = critical,CA:true,pathlen:1
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
[intermediate_ca]
basicConstraints = critical,CA:true,pathlen:0
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
EOF
  if [[ "${exists}" != true || "${ROTATE_ISTIO_ROOT}" == true ]]; then
    new_root=true
    openssl genrsa -out "${ca_dir}/root-key.pem" 4096
    openssl req -new -x509 -sha256 -days 3650 \
      -key "${ca_dir}/root-key.pem" -out "${ca_dir}/root-cert.pem" \
      -config "${ca_dir}/ca.cnf" -extensions root_ca \
      -subj '/O=Homelab/CN=Homelab Root CA'
  fi
  openssl x509 -in "${ca_dir}/root-cert.pem" -checkend 31622400 -noout >/dev/null \
    || { echo 'Error: root must outlive the next one-year intermediate; plan root replacement.' >&2; exit 1; }
  openssl genrsa -out "${ca_dir}/ca-key.pem" 4096
  openssl req -new -sha256 -key "${ca_dir}/ca-key.pem" -out "${ca_dir}/ca.csr" \
    -subj '/O=Homelab/CN=Homelab Istio Intermediate CA'
  openssl x509 -req -sha256 -days 365 -in "${ca_dir}/ca.csr" \
    -CA "${ca_dir}/root-cert.pem" -CAkey "${ca_dir}/root-key.pem" \
    -set_serial "0x$(openssl rand -hex 16)" \
    -extfile "${ca_dir}/ca.cnf" -extensions intermediate_ca -out "${ca_dir}/ca-cert.pem"
  cat "${ca_dir}/ca-cert.pem" "${ca_dir}/root-cert.pem" > "${ca_dir}/cert-chain.pem"
  validate_bundle
  openssl verify -CAfile "${ca_dir}/root-cert.pem" "${ca_dir}/ca-cert.pem" >/dev/null
  if [[ "${new_root}" == true ]]; then
    root_id="$(openssl x509 -in "${ca_dir}/root-cert.pem" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':' | tr '[:upper:]' '[:lower:]')"
    root_path="operator/istio-roots/${root_id}"
    echo ">>> Creating protected root record ${root_path}"
    vault kv put -mount="${KV_MOUNT}" -cas=0 "${root_path}" \
      root-cert.pem=@"${ca_dir}/root-cert.pem" root-key.pem=@"${ca_dir}/root-key.pem"
  fi
  echo ">>> Writing Istio CA bundle (expected KV version ${version})"
  vault kv put -mount="${KV_MOUNT}" -cas="${version}" istio/ca \
    ca-cert.pem=@"${ca_dir}/ca-cert.pem" ca-key.pem=@"${ca_dir}/ca-key.pem" \
    root-cert.pem=@"${ca_dir}/root-cert.pem" \
    cert-chain.pem=@"${ca_dir}/cert-chain.pem"
  openssl x509 -in "${ca_dir}/ca-cert.pem" -noout -fingerprint -sha256 -dates
)

write_bundle_entries() {
  local path generator selected
  while read -r path generator; do
    selected=true
    if (( ${#ONLY_PATHS[@]} )) && ! printf '%s\n' "${ONLY_PATHS[@]}" | grep -qxF "${path}"; then
      selected=false
    fi
    [[ "${selected}" == true ]] || continue
    if [[ "${generator}" != istio-ca || "${path}" != istio/ca ]]; then
      echo "Error: unsupported bundle generator ${generator} for ${path}." >&2
      return 1
    fi
    write_istio_ca
  done < <(yq -r '.secrets[] | select(.generator != null) | "\(.path) \(.generator)"' "${TEMPLATE}")
}

resolve_value() {
  local path="$1" field="$2" generate="$3" format="${4:-password}" value
  # --regenerate drops the Vault lookup for generatable entries so an existing
  # value can't short-circuit regeneration; the template default (if any) still
  # wins, and generate=false entries keep their Vault-backed value.
  local sources=(fetch_from_vault fetch_from_template)
  if [[ "${REGENERATE}" == "true" && "${generate}" != "false" ]]; then
    sources=(fetch_from_template)
  fi
  for src in "${sources[@]}"; do
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
  if [[ "${format}" == "fernet" ]]; then
    generate_fernet_key
  elif [[ "${format}" == "hex" ]]; then
    generate_hex
  elif [[ "${format}" == "key32" ]]; then
    generate_key32
  else
    generate_random
  fi
}

write_kv_entries() {
  local current_path="" payload=() value
  while read -r path field generate format; do
    if [[ "${path}" != "${current_path}" ]]; then
      if [[ -n "${current_path}" ]]; then
        echo ">>> Writing ${KV_MOUNT}/${current_path}"
        vault kv put "${KV_MOUNT}/${current_path}" "${payload[@]}"
      fi
      current_path="${path}"
      payload=()
    fi
    value="$(resolve_value "${path}" "${field}" "${generate}" "${format}")"
    payload+=("${field}=${value}")
  done < <(extract_template_entries)
  if [[ -n "${current_path}" ]]; then
    echo ">>> Writing ${KV_MOUNT}/${current_path}"
    vault kv put "${KV_MOUNT}/${current_path}" "${payload[@]}"
  fi
}

main() {
  parse_args "$@"
  validate_only_paths
  ensure_kv_mount
  ensure_approle_mount
  write_policy
  ensure_role
  write_bundle_entries
  write_kv_entries
  echo
  echo "Seeding complete."
  echo "Next: continue with the first-time bootstrap section in README.md (terraform apply, then ansible bootstrap-k8s.yml)."
}

main "$@"
