#!/bin/bash

set -uo pipefail

URL_WIDTH=55
USER_WIDTH=16

get_secret() {
    kubectl get secret "$2" -n "$1" -o jsonpath="{.data.$3}" 2>/dev/null | base64 -d 2>/dev/null
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

print_row "URL" "USER" "PASSWORD"
print_row "$(repeat_char "-" "$URL_WIDTH")" "$(repeat_char "-" "$USER_WIDTH")" "$(repeat_char "-" 20)"

while IFS=$'\t' read -r ns name hostname; do
    [[ -z "$hostname" ]] && continue
    url="http://$hostname"
    case "$ns/$name" in
        airflow/airflow)
            print_row "$url" "admin" "admin"
            ;;
        dbeaver/cloudbeaver)
            print_row "$url" "-" "(create admin on first login)"
            ;;
        jupyter/jupyterhub)
            print_secret_row "$url" jupyter jupyterhub-admin-creds password admin
            ;;
        monitoring/grafana)
            user=$(get_secret monitoring prometheus-stack-grafana admin-user)
            print_secret_row "$url" monitoring prometheus-stack-grafana admin-password "${user:-admin}"
            ;;
        monitoring/alertmanager|monitoring/prometheus|spark/spark-history)
            print_row "$url" "-" "(no auth)"
            ;;
        ray/ray-vllm)
            print_row "${url}/v1" "-" "(no auth)"
            ;;
        rook-ceph/ceph)
            print_secret_row "$url" rook-ceph rook-ceph-dashboard-password password admin
            ;;
        superset/superset)
            print_row "$url" "admin" "admin"
            ;;
        trino/trino)
            print_row "$url" "admin" "(fixed web UI user)"
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
