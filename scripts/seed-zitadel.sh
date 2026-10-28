#!/usr/bin/env bash
# Apply scripts/zitadel.template.yaml to Zitadel through its API: rename the
# break-glass admin, ensure the GitHub/Google login providers, and reconcile
# the allowed users (missing ones created, unlisted humans deleted, IAM_OWNER
# granted or revoked). Idempotent: re-running converges on the template.
#
# Prereqs:
#   - kubectl pointed at the cluster (reads the iam-admin-pat Secret that
#     Zitadel's setup Job writes into the zitadel namespace)
#   - vault CLI with VAULT_ADDR and VAULT_TOKEN exported (reads idp/* paths)
#   - curl, jq, yq on PATH
#
# Waits up to WAIT_SECONDS (default 1800) for Zitadel to come up, so it can run
# straight after the root app is applied during bootstrap.

set -euo pipefail

: "${VAULT_ADDR:?VAULT_ADDR must be set}"
: "${VAULT_TOKEN:?VAULT_TOKEN must be set}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
TEMPLATE="${SCRIPT_DIR}/zitadel.template.yaml"

ZITADEL_URL="${ZITADEL_URL:-https://zitadel.homelab.xiehang.com}"
NAMESPACE="zitadel"
KV_MOUNT="homelab"
WAIT_SECONDS="${WAIT_SECONDS:-1800}"

PAT=""

# Call the Zitadel API. Prints the response body; fails on any status not in
# the 2xx range unless it is listed in OK_CODES (space-separated).
api() {
  local method="$1" path="$2" body="${3:-}" out code
  out="$(mktemp)"
  code="$(curl -sS -o "${out}" -w '%{http_code}' -X "${method}" "${ZITADEL_URL}${path}" \
    -H "Authorization: Bearer ${PAT}" -H 'Content-Type: application/json' \
    ${body:+-d "${body}"})"
  if [[ "${code}" != 2* && " ${OK_CODES:-} " != *" ${code} "* ]]; then
    echo "Error: ${method} ${path} returned HTTP ${code}: $(jq -c '{code, message}' "${out}" 2>/dev/null)" >&2
    rm -f "${out}"
    return 1
  fi
  cat "${out}"
  rm -f "${out}"
}

wait_for_zitadel() {
  local deadline=$((SECONDS + WAIT_SECONDS))
  echo ">>> Waiting for Zitadel at ${ZITADEL_URL}"
  until kubectl -n "${NAMESPACE}" get secret iam-admin-pat >/dev/null 2>&1 \
      && curl -fsS -o /dev/null "${ZITADEL_URL}/debug/ready"; do
    if (( SECONDS >= deadline )); then
      echo "Error: Zitadel not ready after ${WAIT_SECONDS}s" >&2
      exit 1
    fi
    sleep 10
  done
  PAT="$(kubectl -n "${NAMESPACE}" get secret iam-admin-pat -o jsonpath='{.data.pat}' | base64 -d)"
}

# Setup creates the first admin as <username>@<org domain>; rename it.
ensure_admin_username() {
  local username id
  username="$(yq -r '.admin.username' "${TEMPLATE}")"
  id="$(api POST /v2/users "$(jq -nc --arg u "${username}" \
    '{queries: [{userNameQuery: {userName: $u, method: "TEXT_QUERY_METHOD_EQUALS"}}]}')" \
    | jq -r '.result[0].userId // empty')"
  if [[ -n "${id}" ]]; then
    echo ">>> Admin username already '${username}'"
    return
  fi
  id="$(api POST /v2/users "$(jq -nc --arg u "${username}@" \
    '{queries: [{userNameQuery: {userName: $u, method: "TEXT_QUERY_METHOD_STARTS_WITH"}}]}')" \
    | jq -r '.result[0].userId // empty')"
  if [[ -z "${id}" ]]; then
    echo "Error: no user named '${username}' or '${username}@...' to rename" >&2
    exit 1
  fi
  echo ">>> Renaming admin to '${username}'"
  api PUT "/v2/users/human/${id}" "$(jq -nc --arg u "${username}" '{username: $u}')" >/dev/null
}

# Instance-level provider, so it applies to every org. Linking by verified
# email onto a pre-created user is allowed; creating accounts is not.
ensure_idp() {
  local name="$1" type="$2" vault_path="$3" scopes="$4" id client_id client_secret body
  client_id="$(vault kv get -field=client-id "${KV_MOUNT}/${vault_path}")"
  client_secret="$(vault kv get -field=client-secret "${KV_MOUNT}/${vault_path}")"
  body="$(jq -nc --arg n "${name}" --arg id "${client_id}" --arg s "${client_secret}" \
    --argjson scopes "${scopes}" '{
      name: $n, clientId: $id, clientSecret: $s, scopes: $scopes,
      providerOptions: {
        isLinkingAllowed: true, isCreationAllowed: false,
        isAutoCreation: false, isAutoUpdate: true,
        autoLinking: "AUTO_LINKING_OPTION_EMAIL"
      }
    }')"
  id="$(api POST /admin/v1/idps/templates/_search '{}' \
    | jq -r --arg n "${name}" '.result[]? | select(.name == $n) | .id' | head -n1)"
  if [[ -z "${id}" ]]; then
    echo ">>> Creating ${name} provider"
    id="$(api POST "/admin/v1/idps/${type}" "${body}" | jq -r '.id')"
  else
    echo ">>> Updating ${name} provider"
    api PUT "/admin/v1/idps/${type}/${id}" "${body}" >/dev/null
  fi
  OK_CODES=409 api POST /admin/v1/policies/login/idps "$(jq -nc --arg id "${id}" '{idpId: $id}')" >/dev/null
}

# Lists are captured before looping: a failure inside `< <(...)` would not
# trip set -e, and the loop would silently run over nothing.
ensure_idps() {
  local idps idp
  idps="$(yq -c '.idps[]' "${TEMPLATE}")"
  while read -r idp; do
    [[ -n "${idp}" ]] || continue
    ensure_idp \
      "$(jq -r '.name' <<<"${idp}")" \
      "$(jq -r '.type' <<<"${idp}")" \
      "$(jq -r '.vault' <<<"${idp}")" \
      "$(jq -c '.scopes' <<<"${idp}")"
  done <<<"${idps}"
}

# Bring an existing user's profile and email back to the template. The template
# is reviewed in Git, the same trust that creates users with a verified email.
# Provider logins link by email, so an email change also drops the existing
# links: accounts linked under the old address must not keep their access.
reconcile_user() {
  local id="$1" user="$2" username current want links idp linked
  username="$(jq -r '.username' <<<"${user}")"
  current="$(api GET "/v2/users/${id}" | jq -ce '.user.human | {
    givenName: .profile.givenName, familyName: .profile.familyName,
    email: .email.email, isVerified: (.email.isVerified // false)
  }')"
  want="$(jq -c '{givenName, familyName, email, isVerified: true}' <<<"${user}")"
  if [[ "${current}" == "${want}" ]]; then
    echo ">>> User ${username} up to date"
    return
  fi
  echo ">>> Updating user ${username}"
  api PUT "/v2/users/human/${id}" "$(jq -c '{
    profile: {givenName, familyName},
    email: {email, isVerified: true}
  }' <<<"${want}")" >/dev/null
  if [[ "$(jq -r '.email' <<<"${current}")" != "$(jq -r '.email' <<<"${want}")" ]]; then
    links="$(api POST "/v2/users/${id}/links/_search" '{}' | jq -r '.result[]? | "\(.idpId) \(.userId)"')"
    while read -r idp linked; do
      [[ -n "${idp}" ]] || continue
      echo ">>> Unlinking ${username} from provider ${idp} (email changed)"
      api DELETE "/v2/users/${id}/links/${idp}/${linked}" >/dev/null
    done <<<"${links}"
  fi
}

# No password: these users only log in through a linked provider.
ensure_user() {
  local user="$1" username id
  username="$(jq -r '.username' <<<"${user}")"
  id="$(api POST /v2/users "$(jq -nc --arg u "${username}" \
    '{queries: [{userNameQuery: {userName: $u, method: "TEXT_QUERY_METHOD_EQUALS"}}]}')" \
    | jq -r '.result[0].userId // empty')"
  if [[ -z "${id}" ]]; then
    echo ">>> Creating user ${username}"
    id="$(api POST /v2/users/human "$(jq -c '{
      username: .username,
      profile: {givenName: .givenName, familyName: .familyName},
      email: {email: .email, isVerified: true}
    }' <<<"${user}")" | jq -r '.userId')"
  else
    reconcile_user "${id}" "${user}"
  fi
  if [[ "$(jq -r '.iamOwner // false' <<<"${user}")" == "true" ]]; then
    OK_CODES=409 api POST /admin/v1/members \
      "$(jq -nc --arg id "${id}" '{userId: $id, roles: ["IAM_OWNER"]}')" >/dev/null
  else
    OK_CODES=404 api DELETE "/admin/v1/members/${id}" >/dev/null
  fi
}

# The template is the allowlist: delete every other human except the
# break-glass admin, which also drops its provider links and memberships.
# Machine users (iam-admin) are left alone.
# Every human user, all pages, as one JSON array. Fetched completely before
# anything is deleted so a deletion never shifts the pages being read.
# Callers run this inside $(...), where set -e is off, so every step returns
# on failure explicitly.
list_humans() {
  local limit=100 offset=0 total page all='[]'
  while :; do
    # `.result` must be an array: a response without one fails here rather
    # than reading as "no users". The admin always exists.
    page="$(api POST /v2/users "$(jq -nc --argjson o "${offset}" --argjson l "${limit}" \
      '{query: {offset: $o, limit: $l}, queries: [{typeQuery: {type: "TYPE_HUMAN"}}]}')")" || return 1
    all="$(jq -ce --argjson page "${page}" '. + ($page.result | arrays)' <<<"${all}")" \
      || { echo "Error: user list response at offset ${offset} has no result array" >&2; return 1; }
    total="$(jq -re '.details.totalResult | tonumber' <<<"${page}")" || return 1
    offset=$((offset + limit))
    (( offset < total )) || break
  done
  if [[ "$(jq length <<<"${all}")" != "${total}" ]]; then
    echo "Error: listed $(jq length <<<"${all}") human users, Zitadel reports ${total}" >&2
    return 1
  fi
  echo "${all}"
}

remove_unlisted_users() {
  local allowed humans unlisted username id
  allowed="$(yq -c '[.users[].username] + [.admin.username]' "${TEMPLATE}")"
  humans="$(list_humans)"
  unlisted="$(jq -r --argjson allowed "${allowed}" \
    '.[] | select(.username as $u | $allowed | index($u) | not) | "\(.userId) \(.username)"' <<<"${humans}")"
  while read -r id username; do
    [[ -n "${id}" ]] || continue
    echo ">>> Removing user ${username} (not in ${TEMPLATE##*/})"
    api DELETE "/v2/users/${id}" >/dev/null
  done <<<"${unlisted}"
}

ensure_users() {
  local users user
  users="$(yq -c '.users[]' "${TEMPLATE}")"
  while read -r user; do
    [[ -n "${user}" ]] || continue
    ensure_user "${user}"
  done <<<"${users}"
  remove_unlisted_users
}

main() {
  wait_for_zitadel
  ensure_admin_username
  ensure_idps
  ensure_users
  echo
  echo "Zitadel seeding complete."
}

main "$@"
