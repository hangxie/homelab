#!/bin/bash
set -e

NAMESPACE="llama-cpp"
PVC_NAME="${LLAMA_PVC_NAME:-llama-cpp-models}"
PVC_SIZE="${LLAMA_PVC_SIZE:-100Gi}"
DOWNLOADER_IMAGE="${LLAMA_DOWNLOADER_IMAGE:-curlimages/curl:8.10.1}"
DOWNLOADER_MEMORY_REQUEST="${LLAMA_DOWNLOADER_MEMORY_REQUEST:-512Mi}"
DOWNLOADER_MEMORY_LIMIT="${LLAMA_DOWNLOADER_MEMORY_LIMIT:-6Gi}"
DOWNLOADER_RATE_LIMIT="${LLAMA_DOWNLOADER_RATE_LIMIT:-25M}"
HF_REVISION="${HF_REVISION:-main}"
HARBOR_REGISTRY="${LLAMA_HARBOR_REGISTRY:-registry.xiehang.com}"
HARBOR_PROJECT="${LLAMA_HARBOR_PROJECT:-llm-models}"
HARBOR_SECRET_NAME="${LLAMA_HARBOR_SECRET_NAME:-harbor-credentials}"
ORAS_IMAGE="${LLAMA_ORAS_IMAGE:-ghcr.io/oras-project/oras:v1.2.2}"

usage() {
    cat <<'EOF'
Usage: llama-model.sh <subcommand> [args]

Subcommands:
  sync / add / get <hf-repo>/<file.gguf>  Ensure a GGUF exists on the PVC, using Harbor as a cache when credentials exist
  list / status                           List GGUFs currently on the PVC and show Harbor cache status when available
  delete / remove <hf-repo>/<file.gguf>   Delete a GGUF from the PVC and Harbor cache when credentials exist

Examples:
  llama-model.sh sync unsloth/Qwen2.5-Coder-7B-Instruct-GGUF/Qwen2.5-Coder-7B-Instruct-Q4_K_M.gguf
  llama-model.sh list
  llama-model.sh delete unsloth/Qwen2.5-Coder-7B-Instruct-GGUF/Qwen2.5-Coder-7B-Instruct-Q4_K_M.gguf

Environment:
  HF_TOKEN                       HuggingFace token for gated repos (e.g. Llama)
  LLAMA_PVC_NAME=<name>          PVC name; default llama-cpp-models
  LLAMA_PVC_SIZE=<size>          PVC size on first create; default 100Gi
  LLAMA_DOWNLOADER_IMAGE=<image> Image used for the HF download Job
  LLAMA_DOWNLOADER_MEMORY_REQUEST=<size>
                                 Downloader memory request; default 512Mi
  LLAMA_DOWNLOADER_MEMORY_LIMIT=<size>
                                 Downloader memory limit; default 6Gi
  LLAMA_DOWNLOADER_RATE_LIMIT=<rate>
                                 curl --limit-rate value; default 25M, empty disables
  LLAMA_HARBOR_REGISTRY=<host>    Harbor registry; default registry.xiehang.com
  LLAMA_HARBOR_PROJECT=<project>  Harbor project; default llm-models
  LLAMA_HARBOR_SECRET_NAME=<name> Secret in llama-cpp namespace with username/password keys; default harbor-credentials
  LLAMA_ORAS_IMAGE=<image>        ORAS image used by Harbor pull/push Jobs
EOF
}

split_spec() {
    local SPEC="${1}"
    if [[ "${SPEC}" != *"/"* || "${SPEC}" != *".gguf" ]]; then
        echo "Error: spec must look like '<hf-org>/<hf-repo>/<file>.gguf'" >&2
        echo "Got: ${SPEC}" >&2
        return 1
    fi
    HF_FILE="${SPEC##*/}"
    HF_REPO="${SPEC%/*}"
    if [[ "${HF_REPO}" != *"/"* ]]; then
        echo "Error: hf-repo must include the org, e.g. unsloth/Qwen2.5-...-GGUF" >&2
        return 1
    fi
}

make_job_name() {
    local PREFIX="${1}"
    local SPEC="${2}"
    local MAX_SLUG=$((60 - ${#PREFIX}))
    local SLUG
    SLUG="$(printf '%s' "${SPEC}" | tr '[:upper:]' '[:lower:]' | tr '/_.' '---' \
        | tr -cd 'a-z0-9-' | cut -c1-"${MAX_SLUG}" | sed 's/-*$//')"
    printf '%s%s' "${PREFIX}" "${SLUG}"
}

harbor_repo_name() {
    local SPEC="${1}"
    local SLUG
    SLUG="$(printf '%s' "${SPEC}" | tr '[:upper:]' '[:lower:]' | tr '/_.+' '----' \
        | tr -cd 'a-z0-9-' | sed 's/--*/-/g; s/^-//; s/-$//')"
    printf 'gguf-%s' "${SLUG}"
}

harbor_ref() {
    local SPEC="${1}"
    printf '%s/%s/%s:latest' "${HARBOR_REGISTRY}" "${HARBOR_PROJECT}" "$(harbor_repo_name "${SPEC}")"
}

load_harbor_credentials() {
    HARBOR_USERNAME="$(kubectl -n "${NAMESPACE}" get secret "${HARBOR_SECRET_NAME}" -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null || true)"
    HARBOR_PASSWORD="$(kubectl -n "${NAMESPACE}" get secret "${HARBOR_SECRET_NAME}" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)"
    [[ -n "${HARBOR_USERNAME}" && -n "${HARBOR_PASSWORD}" ]]
}

harbor_cache_disabled_message() {
    echo "Harbor cache disabled: secret ${NAMESPACE}/${HARBOR_SECRET_NAME} with username/password keys was not found."
}

harbor_has_file() {
    local SPEC="${1}"
    local HARBOR_REPO TMPFILE HTTP_STATUS
    HARBOR_REPO="$(harbor_repo_name "${SPEC}")"
    TMPFILE="$(mktemp)"

    if ! load_harbor_credentials; then
        rm -f "${TMPFILE}"
        return 2
    fi

    if ! HTTP_STATUS="$(curl -s -o "${TMPFILE}" -w "%{http_code}" \
        -u "${HARBOR_USERNAME}:${HARBOR_PASSWORD}" \
        -H "Accept: application/vnd.oci.image.manifest.v1+json" \
        "https://${HARBOR_REGISTRY}/v2/${HARBOR_PROJECT}/${HARBOR_REPO}/manifests/latest" 2>/dev/null)"; then
        HTTP_STATUS="0"
    fi

    rm -f "${TMPFILE}"
    [[ "${HTTP_STATUS}" == "200" ]]
}

delete_harbor_file() {
    local SPEC="${1}"
    local HARBOR_REPO HARBOR_REF HTTP_STATUS
    HARBOR_REPO="$(harbor_repo_name "${SPEC}")"
    HARBOR_REF="$(harbor_ref "${SPEC}")"

    if ! load_harbor_credentials; then
        harbor_cache_disabled_message
        echo "Harbor delete skipped: ${HARBOR_REF}"
        return 0
    fi

    echo "Deleting ${HF_REPO}/${HF_FILE} from Harbor cache..."
    if ! HTTP_STATUS="$(curl -s -o /dev/null -w "%{http_code}" \
        -X DELETE \
        -u "${HARBOR_USERNAME}:${HARBOR_PASSWORD}" \
        "https://${HARBOR_REGISTRY}/api/v2.0/projects/${HARBOR_PROJECT}/repositories/${HARBOR_REPO}" 2>/dev/null)"; then
        HTTP_STATUS="0"
    fi

    case "${HTTP_STATUS}" in
        200 | 202)
            echo "Deleted from Harbor: ${HARBOR_REF}"
            ;;
        404)
            echo "Not found on Harbor, skipping: ${HARBOR_REF}"
            ;;
        *)
            echo "Harbor delete returned HTTP ${HTTP_STATUS}" >&2
            echo "Check that the robot account has delete permission on project '${HARBOR_PROJECT}'." >&2
            return 1
            ;;
    esac
}

ensure_namespace_and_pvc() {
    kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${PVC_NAME}
  namespace: ${NAMESPACE}
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: rook-ceph-block
  resources:
    requests:
      storage: ${PVC_SIZE}
EOF
}

delete_job_if_present() {
    local JOB_NAME="${1}"
    kubectl -n "${NAMESPACE}" delete job "${JOB_NAME}" --ignore-not-found >/dev/null
    kubectl -n "${NAMESPACE}" wait --for=delete job/"${JOB_NAME}" --timeout=60s >/dev/null 2>&1 || true
}

wait_for_job() {
    local JOB_NAME="${1}"
    local TIMEOUT_SECONDS="${2}"
    local SLEEP_SECONDS=5
    local ELAPSED=0
    local COMPLETE FAILED

    while (( ELAPSED < TIMEOUT_SECONDS )); do
        COMPLETE="$(kubectl -n "${NAMESPACE}" get job "${JOB_NAME}" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null || true)"
        FAILED="$(kubectl -n "${NAMESPACE}" get job "${JOB_NAME}" -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || true)"

        if [[ "${COMPLETE}" == "True" ]]; then
            return 0
        fi
        if [[ "${FAILED}" == "True" ]]; then
            echo "Error: job ${JOB_NAME} failed." >&2
            kubectl -n "${NAMESPACE}" logs job/"${JOB_NAME}" --tail=200 >&2 || true
            return 1
        fi

        sleep "${SLEEP_SECONDS}"
        ELAPSED=$((ELAPSED + SLEEP_SECONDS))
    done

    echo "Error: timed out waiting for job ${JOB_NAME}." >&2
    kubectl -n "${NAMESPACE}" logs job/"${JOB_NAME}" --tail=200 >&2 || true
    return 1
}

pvc_has_file() {
    local SPEC="${1}"
    split_spec "${SPEC}" || return 1
    local CHECK_POD="llama-check-$(date +%s | tail -c 5)"
    kubectl -n "${NAMESPACE}" delete pod "${CHECK_POD}" --ignore-not-found >/dev/null
    cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${CHECK_POD}
  namespace: ${NAMESPACE}
spec:
  restartPolicy: Never
  containers:
    - name: check
      image: busybox
      command:
        - sh
        - -c
        - |
          dest="/models/${HF_REPO}/${HF_FILE}"
          marker="\${dest}.size"
          file_size() {
            stat -c %s "\$1" 2>/dev/null || wc -c < "\$1" | tr -d ' '
          }
          test -s "\${dest}" && test -s "\${marker}" &&
            [ "\$(file_size "\${dest}")" = "\$(cat "\${marker}" | tr -d ' ')" ]
      volumeMounts:
        - name: models
          mountPath: /models
          readOnly: true
      resources:
        requests:
          cpu: "50m"
          memory: "32Mi"
        limits:
          cpu: "200m"
          memory: "64Mi"
  volumes:
    - name: models
      persistentVolumeClaim:
        claimName: ${PVC_NAME}
        readOnly: true
EOF
    local PHASE=""
    for _ in {1..60}; do
        PHASE="$(kubectl -n "${NAMESPACE}" get pod "${CHECK_POD}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
        case "${PHASE}" in Succeeded|Failed) break ;; esac
        sleep 1
    done
    kubectl -n "${NAMESPACE}" delete pod "${CHECK_POD}" --ignore-not-found >/dev/null
    [[ "${PHASE}" == "Succeeded" ]]
}

download_from_huggingface() {
    local SPEC="${1}"
    echo "Downloading ${HF_REPO}/${HF_FILE} from HuggingFace to PVC ${PVC_NAME}..."

    local JOB_NAME
    JOB_NAME="$(make_job_name "llama-sync-" "${SPEC}")"
    LAST_SYNC_JOB="${JOB_NAME}"

    delete_job_if_present "${JOB_NAME}"
    cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB_NAME}
  namespace: ${NAMESPACE}
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 600
  template:
    spec:
      restartPolicy: Never
      initContainers:
        - name: mkdir
          image: busybox
          command: ["sh", "-c", "mkdir -p /models/${HF_REPO} && chmod -R 777 /models/${HF_REPO%/*}"]
          volumeMounts:
            - name: models
              mountPath: /models
      containers:
        - name: downloader
          image: ${DOWNLOADER_IMAGE}
          command:
            - sh
            - -c
            - |
              set -e
              url="https://huggingface.co/${HF_REPO}/resolve/${HF_REVISION}/${HF_FILE}"
              dest="/models/${HF_REPO}/${HF_FILE}"
              marker="\${dest}.size"
              tmp="\${dest}.part"

              get_remote_size() {
                set -- curl -fsSLI
                if [ -n "\${HF_TOKEN}" ]; then
                  set -- "\$@" -H "Authorization: Bearer \${HF_TOKEN}"
                fi
                "\$@" "\${url}" | awk 'tolower(\$1)=="content-length:" {print \$2}' | tr -d '\r' | tail -n1
              }

              file_size() {
                stat -c %s "\$1" 2>/dev/null || wc -c < "\$1" | tr -d ' '
              }

              expected="\$(get_remote_size || true)"
              if [ -s "\${dest}" ] && [ -n "\${expected}" ]; then
                actual="\$(file_size "\${dest}")"
                if [ "\${actual}" = "\${expected}" ]; then
                  printf '%s\n' "\${actual}" > "\${marker}"
                  echo "Already present and size matches: \${actual} bytes"
                  ls -lh "\${dest}"
                  exit 0
                fi
                echo "Removing incomplete existing file: \${actual} bytes, expected \${expected}"
                rm -f "\${dest}" "\${marker}"
              fi

              rm -f "\${tmp}"
              trap 'rm -f "\${tmp}"' EXIT

              echo "Streaming \${url} -> \${tmp}"
              set -- curl -L --fail --retry 5 --retry-delay 5 --create-dirs
              if [ -n "\${LLAMA_DOWNLOADER_RATE_LIMIT}" ]; then
                set -- "\$@" --limit-rate "\${LLAMA_DOWNLOADER_RATE_LIMIT}"
              fi
              if [ -n "\${HF_TOKEN}" ]; then
                set -- "\$@" -H "Authorization: Bearer \${HF_TOKEN}"
              fi
              "\$@" -o "\${tmp}" "\${url}"

              actual="\$(file_size "\${tmp}")"
              if [ -n "\${expected}" ] && [ "\${actual}" != "\${expected}" ]; then
                echo "Downloaded size mismatch: got \${actual} bytes, expected \${expected}" >&2
                exit 1
              fi

              mv -f "\${tmp}" "\${dest}"
              printf '%s\n' "\${actual}" > "\${marker}"
              trap - EXIT
              ls -lh "\${dest}"
          env:
            - name: HF_TOKEN
              value: "${HF_TOKEN:-}"
            - name: LLAMA_DOWNLOADER_RATE_LIMIT
              value: "${DOWNLOADER_RATE_LIMIT}"
          volumeMounts:
            - name: models
              mountPath: /models
          resources:
            requests:
              cpu: "100m"
              memory: "${DOWNLOADER_MEMORY_REQUEST}"
            limits:
              cpu: "500m"
              memory: "${DOWNLOADER_MEMORY_LIMIT}"
      volumes:
        - name: models
          persistentVolumeClaim:
            claimName: ${PVC_NAME}
EOF

    echo "Waiting for download job to complete..."
    wait_for_job "${JOB_NAME}" 3600
}

pull_from_harbor() {
    local SPEC="${1}"
    local HARBOR_REF JOB_NAME
    HARBOR_REF="$(harbor_ref "${SPEC}")"
    JOB_NAME="$(make_job_name "llama-pull-" "${SPEC}")"
    LAST_SYNC_JOB="${JOB_NAME}"

    echo "Pulling ${HF_REPO}/${HF_FILE} from Harbor cache..."
    delete_job_if_present "${JOB_NAME}"
    cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB_NAME}
  namespace: ${NAMESPACE}
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 600
  template:
    spec:
      restartPolicy: Never
      initContainers:
        - name: oras-installer
          image: ${ORAS_IMAGE}
          command: [cp, /bin/oras, /shared/oras]
          volumeMounts:
            - name: shared-bin
              mountPath: /shared
        - name: mkdir
          image: busybox
          command: ["sh", "-c", "mkdir -p /models/${HF_REPO} && chmod -R 777 /models/${HF_REPO%/*}"]
          volumeMounts:
            - name: models
              mountPath: /models
      containers:
        - name: pull
          image: busybox
          command:
            - sh
            - -c
            - |
              set -e
              export PATH="/shared:\$PATH"
              rm -f "/models/${HF_REPO}/${HF_FILE}" "/models/${HF_REPO}/${HF_FILE}.size" "/models/${HF_REPO}/${HF_FILE}.part"
              echo "\${HARBOR_PASSWORD}" | oras pull -u "\${HARBOR_USERNAME}" --password-stdin "\${HARBOR_REF}" --output "/models/${HF_REPO}"
              test -s "/models/${HF_REPO}/${HF_FILE}"
              test -s "/models/${HF_REPO}/${HF_FILE}.size"
              ls -lh "/models/${HF_REPO}/${HF_FILE}"
          env:
            - name: HARBOR_REF
              value: "${HARBOR_REF}"
            - name: HARBOR_USERNAME
              valueFrom:
                secretKeyRef:
                  name: ${HARBOR_SECRET_NAME}
                  key: username
            - name: HARBOR_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: ${HARBOR_SECRET_NAME}
                  key: password
          volumeMounts:
            - name: models
              mountPath: /models
            - name: shared-bin
              mountPath: /shared
            - name: host-ca-certs
              mountPath: /etc/ssl/certs
              readOnly: true
          resources:
            requests:
              cpu: "500m"
              memory: "512Mi"
            limits:
              cpu: "1"
              memory: "1Gi"
      volumes:
        - name: models
          persistentVolumeClaim:
            claimName: ${PVC_NAME}
        - name: shared-bin
          emptyDir: {}
        - name: host-ca-certs
          hostPath:
            path: /etc/ssl/certs
            type: Directory
EOF

    echo "Waiting for Harbor pull job to complete..."
    wait_for_job "${JOB_NAME}" 3600
}

push_to_harbor() {
    local SPEC="${1}"
    local HARBOR_REF JOB_NAME
    HARBOR_REF="$(harbor_ref "${SPEC}")"
    JOB_NAME="$(make_job_name "llama-push-" "${SPEC}")"

    if ! load_harbor_credentials; then
        harbor_cache_disabled_message
        echo "Harbor push skipped: ${HARBOR_REF}"
        return 0
    fi

    echo "Pushing ${HF_REPO}/${HF_FILE} from PVC to Harbor cache..."
    delete_job_if_present "${JOB_NAME}"
    cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB_NAME}
  namespace: ${NAMESPACE}
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 600
  template:
    spec:
      restartPolicy: Never
      initContainers:
        - name: oras-installer
          image: ${ORAS_IMAGE}
          command: [cp, /bin/oras, /shared/oras]
          volumeMounts:
            - name: shared-bin
              mountPath: /shared
      containers:
        - name: push
          image: busybox
          command:
            - sh
            - -c
            - |
              set -e
              export PATH="/shared:\$PATH"
              cd "/models/${HF_REPO}"
              test -s "${HF_FILE}"
              test -s "${HF_FILE}.size"
              echo "\${HARBOR_PASSWORD}" | oras push -u "\${HARBOR_USERNAME}" --password-stdin "\${HARBOR_REF}" "${HF_FILE}" "${HF_FILE}.size"
              echo "Pushed to Harbor: \${HARBOR_REF}"
          env:
            - name: HARBOR_REF
              value: "${HARBOR_REF}"
            - name: HARBOR_USERNAME
              valueFrom:
                secretKeyRef:
                  name: ${HARBOR_SECRET_NAME}
                  key: username
            - name: HARBOR_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: ${HARBOR_SECRET_NAME}
                  key: password
          volumeMounts:
            - name: models
              mountPath: /models
            - name: shared-bin
              mountPath: /shared
            - name: host-ca-certs
              mountPath: /etc/ssl/certs
              readOnly: true
          resources:
            requests:
              cpu: "500m"
              memory: "512Mi"
            limits:
              cpu: "1"
              memory: "1Gi"
      volumes:
        - name: models
          persistentVolumeClaim:
            claimName: ${PVC_NAME}
        - name: shared-bin
          emptyDir: {}
        - name: host-ca-certs
          hostPath:
            path: /etc/ssl/certs
            type: Directory
EOF

    echo "Waiting for Harbor push job to complete..."
    wait_for_job "${JOB_NAME}" 3600
}

cmd_sync() {
    local SPEC="${1:-}"
    if [[ -z "${SPEC}" ]]; then
        usage
        exit 1
    fi
    split_spec "${SPEC}" || exit 1

    ensure_namespace_and_pvc

    local ON_PVC=false
    local HARBOR_READY=false
    local ON_HARBOR=false
    local HARBOR_REF
    HARBOR_REF="$(harbor_ref "${SPEC}")"

    if pvc_has_file "${SPEC}"; then
        ON_PVC=true
    fi

    if load_harbor_credentials; then
        HARBOR_READY=true
        if harbor_has_file "${SPEC}"; then
            ON_HARBOR=true
        fi
    else
        harbor_cache_disabled_message
    fi

    echo "  PVC:    ${ON_PVC}"
    if ${HARBOR_READY}; then
        echo "  Harbor: ${ON_HARBOR} (${HARBOR_REF})"
    else
        echo "  Harbor: disabled"
    fi

    if ${ON_PVC}; then
        if ${HARBOR_READY} && ! ${ON_HARBOR}; then
            echo "GGUF is on PVC but missing from Harbor cache."
            push_to_harbor "${SPEC}"
        else
            echo "Already on PVC: ${HF_REPO}/${HF_FILE}"
        fi

        echo ""
        echo "Sync complete."
        echo "  Repo: ${HF_REPO}"
        echo "  File: ${HF_FILE}"
        if ${HARBOR_READY}; then
            echo "  Harbor: ${HARBOR_REF}"
        fi
        return 0
    fi

    if ${HARBOR_READY} && ${ON_HARBOR}; then
        pull_from_harbor "${SPEC}"
    else
        download_from_huggingface "${SPEC}"
        if ${HARBOR_READY}; then
            push_to_harbor "${SPEC}"
        fi
    fi

    if ! pvc_has_file "${SPEC}"; then
        echo "Error: ${HF_REPO}/${HF_FILE} still missing after job completion." >&2
        if [[ -n "${LAST_SYNC_JOB:-}" ]]; then
            kubectl -n "${NAMESPACE}" logs job/"${LAST_SYNC_JOB}" --tail=200 >&2 || true
        fi
        exit 1
    fi

    echo ""
    echo "Sync complete."
    echo "  Repo: ${HF_REPO}"
    echo "  File: ${HF_FILE}"
    if ${HARBOR_READY}; then
        echo "  Harbor: ${HARBOR_REF}"
    fi
}

cmd_list() {
    ensure_namespace_and_pvc

    local POD_NAME="llama-list-$(date +%s | tail -c 5)"
    kubectl -n "${NAMESPACE}" delete pod "${POD_NAME}" --ignore-not-found >/dev/null
    cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${POD_NAME}
  namespace: ${NAMESPACE}
spec:
  restartPolicy: Never
  containers:
    - name: list
      image: busybox
      command:
        - sh
        - -c
        - |
          if [ ! -d /mnt/models ]; then
            exit 0
          fi
          cd /mnt/models
          find . -type f -name '*.gguf' | sed 's|^\./||' | sort | while read -r f; do
            size=\$(du -h "\$f" | cut -f1)
            printf "%-12s  %s\n" "\$size" "\$f"
          done
      volumeMounts:
        - name: models
          mountPath: /mnt/models
          readOnly: true
      resources:
        requests:
          cpu: "50m"
          memory: "32Mi"
        limits:
          cpu: "200m"
          memory: "64Mi"
  volumes:
    - name: models
      persistentVolumeClaim:
        claimName: ${PVC_NAME}
        readOnly: true
EOF
    kubectl -n "${NAMESPACE}" wait pod/"${POD_NAME}" \
        --for=jsonpath='{.status.phase}'=Succeeded \
        --timeout=60s >/dev/null

    local PVC_LINES
    PVC_LINES="$(kubectl -n "${NAMESPACE}" logs "${POD_NAME}")"

    if load_harbor_credentials; then
        printf "%-12s  %-80s  %s\n" "SIZE" "SPEC" "HARBOR"
        printf "%-12s  %-80s  %s\n" "----" "----" "------"
        while read -r SIZE SPEC; do
            [[ -z "${SPEC}" ]] && continue
            if harbor_has_file "${SPEC}"; then
                printf "%-12s  %-80s  %s\n" "${SIZE}" "${SPEC}" "$(harbor_ref "${SPEC}")"
            else
                printf "%-12s  %-80s  %s\n" "${SIZE}" "${SPEC}" "-"
            fi
        done <<< "${PVC_LINES}"
    else
        printf "%-12s  %s\n" "SIZE" "SPEC"
        printf "%-12s  %s\n" "----" "----"
        printf '%s\n' "${PVC_LINES}"
        echo ""
        harbor_cache_disabled_message
    fi
    kubectl -n "${NAMESPACE}" delete pod "${POD_NAME}" --ignore-not-found >/dev/null
}

cmd_delete() {
    local SPEC="${1:-}"
    if [[ -z "${SPEC}" ]]; then
        usage
        exit 1
    fi
    split_spec "${SPEC}" || exit 1

    ensure_namespace_and_pvc

    if ! pvc_has_file "${SPEC}"; then
        echo "No complete file marker found; deleting any leftovers for: ${HF_REPO}/${HF_FILE}"
    fi

    local JOB_NAME
    JOB_NAME="$(make_job_name "llama-delete-" "${SPEC}")"

    delete_job_if_present "${JOB_NAME}"
    cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB_NAME}
  namespace: ${NAMESPACE}
spec:
  ttlSecondsAfterFinished: 300
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: delete
          image: busybox
          command:
            - sh
            - -c
            - |
              target="/models/${HF_REPO}/${HF_FILE}"
              if [ -f "\$target" ]; then
                rm -f "\$target" "\$target.size" "\$target.part"
                echo "Deleted \$target"
              else
                rm -f "\$target.size" "\$target.part"
                echo "Already gone: \$target"
              fi
              repo_dir="/models/${HF_REPO}"
              if [ -d "\$repo_dir" ] && [ -z "\$(ls -A "\$repo_dir")" ]; then
                rmdir "\$repo_dir"
                org_dir="/models/${HF_REPO%/*}"
                if [ -d "\$org_dir" ] && [ -z "\$(ls -A "\$org_dir")" ]; then
                  rmdir "\$org_dir"
                fi
              fi
          volumeMounts:
            - name: models
              mountPath: /models
          resources:
            requests:
              cpu: "50m"
              memory: "32Mi"
            limits:
              cpu: "200m"
              memory: "64Mi"
      volumes:
        - name: models
          persistentVolumeClaim:
            claimName: ${PVC_NAME}
EOF

    wait_for_job "${JOB_NAME}" 120
    delete_harbor_file "${SPEC}"

    echo ""
    echo "Delete complete: ${HF_REPO}/${HF_FILE}"
}

SUBCOMMAND="${1:-}"
shift || true

case "${SUBCOMMAND}" in
    sync | add | get)   cmd_sync "$@" ;;
    list | status)   cmd_list ;;
    delete | remove) cmd_delete "$@" ;;
    *)      usage; exit 1 ;;
esac
