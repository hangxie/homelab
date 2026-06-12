#!/bin/bash

set -uo pipefail

URL_WIDTH=55
USER_WIDTH=28
URL_SCHEME="${DASHBOARD_CREDS_SCHEME:-https}"

get_secret() {
    kubectl get secret "$2" -n "$1" -o json 2>/dev/null \
        | jq -r --arg key "$3" '.data[$key] // empty' \
        | base64 -d 2>/dev/null
}

print_row() {
    printf "%-${URL_WIDTH}s %-${USER_WIDTH}s %s\n" "$1" "$2" "$3"
}

repeat_char() {
    local char="$1"
    local count="$2"
    local text

    printf -v text "%*s" "$count" ""
    printf "%s" "${text// /$char}"
}

print_secret_row() {
    local url="$1"
    local ns="$2"
    local secret="$3"
    local key="$4"
    local user="$5"
    local pass

    pass=$(get_secret "$ns" "$secret" "$key")
    [[ -z "$pass" ]] && pass="(secret missing)"
    print_row "$url" "$user" "$pass"
}

print_secret_user_pass_row() {
    local url="$1"
    local ns="$2"
    local secret="$3"
    local user_key="$4"
    local pass_key="$5"
    local default_user="$6"
    local user

    user=$(get_secret "$ns" "$secret" "$user_key")
    [[ -z "$user" ]] && user="$default_user"
    print_secret_row "$url" "$ns" "$secret" "$pass_key" "$user"
}

print_row "URL" "USER" "CREDENTIAL"
print_row "$(repeat_char "-" "$URL_WIDTH")" "$(repeat_char "-" "$USER_WIDTH")" "$(repeat_char "-" 20)"

while IFS=$'\t' read -r ns name hostname; do
    [[ -z "$hostname" ]] && continue
    url="${URL_SCHEME}://$hostname"
    case "$ns/$name" in
        airflow/airflow)
            print_secret_row "$url" airflow airflow-admin password admin
            ;;
        argocd/argocd)
            print_secret_row "$url" argocd argocd-initial-admin-secret password admin
            ;;
        dbeaver/cloudbeaver|dbeaver/dbeaver)
            # CloudBeaver keeps an internal admin in its workspace PVC; this
            # internal-only tool intentionally stays on the first-login flow.
            print_row "$url" "-" "(admin created during first login)"
            ;;
        headlamp/headlamp)
            # Token-based login: no static credential is materialized; the
            # operator mints an SA token on demand and pastes it at the
            # login screen. The `headlamp` ServiceAccount is provisioned by
            # the chart and bound to cluster-admin via the chart's own CRB.
            print_row "$url" headlamp \
                "(kubectl -n headlamp create token headlamp --duration=8h)"
            ;;
        jupyter/jupyter|jupyter/jupyterhub)
            print_secret_row "$url" jupyter jupyter-admin password admin
            ;;
        kube-system/hubble)
            print_row "$url" "-" "(no auth)"
            ;;
        llama-cpp/llama-cpp)
            print_row "${url}/v1" "-" "(no auth)"
            ;;
        monitoring/grafana)
            print_secret_user_pass_row "$url" monitoring grafana-admin username password admin
            ;;
        monitoring/alertmanager|monitoring/prometheus|ray/ray-dashboard|spark/spark-history)
            print_row "$url" "-" "(no auth)"
            ;;
        openwebui/open-webui)
            print_secret_row "$url" openwebui openwebui-admin password admin@homelab.xiehang.com
            ;;
        ray/ray-vllm)
            print_row "${url}/v1" "-" "(no auth)"
            ;;
        rook-ceph/ceph)
            print_secret_row "$url" rook-ceph rook-ceph-dashboard-password password admin
            ;;
        superset/superset)
            print_secret_row "$url" superset superset-admin password admin
            ;;
        trino/trino)
            print_secret_user_pass_row "$url" trino trino-credentials username password admin
            ;;
        *)
            print_row "$url" "-" "(credentials unknown)"
            ;;
    esac
done < <(kubectl get httproute -A -o json 2>/dev/null | jq -r '
    .items[]
    | . as $route
    | ($route.spec.hostnames // [])[]
    | [$route.metadata.namespace, $route.metadata.name, .]
    | @tsv
') | sort
