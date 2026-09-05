#!/usr/bin/env bash
# Rotate the auto-generated credentials end to end: mint fresh values in Vault,
# push them through External Secrets, wait for the operators that own a
# credential to adopt it, re-run the bootstrap Jobs that apply a password to its
# app or database, and restart the workloads that only read their Secret at
# startup.
#
# Externally minted credentials are never touched. Those are the entries marked
# `generate: false` in scripts/vault-secrets.template.yaml -- the Harbor robot,
# the HuggingFace token, the Cloudflare token and the Slack webhook. They are
# issued outside this deployment, so only their issuer can replace them and a
# locally generated value would just break the integration. README.md carries
# the per-credential manual procedure for each.
#
# Prereqs:
#   - vault, kubectl, jq, yq on PATH
#   - VAULT_ADDR and VAULT_TOKEN exported (same token used for seeding)
#   - kubeconfig pointing at the homelab cluster
#
# Usage:
#   scripts/rotate-cred.sh                    # every safely rotatable path
#   scripts/rotate-cred.sh --dry-run          # print the plan, change nothing
#   scripts/rotate-cred.sh redis/default ...  # only the named paths
#
# Vault writes are delegated to `seed-vault.sh --regenerate --only`, so the
# value formats (url-safe base64 / fernet / hex) and the `generate: false`
# exclusion stay defined in exactly one place.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
REPO_DIR="$(cd -- "${SCRIPT_DIR}/.." >/dev/null && pwd)"
TEMPLATE="${SCRIPT_DIR}/vault-secrets.template.yaml"

DRY_RUN=false
ASSUME_YES=false
SYNC_TIMEOUT=120     # seconds to wait for one ExternalSecret to re-read Vault
JOB_TIMEOUT=600      # seconds to wait for one bootstrap Job to complete
ROLLOUT_TIMEOUT=600  # seconds to wait for one workload rollout

ROTATE_PATHS=()      # paths this run rotates
HELD_PATHS=()        # rotatable paths deliberately skipped this run
REFRESHED=()         # "namespace/secret" pairs ESO re-synced
WARNINGS=()          # non-fatal problems, replayed in the summary

log()  { printf '>>> %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; WARNINGS+=("$*"); }
die()  { printf 'Error: %s\n' "$*" >&2; exit 1; }

generatable_paths() {
  yq -r '.secrets[] | select(.generate != false) | .path' "${TEMPLATE}"
}

external_paths() {
  yq -r '.secrets[] | select(.generate == false) | .path' "${TEMPLATE}"
}

# Paths whose Vault value can be regenerated, but where nothing in the cluster
# re-applies it to the app -- or where re-applying it destroys data. Rotating
# one of these without the matching manual step leaves Vault out of sync with
# the running system, so they are opt-in.
#
# mysql/monitoring is deliberately absent: mysql-monitoring-user-bootstrap does
# ALTER USER for it, so it rotates cleanly even though mysql/root does not.
hold_reason() {
  case "$1" in
    mysql/root)
      echo "the MySQL operator authenticates with this account and no in-cluster Job resets it; ALTER USER 'root' in MySQL first" ;;
    cassandra/admin)
      echo "Cassandra keeps its auth table in the data directory; the Vault value only seeds a fresh cluster" ;;
    dbeaver/admin)
      echo "CloudBeaver persists the admin in its workspace PVC; rotating needs a workspace wipe (see README.md)" ;;
    airflow/admin)
      echo "the chart's create-user Job does not reset an existing user; change it in the Airflow UI" ;;
    openwebui/admin)
      echo "OpenWebUI persists the admin in its own database; change it in the UI or wipe the open-webui PVC" ;;
    airflow/fernet-key)
      echo "existing encrypted Connections and Variables become undecryptable; re-encrypt them first" ;;
    superset/secret)
      echo "encrypted values in the Superset metadata DB need 'superset re-encrypt-secrets' with PREVIOUS_SECRET_KEY" ;;
    *)
      return 1 ;;
  esac
}

list_held() {
  local path reason
  while read -r path; do
    [[ -n "${path}" ]] || continue
    if reason="$(hold_reason "${path}")"; then
      printf '  %-20s %s\n' "${path}" "${reason}"
    fi
  done < <(generatable_paths)
}

usage() {
  cat >&2 <<EOF
Usage: ${0##*/} [--dry-run] [--yes] [path]...

  --dry-run   Print the plan -- including the live ExternalSecrets, Jobs and
              workloads it would touch -- without changing anything.
  --yes       Skip the confirmation prompt.

With no paths, every auto-generated credential is rotated except the ones held
back below, which need a step this script cannot take safely on its own. Name a
held path explicitly to rotate it anyway; its manual follow-up is printed at the
end. Externally minted credentials (generate: false) are always refused.

Held back by default:
$(list_held)
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) DRY_RUN=true ;;
      --yes|-y)  ASSUME_YES=true ;;
      -h|--help) usage; exit 0 ;;
      -*)        die "unknown flag '$1'" ;;
      *)         ROTATE_PATHS+=("$1") ;;
    esac
    shift
  done
}

require_tools() {
  local tool
  for tool in vault kubectl jq yq openssl; do
    command -v "${tool}" >/dev/null || die "${tool} not found on PATH"
  done
  : "${VAULT_ADDR:?VAULT_ADDR must be set}"
  : "${VAULT_TOKEN:?VAULT_TOKEN must be set}"
  kubectl version -o json >/dev/null 2>&1 || die "kubectl cannot reach a cluster"
}

# Turn the operator's arguments (or the whole template) into ROTATE_PATHS, and
# record what was held back so the summary can explain the gap.
select_paths() {
  local path generatable external
  generatable="$(generatable_paths)"
  external="$(external_paths)"

  if (( ${#ROTATE_PATHS[@]} )); then
    for path in "${ROTATE_PATHS[@]}"; do
      if grep -qxF "${path}" <<<"${external}"; then
        die "${path} is minted outside the deployment (generate: false); rotate it at the source, see README.md"
      fi
      grep -qxF "${path}" <<<"${generatable}" \
        || die "${path} is not a path in ${TEMPLATE##*/}"
    done
    return
  fi

  while read -r path; do
    [[ -n "${path}" ]] || continue
    if hold_reason "${path}" >/dev/null; then
      HELD_PATHS+=("${path}")
    else
      ROTATE_PATHS+=("${path}")
    fi
  done <<<"${generatable}"
  (( ${#ROTATE_PATHS[@]} )) || die "nothing to rotate"
}

paths_json() {
  printf '%s\n' "${ROTATE_PATHS[@]}" | jq -R . | jq -s -c .
}

confirm() {
  if [[ "${DRY_RUN}" == "true" || "${ASSUME_YES}" == "true" ]]; then
    return 0
  fi
  local reply
  echo
  echo "This rotates live credentials on $(kubectl config current-context)."
  read -r -p "Continue? [y/N] " reply
  [[ "${reply}" == "y" || "${reply}" == "Y" ]] || die "aborted"
}

# --- step 1: Vault ----------------------------------------------------------

regenerate_in_vault() {
  local args=(--regenerate) path
  for path in "${ROTATE_PATHS[@]}"; do
    args+=(--only "${path}")
  done
  log "Regenerating ${#ROTATE_PATHS[@]} path(s) in Vault"
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "    [dry-run] seed-vault.sh ${args[*]}"
    return 0
  fi
  "${SCRIPT_DIR}/seed-vault.sh" "${args[@]}"
}

# --- step 2: External Secrets ----------------------------------------------

# Every ExternalSecret reading one of the rotated Vault paths, as
# "namespace<TAB>name<TAB>targetSecret<TAB>syncedResourceVersion". The
# secretStoreRef needs no filtering: only the vault-homelab store uses these
# keys, so the RGW-backed ExternalSecrets never match.
find_external_secrets() {
  kubectl get externalsecrets -A -o json | jq -r --argjson paths "$(paths_json)" '
    .items[] as $es
    | ([ (($es.spec.data // [])[]?.remoteRef.key),
         (($es.spec.dataFrom // [])[]?.extract.key) ]
       | map(select(. != null))) as $keys
    | select((($keys - ($keys - $paths)) | length) > 0)
    | [ $es.metadata.namespace,
        $es.metadata.name,
        ($es.spec.target.name // $es.metadata.name),
        ($es.status.syncedResourceVersion // "") ]
    | @tsv
  '
}

# status.syncedResourceVersion is a hash of the data ESO last pulled, so it
# changes exactly when the new Vault value lands -- a truthful signal even for
# ExternalSecrets that template their output (trino's bcrypt password.db) or
# merge into a Secret they do not own (rook's dashboard password).
wait_for_sync() {
  local ns="$1" name="$2" before="$3" deadline now
  deadline=$(( $(date +%s) + SYNC_TIMEOUT ))
  while :; do
    now="$(kubectl -n "${ns}" get externalsecret "${name}" \
             -o jsonpath='{.status.syncedResourceVersion}' 2>/dev/null || true)"
    if [[ -n "${now}" && "${now}" != "${before}" ]]; then
      return 0
    fi
    if (( $(date +%s) >= deadline )); then
      warn "${ns}/${name}: no re-sync within ${SYNC_TIMEOUT}s (still ${before:-<none>})"
      return 1
    fi
    sleep 2
  done
}

refresh_external_secrets() {
  local ns name target before found=0
  log "Forcing ExternalSecrets to re-read Vault"
  while IFS=$'\t' read -r ns name target before; do
    [[ -n "${ns}" ]] || continue
    found=1
    echo "    ${ns}/${name} -> secret/${target}"
    if [[ "${DRY_RUN}" == "true" ]]; then
      REFRESHED+=("${ns}/${target}")
      continue
    fi
    kubectl -n "${ns}" annotate externalsecret "${name}" \
      "force-sync=$(date +%s)" --overwrite >/dev/null
    if wait_for_sync "${ns}" "${name}" "${before}"; then
      REFRESHED+=("${ns}/${target}")
    fi
  done < <(find_external_secrets)
  (( found )) || warn "no ExternalSecret reads any of the rotated paths"
}

refreshed_json() {
  if (( ${#REFRESHED[@]} )); then
    printf '%s\n' "${REFRESHED[@]}" | jq -R . | jq -s -c 'unique'
  else
    echo '[]'
  fi
}

# --- step 2b: operators that still have to push the value onward ------------

# ESO writing a Secret is not the same as the credential being live. CNPG owns
# the postgres superuser role: it copies that Secret into the database only when
# it reconciles, and records what it applied in
# status.secretsResourceVersion.superuserSecretVersion. A cluster reporting
# "healthy" can sit on a stale value indefinitely -- nothing re-triggers it --
# and every *-postgres-bootstrap Job authenticates as that superuser, so
# re-running them first fails with "password authentication failed for user
# postgres" while the Secret and Vault both look correct.
#
# Annotating the Cluster forces the reconcile; the annotation is removed again
# so Argo CD sees no drift.
cnpg_superuser_clusters() {
  kubectl get clusters.postgresql.cnpg.io -A -o json 2>/dev/null | jq -r '
    .items[]
    | select(.spec.enableSuperuserAccess != false)
    | [ .metadata.namespace,
        .metadata.name,
        (.spec.superuserSecret.name // "\(.metadata.name)-superuser") ]
    | @tsv
  '
}

wait_for_cnpg_superuser() {
  local ns name secret live applied deadline nudged
  while IFS=$'\t' read -r ns name secret; do
    [[ -n "${ns}" ]] || continue
    printf '%s\n' "${REFRESHED[@]}" | grep -qxF "${ns}/${secret}" || continue

    log "Waiting for CNPG to apply the superuser password to ${ns}/${name}"
    if [[ "${DRY_RUN}" == "true" ]]; then
      echo "    [dry-run] nudge cluster/${name} and wait for it to adopt secret/${secret}"
      continue
    fi

    live="$(kubectl -n "${ns}" get secret "${secret}" \
              -o jsonpath='{.metadata.resourceVersion}' 2>/dev/null || true)"
    nudged=false
    deadline=$(( $(date +%s) + SYNC_TIMEOUT ))
    while :; do
      applied="$(kubectl -n "${ns}" get cluster "${name}" \
                   -o jsonpath='{.status.secretsResourceVersion.superuserSecretVersion}' \
                   2>/dev/null || true)"
      [[ -n "${live}" && "${applied}" == "${live}" ]] && break
      if [[ "${nudged}" == "false" ]]; then
        kubectl -n "${ns}" annotate cluster "${name}" \
          "rotate-cred/nudge=$(date +%s)" --overwrite >/dev/null 2>&1 || true
        nudged=true
      fi
      if (( $(date +%s) >= deadline )); then
        warn "${ns}/${name}: CNPG still on superuser secret version ${applied:-<none>} (want ${live}); the *-postgres-bootstrap Jobs will fail to authenticate"
        break
      fi
      sleep 2
    done
    if [[ "${nudged}" == "true" ]]; then
      kubectl -n "${ns}" annotate cluster "${name}" rotate-cred/nudge- >/dev/null 2>&1 || true
    fi
  done < <(cnpg_superuser_clusters)
}

# --- step 3: the Jobs that apply a credential -------------------------------

# Workloads mounting one of the refreshed Secrets, as
# "namespace<TAB>kind<TAB>name". `$1` is the kind list passed to kubectl.
find_consumers() {
  kubectl get "$1" -A -o json | jq -r --argjson want "$(refreshed_json)" '
    .items[] as $w
    | ($w.spec.template.spec // {}) as $ps
    | ([ ((($ps.containers // []) + ($ps.initContainers // []))[]?
            | ((.env // [])[]?.valueFrom.secretKeyRef.name),
              ((.envFrom // [])[]?.secretRef.name)),
         (($ps.volumes // [])[]?
            | .secret.secretName,
              ((.projected.sources // [])[]?.secret.name)) ]
       | map(select(. != null))
       | map("\($w.metadata.namespace)/\(.)")
       | unique) as $mounted
    | select((($mounted - ($mounted - $want)) | length) > 0)
    | [ $w.metadata.namespace, $w.kind, $w.metadata.name ] | @tsv
  '
}

# A rotated password only reaches its app or database when the Job that writes
# it runs again. Those are this repo's `*-bootstrap` hooks (ALTER USER against
# Postgres and MySQL) plus one chart-rendered exception: superset's init-db Job,
# whose initscript ends in `fab reset-password`. Other Jobs that merely read a
# rotated Secret -- schema migrations, the chart create-user Jobs -- are left
# alone; re-running them is at best pointless and at worst fails outright.
is_apply_job() {
  case "$1" in
    *-bootstrap)         return 0 ;;
    wl-superset-init-db) return 0 ;;
    *)                   return 1 ;;
  esac
}

# CronJob-spawned Jobs (mysql-outage-reboot) are runs of a schedule, not
# bootstrap hooks, and their spec is owned elsewhere.
owned_by_cronjob() {
  local ns="$1" name="$2"
  [[ -n "$(kubectl -n "${ns}" get job "${name}" \
             -o jsonpath='{.metadata.ownerReferences[?(@.kind=="CronJob")].name}' 2>/dev/null)" ]]
}

# A completed Job cannot be restarted and `kubectl create job --from` only
# accepts a CronJob, so the re-run is a copy: the pod template verbatim, under a
# fresh name, with the controller-generated selector, labels, status and Argo CD
# hook annotations stripped. ttlSecondsAfterFinished means a copy left behind by
# an interrupted run still cleans itself up.
clone_job_spec() {
  local ns="$1" name="$2" clone="$3"
  kubectl -n "${ns}" get job "${name}" -o json | jq --arg n "${clone}" '
    { apiVersion, kind, metadata: { name: $n, namespace: .metadata.namespace }, spec }
    | .spec.selector = null
    | .spec.manualSelector = null
    | .spec.template.metadata.labels =
        ((.spec.template.metadata.labels // {})
         | del(."batch.kubernetes.io/controller-uid", ."batch.kubernetes.io/job-name",
               ."controller-uid", ."job-name"))
    | .spec.ttlSecondsAfterFinished = 600
  '
}

rerun_job() {
  local ns="$1" name="$2" clone
  clone="rot-$(date +%s)-${name}"
  clone="${clone:0:63}"
  clone="${clone%%-}"
  echo "    ${ns}/${name}"
  if [[ "${DRY_RUN}" == "true" ]]; then
    return 0
  fi
  clone_job_spec "${ns}" "${name}" "${clone}" | kubectl -n "${ns}" create -f - >/dev/null
  if ! kubectl -n "${ns}" wait --for=condition=complete "job/${clone}" \
         --timeout="${JOB_TIMEOUT}s" >/dev/null 2>&1; then
    warn "${ns}/${name}: re-run did not complete; logs: kubectl -n ${ns} logs job/${clone}"
    return 0
  fi
  kubectl -n "${ns}" delete "job/${clone}" --ignore-not-found >/dev/null
}

# `*-bootstrap` Jobs go first: they are what gives the database the new password
# that the second pass (and the restarted pods) then authenticate with.
rerun_apply_jobs() {
  local ns kind name pass
  log "Re-running the Jobs that apply a rotated credential"
  for pass in 1 2; do
    while IFS=$'\t' read -r ns kind name; do
      [[ -n "${ns}" ]] || continue
      is_apply_job "${name}" || continue
      case "${name}" in
        *-bootstrap) [[ "${pass}" == 1 ]] || continue ;;
        *)           [[ "${pass}" == 2 ]] || continue ;;
      esac
      if owned_by_cronjob "${ns}" "${name}"; then
        continue
      fi
      rerun_job "${ns}" "${name}"
    done < <(find_consumers jobs)
  done
}

# --- step 4: restart the consumers -----------------------------------------

restart_consumers() {
  local ns kind name lower
  log "Restarting the workloads holding a rotated Secret"
  while IFS=$'\t' read -r ns kind name; do
    [[ -n "${ns}" ]] || continue
    lower="$(printf '%s' "${kind}" | tr '[:upper:]' '[:lower:]')"
    echo "    ${ns} ${lower}/${name}"
    if [[ "${DRY_RUN}" != "true" ]]; then
      kubectl -n "${ns}" rollout restart "${lower}/${name}" >/dev/null
    fi
  done < <(find_consumers deploy,sts,ds)

  if [[ "${DRY_RUN}" == "true" ]]; then
    return 0
  fi
  while IFS=$'\t' read -r ns kind name; do
    [[ -n "${ns}" ]] || continue
    lower="$(printf '%s' "${kind}" | tr '[:upper:]' '[:lower:]')"
    kubectl -n "${ns}" rollout status "${lower}/${name}" \
      --timeout="${ROLLOUT_TIMEOUT}s" >/dev/null \
      || warn "${ns} ${lower}/${name}: rollout did not settle in ${ROLLOUT_TIMEOUT}s"
  done < <(find_consumers deploy,sts,ds)
}

# --- step 5: per-path apply hooks ------------------------------------------

# Grafana only reads GF_SECURITY_ADMIN_PASSWORD when it creates the admin row,
# so a restart alone leaves the old password in the Postgres-backed user table.
# The value is piped out of the pod's own environment, never through this
# script: --password-from-stdin is also the only form that survives a password
# starting with '-', which a url-safe base64 secret is about one time in
# thirteen.
apply_grafana_admin() {
  echo "    grafana: resetting the admin password from the pod environment"
  if [[ "${DRY_RUN}" == "true" ]]; then
    return 0
  fi
  kubectl -n grafana exec deploy/grafana -c grafana -- sh -c \
    'printf %s "$GF_SECURITY_ADMIN_PASSWORD" | grafana cli --homepath "$GF_PATHS_HOME" --config "$GF_PATHS_CONFIG" admin reset-admin-password --password-from-stdin' \
    >/dev/null || warn "grafana: admin password reset failed"
}

# rook re-pushes the dashboard password to the mgr on every CephCluster
# reconcile, so the value does land eventually. This is the repo's own PostSync
# hook, applied directly so the rotation takes effect now; it carries
# ttlSecondsAfterFinished, which is why it is not discoverable as a live Job.
apply_ceph_dashboard() {
  local manifest="${REPO_DIR}/gitops/platform/rook-ceph/cluster/09-dashboard-password-job.yaml"
  echo "    rook-ceph: pushing the dashboard password to the mgr"
  if [[ "${DRY_RUN}" == "true" ]]; then
    return 0
  fi
  kubectl delete -f "${manifest}" --ignore-not-found >/dev/null
  kubectl create -f "${manifest}" >/dev/null
  kubectl -n rook-ceph wait --for=condition=complete job/ceph-dashboard-set-password \
    --timeout="${JOB_TIMEOUT}s" >/dev/null 2>&1 \
    || warn "rook-ceph: ceph-dashboard-set-password did not complete"
}

has_path() {
  printf '%s\n' "${ROTATE_PATHS[@]}" | grep -qxF "$1"
}

run_apply_hooks() {
  if ! has_path grafana/admin && ! has_path ceph/dashboard; then
    return 0
  fi
  log "Applying the credentials nothing else pushes"
  if has_path grafana/admin; then
    apply_grafana_admin
  fi
  if has_path ceph/dashboard; then
    apply_ceph_dashboard
  fi
}

# --- summary ----------------------------------------------------------------

print_summary() {
  local path reason pending=()
  echo
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "Dry run: nothing was changed."
  else
    echo "Rotated ${#ROTATE_PATHS[@]} path(s); ${#REFRESHED[@]} Secret(s) re-synced."
  fi

  # A held path named on the command line still got a new Vault value, so its
  # manual step is now outstanding rather than merely advisory.
  for path in "${ROTATE_PATHS[@]}"; do
    if reason="$(hold_reason "${path}")"; then
      pending+=("${path}: ${reason}")
    fi
  done
  if (( ${#pending[@]} )); then
    echo
    echo "Needs a manual step to finish:"
    printf '  %s\n' "${pending[@]}"
  fi

  if (( ${#HELD_PATHS[@]} )); then
    echo
    echo "Not rotated -- name the path explicitly to override:"
    list_held
  fi

  echo
  echo "Not rotated -- minted outside the deployment, see README.md:"
  external_paths | sed 's/^/  /'

  if (( ${#WARNINGS[@]} )); then
    echo
    echo "Warnings:"
    printf '  %s\n' "${WARNINGS[@]}"
    return 1
  fi
}

main() {
  parse_args "$@"
  require_tools
  select_paths

  echo "Rotating:"
  printf '  %s\n' "${ROTATE_PATHS[@]}"
  confirm

  regenerate_in_vault
  refresh_external_secrets
  if (( ${#REFRESHED[@]} )); then
    wait_for_cnpg_superuser
    rerun_apply_jobs
    restart_consumers
  fi
  run_apply_hooks
  print_summary
}

main "$@"
