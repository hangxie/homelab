#!/usr/bin/env bash
# Apply scripts/zitadel.template.yaml to Zitadel through its API: rename the
# break-glass admin, ensure the GitHub/Google login providers, the app project
# with its roles and OIDC clients, and reconcile the listed users (missing ones
# created; profile, IAM_OWNER and project roles set). Users not listed are left
# alone. Idempotent: re-running converges on the template.
#
# Zitadel generates OIDC client secrets itself and returns them only once, so
# each client's id/secret is written to Vault oidc/<name> when the client is
# created, when Vault does not hold its current client id (e.g. after a Nuke),
# or with --regenerate, which mints a fresh secret for every client.
#
# Prereqs:
#   - kubectl pointed at the cluster (reads the iam-admin-pat Secret that
#     Zitadel's setup Job writes into the zitadel namespace)
#   - vault CLI with VAULT_ADDR and VAULT_TOKEN exported (reads idp/*, writes
#     oidc/*)
#   - curl, jq, yq on PATH
#
# Waits up to WAIT_SECONDS (default 1800) for Zitadel to come up, so it can run
# straight after the root app is applied during bootstrap.

set -euo pipefail

REGENERATE=false
case "${1:-}" in
  "") ;;
  --regenerate) REGENERATE=true ;;
  *) echo "Usage: ${0##*/} [--regenerate]" >&2; exit 1 ;;
esac

: "${VAULT_ADDR:?VAULT_ADDR must be set}"
: "${VAULT_TOKEN:?VAULT_TOKEN must be set}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
TEMPLATE="${SCRIPT_DIR}/zitadel.template.yaml"

ZITADEL_URL="${ZITADEL_URL:-https://zitadel.homelab.xiehang.com}"
NAMESPACE="zitadel"
KV_MOUNT="homelab"
WAIT_SECONDS="${WAIT_SECONDS:-1800}"

PAT=""
PROJECT_ID=""

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

# The break-glass admin's project roles, so it can sign in to apps when GitHub
# and Google are unreachable. It is IAM owner anyway, so this adds no privilege.
ensure_admin_grant() {
  local admin id
  admin="$(yq -c '.admin' "${TEMPLATE}")"
  id="$(api POST /v2/users "$(jq -nc --arg u "$(jq -r '.username' <<<"${admin}")" \
    '{queries: [{userNameQuery: {userName: $u, method: "TEXT_QUERY_METHOD_EQUALS"}}]}')" \
    | jq -r '.result[0].userId')"
  ensure_user_grant "${id}" "${admin}"
}

# Instance-level provider, so it applies to every org. A first login links by
# verified email to a listed user, or else creates an account with no role grant.
ensure_idp() {
  local name="$1" type="$2" vault_path="$3" scopes="$4" id client_id client_secret body
  client_id="$(vault kv get -field=client-id "${KV_MOUNT}/${vault_path}")"
  client_secret="$(vault kv get -field=client-secret "${KV_MOUNT}/${vault_path}")"
  body="$(jq -nc --arg n "${name}" --arg id "${client_id}" --arg s "${client_secret}" \
    --argjson scopes "${scopes}" '{
      name: $n, clientId: $id, clientSecret: $s, scopes: $scopes,
      providerOptions: {
        isLinkingAllowed: true, isCreationAllowed: true,
        isAutoCreation: true, isAutoUpdate: true,
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

ensure_oidc_settings() {
  local want current
  want="$(yq -c '.oidcSettings | {accessTokenLifetime, idTokenLifetime,
    refreshTokenIdleExpiration, refreshTokenExpiration}' "${TEMPLATE}")"
  current="$(api GET /admin/v1/settings/oidc | jq -c '.settings | {accessTokenLifetime, idTokenLifetime,
    refreshTokenIdleExpiration, refreshTokenExpiration}')"
  if [[ "${current}" == "${want}" ]]; then
    echo ">>> OIDC token lifetimes up to date"
  else
    echo ">>> Setting OIDC token lifetimes"
    api PUT /admin/v1/settings/oidc "${want}" >/dev/null
  fi
}

# Only the lifetimes come from the template; the rest of the instance login
# policy is read back and resent, since the update replaces the whole policy.
ensure_login_policy() {
  local current want
  current="$(api GET /admin/v1/policies/login | jq -c '.policy | {
    allowUsernamePassword: (.allowUsernamePassword // false),
    allowRegister: (.allowRegister // false),
    allowExternalIdp: (.allowExternalIdp // false),
    forceMfa: (.forceMfa // false),
    forceMfaLocalOnly: (.forceMfaLocalOnly // false),
    passwordlessType: (.passwordlessType // "PASSWORDLESS_TYPE_NOT_ALLOWED"),
    hidePasswordReset: (.hidePasswordReset // false),
    ignoreUnknownUsernames: (.ignoreUnknownUsernames // false),
    defaultRedirectUri: (.defaultRedirectUri // ""),
    allowDomainDiscovery: (.allowDomainDiscovery // false),
    disableLoginWithEmail: (.disableLoginWithEmail // false),
    disableLoginWithPhone: (.disableLoginWithPhone // false),
    passwordCheckLifetime, externalLoginCheckLifetime, mfaInitSkipLifetime,
    secondFactorCheckLifetime, multiFactorCheckLifetime
  }')"
  want="$(jq -c --argjson t "$(yq -c '.loginPolicy' "${TEMPLATE}")" '. + $t' <<<"${current}")"
  if [[ "${current}" == "${want}" ]]; then
    echo ">>> Login policy lifetimes up to date"
  else
    echo ">>> Setting login policy lifetimes"
    api PUT /admin/v1/policies/login "${want}" >/dev/null
    # The Login UI caches the policy and keeps creating sessions with the old
    # lifetimes until restarted.
    echo ">>> Restarting the Login UI"
    kubectl -n "${NAMESPACE}" rollout restart deploy/zitadel-login >/dev/null
  fi
}

# Zitadel asserts project roles as a map keyed by role, which most apps cannot
# map; this Action adds the user's role keys as a plain `groups` list to
# userinfo (and so the ID token) and to access tokens. Some tokens (the
# console's) carry no grant list at all, and a failing Action fails the token
# request, so it reads defensively and is allowed to fail: without `groups`,
# apps refuse the login anyway. Only grants on the homelab project count, so a
# role in another project can never pass for a homelab one.
GROUPS_ACTION_NAME="groupsClaim"
GROUPS_ACTION_SCRIPT='function groupsClaim(ctx, api) {
  const grants = ctx.v1.user && ctx.v1.user.grants;
  if (!grants || !grants.grants) {
    return;
  }
  let groups = [];
  grants.grants.forEach(grant => {
    if (grant.projectId !== "__PROJECT_ID__") {
      return;
    }
    (grant.roles || []).forEach(role => groups.push(role));
  });
  api.v1.claims.setClaim("groups", groups);
}'

# Needs PROJECT_ID, so it runs after ensure_project.
ensure_groups_action() {
  local body id current trigger flow
  body="$(jq -nc --arg n "${GROUPS_ACTION_NAME}" --arg p "${PROJECT_ID}" --arg s "${GROUPS_ACTION_SCRIPT}" \
    '{name: $n, script: ($s | sub("__PROJECT_ID__"; $p)), timeout: "10s", allowedToFail: true}')"
  current="$(api POST /management/v1/actions/_search '{}' | jq -c --arg n "${GROUPS_ACTION_NAME}" \
    '.result[]? | select(.name == $n) | {id, name, script, timeout, allowedToFail: (.allowedToFail // false)}')"
  if [[ -z "${current}" ]]; then
    echo ">>> Creating action ${GROUPS_ACTION_NAME}"
    id="$(api POST /management/v1/actions "${body}" | jq -r '.id')"
  else
    id="$(jq -r '.id' <<<"${current}")"
    if [[ "$(jq -c 'del(.id)' <<<"${current}")" == "${body}" ]]; then
      echo ">>> Action ${GROUPS_ACTION_NAME} up to date"
    else
      echo ">>> Updating action ${GROUPS_ACTION_NAME}"
      api PUT "/management/v1/actions/${id}" "${body}" >/dev/null
    fi
  fi
  # Flow 2 is Complement Token; triggers 4 and 5 run before userinfo and
  # access token creation. Setting a trigger replaces its action list, and
  # setting it unchanged is an error.
  flow="$(api GET /management/v1/flows/2)"
  for trigger in 4 5; do
    if [[ "$(jq -c --arg t "${trigger}" \
        '[.flow.triggerActions[]? | select(.triggerType.id == $t) | .actions[].id]' <<<"${flow}")" \
        != "$(jq -nc --arg id "${id}" '[$id]')" ]]; then
      echo ">>> Setting action ${GROUPS_ACTION_NAME} on token trigger ${trigger}"
      api POST "/management/v1/flows/2/trigger/${trigger}" \
        "$(jq -nc --arg id "${id}" '{actionIds: [$id]}')" >/dev/null
    fi
  done
}

# Role check makes a login fail for users without a grant on the project; role
# assertion puts the granted roles into tokens and userinfo.
ensure_project() {
  local name body current
  name="$(yq -r '.project.name' "${TEMPLATE}")"
  body="$(jq -nc --arg n "${name}" \
    '{name: $n, projectRoleAssertion: true, projectRoleCheck: true, hasProjectCheck: false}')"
  current="$(api POST /management/v1/projects/_search "$(jq -nc --arg n "${name}" \
    '{queries: [{nameQuery: {name: $n, method: "TEXT_QUERY_METHOD_EQUALS"}}]}')" \
    | jq -c '.result[0] // empty | {id, name,
        projectRoleAssertion: (.projectRoleAssertion // false),
        projectRoleCheck: (.projectRoleCheck // false),
        hasProjectCheck: (.hasProjectCheck // false)}')"
  if [[ -z "${current}" ]]; then
    echo ">>> Creating project ${name}"
    PROJECT_ID="$(api POST /management/v1/projects "${body}" | jq -r '.id')"
    return
  fi
  PROJECT_ID="$(jq -r '.id' <<<"${current}")"
  if [[ "$(jq -c 'del(.id)' <<<"${current}")" == "${body}" ]]; then
    echo ">>> Project ${name} up to date"
  else
    echo ">>> Updating project ${name}"
    api PUT "/management/v1/projects/${PROJECT_ID}" "${body}" >/dev/null
  fi
}

# Removing a role also drops it from every user grant.
ensure_project_roles() {
  local want have key
  want="$(yq -c '.project.roles' "${TEMPLATE}")"
  have="$(api POST "/management/v1/projects/${PROJECT_ID}/roles/_search" '{}' | jq -c '[.result[]?.key]')"
  for key in $(jq -r --argjson have "${have}" '.[] | select(. as $k | $have | index($k) | not)' <<<"${want}"); do
    echo ">>> Adding project role ${key}"
    api POST "/management/v1/projects/${PROJECT_ID}/roles" \
      "$(jq -nc --arg k "${key}" '{roleKey: $k, displayName: $k}')" >/dev/null
  done
  for key in $(jq -r --argjson want "${want}" '.[] | select(. as $k | $want | index($k) | not)' <<<"${have}"); do
    echo ">>> Removing project role ${key}"
    api DELETE "/management/v1/projects/${PROJECT_ID}/roles/${key}" >/dev/null
  done
}

write_client_secret() {
  local name="$1" client_id="$2" client_secret="$3"
  echo ">>> Writing ${KV_MOUNT}/oidc/${name} to Vault"
  # Through stdin, so the secret never shows up in a process listing.
  jq -nc --arg id "${client_id}" --arg s "${client_secret}" \
    '{"client-id": $id, "client-secret": $s}' \
    | vault kv put "${KV_MOUNT}/oidc/${name}" - >/dev/null
}

# Confidential web client with the authorization code flow. Roles and the
# profile go into the ID token too, for apps that never call userinfo. JWT
# access tokens: apps that try to decode an opaque token log it verbatim.
ensure_client() {
  local client="$1" apps="$2" name want current app_id client_id created stored stored_secret
  name="$(jq -r '.name' <<<"${client}")"
  want="$(jq -c '{
    redirectUris: (.redirectUris | sort),
    postLogoutRedirectUris: ((.postLogoutRedirectUris // []) | sort),
    responseTypes: ["OIDC_RESPONSE_TYPE_CODE"],
    grantTypes: ["OIDC_GRANT_TYPE_AUTHORIZATION_CODE", "OIDC_GRANT_TYPE_REFRESH_TOKEN"],
    appType: "OIDC_APP_TYPE_WEB",
    authMethodType: "OIDC_AUTH_METHOD_TYPE_BASIC",
    accessTokenType: "OIDC_TOKEN_TYPE_JWT",
    accessTokenRoleAssertion: true,
    idTokenRoleAssertion: true,
    idTokenUserinfoAssertion: true,
    devMode: false
  }' <<<"${client}")"
  current="$(jq -c --arg n "${name}" '.[] | select(.name == $n)' <<<"${apps}")"
  if [[ -z "${current}" ]]; then
    echo ">>> Creating OIDC client ${name}"
    created="$(api POST "/management/v1/projects/${PROJECT_ID}/apps/oidc" \
      "$(jq -c --arg n "${name}" '. + {name: $n, version: "OIDC_VERSION_1_0"}' <<<"${want}")")"
    write_client_secret "${name}" "$(jq -r '.clientId' <<<"${created}")" "$(jq -r '.clientSecret' <<<"${created}")"
    return
  fi
  app_id="$(jq -r '.id' <<<"${current}")"
  client_id="$(jq -r '.oidcConfig.clientId' <<<"${current}")"
  # Responses omit fields at their zero value, the first value of each enum.
  if [[ "$(jq -c '.oidcConfig | {
    redirectUris: ((.redirectUris // []) | sort),
    postLogoutRedirectUris: ((.postLogoutRedirectUris // []) | sort),
    responseTypes: (.responseTypes // ["OIDC_RESPONSE_TYPE_CODE"]),
    grantTypes: (.grantTypes // ["OIDC_GRANT_TYPE_AUTHORIZATION_CODE"]),
    appType: (.appType // "OIDC_APP_TYPE_WEB"),
    authMethodType: (.authMethodType // "OIDC_AUTH_METHOD_TYPE_BASIC"),
    accessTokenType: (.accessTokenType // "OIDC_TOKEN_TYPE_BEARER"),
    accessTokenRoleAssertion: (.accessTokenRoleAssertion // false),
    idTokenRoleAssertion: (.idTokenRoleAssertion // false),
    idTokenUserinfoAssertion: (.idTokenUserinfoAssertion // false),
    devMode: (.devMode // false)
  }' <<<"${current}")" == "${want}" ]]; then
    echo ">>> OIDC client ${name} up to date"
  else
    echo ">>> Updating OIDC client ${name}"
    api PUT "/management/v1/projects/${PROJECT_ID}/apps/${app_id}/oidc_config" "${want}" >/dev/null
  fi
  # Zitadel never returns a secret, so a stale one cannot be detected here;
  # only a missing one. Recover from a stale one with --regenerate.
  stored="$(vault kv get -field=client-id "${KV_MOUNT}/oidc/${name}" 2>/dev/null || true)"
  stored_secret="$(vault kv get -field=client-secret "${KV_MOUNT}/oidc/${name}" 2>/dev/null || true)"
  if [[ "${REGENERATE}" == "true" || "${stored}" != "${client_id}" || -z "${stored_secret}" ]]; then
    echo ">>> Generating a new secret for OIDC client ${name}"
    write_client_secret "${name}" "${client_id}" "$(api POST \
      "/management/v1/projects/${PROJECT_ID}/apps/${app_id}/oidc_config/_generate_client_secret" '{}' \
      | jq -r '.clientSecret')"
  fi
}

# Confidential API client with client-secret (basic) auth: it never logs users
# in, it only introspects tokens (e.g. Authorino for the Gateway).
ensure_api_client() {
  local client="$1" apps="$2" name current app_id client_id created stored stored_secret
  name="$(jq -r '.name' <<<"${client}")"
  current="$(jq -c --arg n "${name}" '.[] | select(.name == $n)' <<<"${apps}")"
  if [[ -z "${current}" ]]; then
    echo ">>> Creating API client ${name}"
    created="$(api POST "/management/v1/projects/${PROJECT_ID}/apps/api" \
      "$(jq -nc --arg n "${name}" '{name: $n, authMethodType: "API_AUTH_METHOD_TYPE_BASIC"}')")"
    write_client_secret "${name}" "$(jq -r '.clientId' <<<"${created}")" "$(jq -r '.clientSecret' <<<"${created}")"
    return
  fi
  app_id="$(jq -r '.id' <<<"${current}")"
  client_id="$(jq -r '.apiConfig.clientId' <<<"${current}")"
  # Responses omit the zero value: BASIC is the first API auth method.
  if [[ "$(jq -r '.apiConfig.authMethodType // "API_AUTH_METHOD_TYPE_BASIC"' <<<"${current}")" == "API_AUTH_METHOD_TYPE_BASIC" ]]; then
    echo ">>> API client ${name} up to date"
  else
    echo ">>> Updating API client ${name}"
    api PUT "/management/v1/projects/${PROJECT_ID}/apps/${app_id}/api_config" \
      '{"authMethodType": "API_AUTH_METHOD_TYPE_BASIC"}' >/dev/null
  fi
  stored="$(vault kv get -field=client-id "${KV_MOUNT}/oidc/${name}" 2>/dev/null || true)"
  stored_secret="$(vault kv get -field=client-secret "${KV_MOUNT}/oidc/${name}" 2>/dev/null || true)"
  if [[ "${REGENERATE}" == "true" || "${stored}" != "${client_id}" || -z "${stored_secret}" ]]; then
    echo ">>> Generating a new secret for API client ${name}"
    write_client_secret "${name}" "${client_id}" "$(api POST \
      "/management/v1/projects/${PROJECT_ID}/apps/${app_id}/api_config/_generate_client_secret" '{}' \
      | jq -r '.clientSecret')"
    # Authorino reads introspection credentials only when an AuthConfig
    # reconciles, never on a Secret change; until then every token gets 401.
    echo ">>> Reload the consumer now, e.g. for authorino:"
    echo "    kubectl -n authorino annotate externalsecret zitadel-introspection force-sync=\$(date +%s) --overwrite"
    echo "    kubectl -n authorino annotate authconfig --all homelab/reload=\$(date +%s) --overwrite"
  fi
}

# True if the PAT is live in Zitadel and belongs to the given user. Exits on
# anything but 200/401, so an outage never passes for a revoked token.
pat_valid() {
  local token="$1" id="$2" out code
  out="$(mktemp)"
  # Header through stdin, so the token never shows up in a process listing.
  code="$(curl -sS -o "${out}" -w '%{http_code}' -H @- "${ZITADEL_URL}/auth/v1/users/me" \
    <<<"Authorization: Bearer ${token}")"
  case "${code}" in
    200) if [[ "$(jq -r '.user.id' "${out}")" == "${id}" ]]; then code=0; else code=1; fi ;;
    401) code=1 ;;
    *) echo "Error: checking a PAT returned HTTP ${code}" >&2; rm -f "${out}"; exit 1 ;;
  esac
  rm -f "${out}"
  return "${code}"
}

# Machine user for an in-cluster bearer-token client: exactly the template's
# roles and a PAT in Vault. A PAT is shown only once, so a new one is issued
# when the Vault one is missing or no longer valid, or with --regenerate.
# Older PATs are kept: consumers hold the token in env until they restart, so
# the operator revokes them once the consumer runs on the new one.
ensure_machine() {
  local machine="$1" name vault_path id token pats created ns es secret workload
  name="$(jq -r '.name' <<<"${machine}")"
  vault_path="$(jq -r '.vault' <<<"${machine}")"
  id="$(api POST /v2/users "$(jq -nc --arg u "${name}" \
    '{queries: [{userNameQuery: {userName: $u, method: "TEXT_QUERY_METHOD_EQUALS"}}]}')" \
    | jq -r '.result[0].userId // empty')"
  if [[ -z "${id}" ]]; then
    echo ">>> Creating machine user ${name}"
    id="$(api POST /management/v1/users/machine "$(jq -nc --arg n "${name}" \
      '{userName: $n, name: $n, accessTokenType: "ACCESS_TOKEN_TYPE_BEARER"}')" | jq -r '.userId')"
  else
    echo ">>> Machine user ${name} exists"
  fi
  ensure_user_grant "${id}" "$(jq -c '{username: .name, roles}' <<<"${machine}")"
  token="$(vault kv get -field=token "${KV_MOUNT}/${vault_path}" 2>/dev/null || true)"
  if [[ "${REGENERATE}" != "true" && -n "${token}" ]] && pat_valid "${token}" "${id}"; then
    echo ">>> Machine user ${name} PAT in Vault is valid"
    return
  fi
  pats="$(api POST "/management/v1/users/${id}/pats/_search" '{}' | jq -r '[.result[]?.id] | join(" ")')"
  echo ">>> Issuing a PAT for ${name} into ${KV_MOUNT}/${vault_path}"
  created="$(api POST "/management/v1/users/${id}/pats" '{}')"
  # Through stdin, so the token never shows up in a process listing.
  jq -c '{token}' <<<"${created}" | vault kv put "${KV_MOUNT}/${vault_path}" - >/dev/null
  echo ">>> Move the consumer to the new PAT: force-sync, then restart the workloads reading the Secret:"
  while read -r ns es secret; do
    [[ -n "${ns}" ]] || continue
    echo "    kubectl -n ${ns} annotate externalsecret ${es} force-sync=\$(date +%s) --overwrite"
    # The token sits in env or a mounted file, so only a restart picks it up.
    for workload in $(kubectl -n "${ns}" get deploy,sts -o json | jq -r --arg s "${secret}" '.items[]
        | select([.spec.template.spec | ((.containers[]?, .initContainers[]?)
            | (.env[]?.valueFrom.secretKeyRef.name, .envFrom[]?.secretRef.name)), .volumes[]?.secret.secretName]
          | index($s))
        | "\(.kind | ascii_downcase)/\(.metadata.name)"'); do
      echo "    kubectl -n ${ns} rollout restart ${workload}"
    done
  done < <(kubectl get externalsecret -A -o json | jq -r --arg k "${vault_path}" \
    '.items[] | select([.spec.data[]?.remoteRef.key] | index($k))
      | "\(.metadata.namespace) \(.metadata.name) \(.spec.target.name // .metadata.name)"')
  if [[ -n "${pats}" ]]; then
    echo ">>> Once it works on the new PAT, delete the old ones (${pats}) in the Zitadel console:"
    echo "    Users > Service Accounts > ${name} > Personal Access Tokens"
  fi
}

ensure_machines() {
  local machines machine
  machines="$(yq -c '(.machines // [])[]' "${TEMPLATE}")"
  while read -r machine; do
    [[ -n "${machine}" ]] || continue
    ensure_machine "${machine}"
  done <<<"${machines}"
}

# The template is the client list: unlisted apps in the project are deleted.
# Their Vault oidc/<name> paths are left for the operator to remove.
ensure_clients() {
  local apps clients client unlisted id name
  apps="$(api POST "/management/v1/projects/${PROJECT_ID}/apps/_search" '{}' | jq -c '[.result[]?]')"
  clients="$(yq -c '.clients[]' "${TEMPLATE}")"
  while read -r client; do
    [[ -n "${client}" ]] || continue
    ensure_client "${client}" "${apps}"
  done <<<"${clients}"
  clients="$(yq -c '(.apiClients // [])[]' "${TEMPLATE}")"
  while read -r client; do
    [[ -n "${client}" ]] || continue
    ensure_api_client "${client}" "${apps}"
  done <<<"${clients}"
  unlisted="$(jq -r --argjson want "$(yq -c '[.clients[].name] + [(.apiClients // [])[].name]' "${TEMPLATE}")" \
    '.[] | select(.name as $n | $want | index($n) | not) | "\(.id) \(.name)"' <<<"${apps}")"
  while read -r id name; do
    [[ -n "${id}" ]] || continue
    echo ">>> Removing OIDC client ${name} (not in ${TEMPLATE##*/})"
    api DELETE "/management/v1/projects/${PROJECT_ID}/apps/${id}" >/dev/null
  done <<<"${unlisted}"
}

# One grant per user on the project, holding exactly the template's roles.
ensure_user_grant() {
  local id="$1" user="$2" username roles grant
  username="$(jq -r '.username' <<<"${user}")"
  roles="$(jq -c '(.roles // []) | sort' <<<"${user}")"
  grant="$(api POST /management/v1/users/grants/_search "$(jq -nc --arg u "${id}" --arg p "${PROJECT_ID}" \
    '{queries: [{userIdQuery: {userId: $u}}, {projectIdQuery: {projectId: $p}}]}')" \
    | jq -c '.result[0] // empty | {id, roleKeys: ((.roleKeys // []) | sort)}')"
  if [[ -z "${grant}" ]]; then
    [[ "${roles}" != "[]" ]] || return 0
    echo ">>> Granting ${username} roles ${roles}"
    api POST "/management/v1/users/${id}/grants" \
      "$(jq -nc --arg p "${PROJECT_ID}" --argjson r "${roles}" '{projectId: $p, roleKeys: $r}')" >/dev/null
  elif [[ "${roles}" == "[]" ]]; then
    echo ">>> Revoking ${username} project grant"
    api DELETE "/management/v1/users/${id}/grants/$(jq -r '.id' <<<"${grant}")" >/dev/null
  elif [[ "$(jq -c '.roleKeys' <<<"${grant}")" != "${roles}" ]]; then
    echo ">>> Setting ${username} roles to ${roles}"
    api PUT "/management/v1/users/${id}/grants/$(jq -r '.id' <<<"${grant}")" \
      "$(jq -nc --argjson r "${roles}" '{roleKeys: $r}')" >/dev/null
  fi
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
  ensure_user_grant "${id}" "${user}"
}

ensure_users() {
  local users user
  users="$(yq -c '.users[]' "${TEMPLATE}")"
  while read -r user; do
    [[ -n "${user}" ]] || continue
    ensure_user "${user}"
  done <<<"${users}"
}

main() {
  wait_for_zitadel
  ensure_admin_username
  ensure_idps
  ensure_oidc_settings
  ensure_login_policy
  ensure_project
  ensure_groups_action
  ensure_project_roles
  ensure_clients
  ensure_admin_grant
  ensure_users
  ensure_machines
  echo
  echo "Zitadel seeding complete."
}

main "$@"
