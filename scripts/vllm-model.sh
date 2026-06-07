#!/bin/bash
set -e

NAMESPACE="${VLLM_NAMESPACE:-ray}"
PVC_NAME="${VLLM_PVC_NAME:-llm-models}"
PVC_SIZE="${VLLM_PVC_SIZE:-20Gi}"
HARBOR_REGISTRY="registry.xiehang.com"
HARBOR_PROJECT="llm-models"
RAY_IMAGE="hangxie/ray-vllm:v0.1.0"

usage() {
    cat <<'EOF'
Usage: vllm-model.sh <subcommand> [args]

Subcommands:
  verify / check <model-id>   Check integrity and PVC/Harbor drift for a model
  list / status               List models on PVC and Harbor registry
  delete / remove <model-id>  Remove a model from both PVC and Harbor

Examples:
  vllm-model.sh verify Qwen/Qwen3-4B-AWQ
  vllm-model.sh list
  vllm-model.sh delete Qwen/Qwen3-4B-AWQ

Environment:
  VLLM_NAMESPACE=<name>  Kubernetes namespace; default ray
  VLLM_PVC_NAME=<name>  Model PVC name; default llm-models
  VLLM_PVC_SIZE=<size>  PVC size on first create; default 20Gi
EOF
}

ensure_namespace_and_pvc() {
    kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
    cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${PVC_NAME}
  namespace: ${NAMESPACE}
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: rook-cephfs
  resources:
    requests:
      storage: ${PVC_SIZE}
EOF
}

validate_pvc_model() {
    local MODEL_ID="${1}"
    local MODEL_SLUG
    MODEL_SLUG="$(echo "${MODEL_ID}" | tr '[:upper:]/' '[:lower:]-' | tr -cd 'a-z0-9-')"

    local CHECK_POD="vllm-sync-check-$(echo "${MODEL_SLUG}" | cut -c1-41)-$(date +%s | tail -c 5)"
    kubectl delete pod "${CHECK_POD}" --namespace="${NAMESPACE}" --ignore-not-found >/dev/null
    cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${CHECK_POD}
  namespace: ${NAMESPACE}
spec:
  restartPolicy: Never
  nodeSelector:
    feature.node.kubernetes.io/pci-10de.present: "true"
  tolerations:
    - key: gpu
      value: "true"
      effect: NoSchedule
  containers:
    - name: check
      image: ${RAY_IMAGE}
      command:
        - python
        - -c
        - |
          import os
          from pathlib import Path
          from safetensors import safe_open

          root = Path("/mnt/models") / os.environ["MODEL_ID"]
          if not (root / "config.json").is_file():
              raise SystemExit(f"missing config.json under {root}")

          safetensor_files = sorted(root.glob("*.safetensors"))
          for path in safetensor_files:
              with safe_open(str(path), framework="pt", device="cpu") as handle:
                  keys = list(handle.keys())
                  if not keys:
                      raise SystemExit(f"{path} has no tensors")

          print(f"validated {root} ({len(safetensor_files)} safetensors file(s))")
      env:
        - name: MODEL_ID
          value: "${MODEL_ID}"
      volumeMounts:
        - name: models
          mountPath: /mnt/models
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
        readOnly: true
EOF

    local VALID=false
    local PHASE=""
    for _ in {1..120}; do
        PHASE="$(kubectl get pod "${CHECK_POD}" --namespace="${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
        case "${PHASE}" in
            Succeeded)
                VALID=true
                break
                ;;
            Failed)
                break
                ;;
        esac
        sleep 1
    done

    if [[ "${VALID}" != "true" ]]; then
        kubectl logs "${CHECK_POD}" --namespace="${NAMESPACE}" 2>/dev/null || true
    fi

    kubectl delete pod "${CHECK_POD}" --namespace="${NAMESPACE}" --ignore-not-found >/dev/null
    [[ "${VALID}" == "true" ]]
}

validate_harbor_model() {
    local MODEL_ID="${1}"
    local HARBOR_TAG
    HARBOR_TAG="$(echo "${MODEL_ID}" | tr '[:upper:]/.+' '[:lower:]---' | tr -cd 'a-z0-9-')"

    local HARBOR_USERNAME HARBOR_PASSWORD
    HARBOR_USERNAME=$(kubectl get secret harbor-credentials -n "${NAMESPACE}" -o jsonpath='{.data.username}' | base64 -d)
    HARBOR_PASSWORD=$(kubectl get secret harbor-credentials -n "${NAMESPACE}" -o jsonpath='{.data.password}' | base64 -d)

    local TMPFILE HTTP_STATUS
    TMPFILE=$(mktemp)
    HTTP_STATUS=$(curl -s -o "${TMPFILE}" -w "%{http_code}" \
        -u "${HARBOR_USERNAME}:${HARBOR_PASSWORD}" \
        -H "Accept: application/vnd.oci.image.manifest.v1+json" \
        "https://${HARBOR_REGISTRY}/v2/${HARBOR_PROJECT}/${HARBOR_TAG}/manifests/latest" 2>/dev/null || echo "0")

    if [[ "${HTTP_STATUS}" != "200" ]]; then
        rm -f "${TMPFILE}"
        return 1
    fi

    if ! jq -e '.layers | length > 0' "${TMPFILE}" >/dev/null 2>&1; then
        echo "Harbor manifest for ${MODEL_ID} has no layers" >&2
        rm -f "${TMPFILE}"
        return 1
    fi

    rm -f "${TMPFILE}"
}

collect_pvc_model_files() {
    local MODEL_ID="${1}"
    local OUTFILE="${2}"
    local MODEL_SLUG
    MODEL_SLUG="$(echo "${MODEL_ID}" | tr '[:upper:]/' '[:lower:]-' | tr -cd 'a-z0-9-')"

    local CHECK_POD="vllm-drift-pvc-$(echo "${MODEL_SLUG}" | cut -c1-42)-$(date +%s | tail -c 5)"
    kubectl delete pod "${CHECK_POD}" --namespace="${NAMESPACE}" --ignore-not-found >/dev/null
    cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${CHECK_POD}
  namespace: ${NAMESPACE}
spec:
  restartPolicy: Never
  nodeSelector:
    feature.node.kubernetes.io/pci-10de.present: "true"
  tolerations:
    - key: gpu
      value: "true"
      effect: NoSchedule
  containers:
    - name: check
      image: ${RAY_IMAGE}
      command:
        - python
        - -c
        - |
          import hashlib
          import json
          import os
          import sys
          from pathlib import Path

          root = Path("/mnt/models") / os.environ["MODEL_ID"]
          if not root.is_dir():
              raise SystemExit(f"missing model directory under {root}")

          records = []
          for path in sorted(p for p in root.iterdir() if p.is_file()):
              digest = hashlib.sha256()
              with path.open("rb") as handle:
                  for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                      digest.update(chunk)
              records.append({
                  "path": path.name,
                  "digest": "sha256:" + digest.hexdigest(),
                  "size": path.stat().st_size,
              })

          json.dump(records, sys.stdout, sort_keys=True)
          sys.stdout.write("\n")
      env:
        - name: MODEL_ID
          value: "${MODEL_ID}"
      volumeMounts:
        - name: models
          mountPath: /mnt/models
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
        readOnly: true
EOF

    local VALID=false
    local PHASE=""
    for _ in {1..3600}; do
        PHASE="$(kubectl get pod "${CHECK_POD}" --namespace="${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
        case "${PHASE}" in
            Succeeded)
                VALID=true
                break
                ;;
            Failed)
                break
                ;;
        esac
        sleep 1
    done

    if [[ "${VALID}" == "true" ]]; then
        kubectl logs "${CHECK_POD}" --namespace="${NAMESPACE}" > "${OUTFILE}"
    else
        kubectl logs "${CHECK_POD}" --namespace="${NAMESPACE}" 2>/dev/null || true
    fi

    kubectl delete pod "${CHECK_POD}" --namespace="${NAMESPACE}" --ignore-not-found >/dev/null
    [[ "${VALID}" == "true" ]] && jq -e 'type == "array"' "${OUTFILE}" >/dev/null
}

collect_harbor_model_files() {
    local MODEL_ID="${1}"
    local OUTFILE="${2}"
    local HARBOR_TAG
    HARBOR_TAG="$(echo "${MODEL_ID}" | tr '[:upper:]/.+' '[:lower:]---' | tr -cd 'a-z0-9-')"

    local HARBOR_USERNAME HARBOR_PASSWORD
    HARBOR_USERNAME=$(kubectl get secret harbor-credentials -n "${NAMESPACE}" -o jsonpath='{.data.username}' | base64 -d)
    HARBOR_PASSWORD=$(kubectl get secret harbor-credentials -n "${NAMESPACE}" -o jsonpath='{.data.password}' | base64 -d)

    local TMPFILE HTTP_STATUS
    TMPFILE=$(mktemp)
    HTTP_STATUS=$(curl -s -o "${TMPFILE}" -w "%{http_code}" \
        -u "${HARBOR_USERNAME}:${HARBOR_PASSWORD}" \
        -H "Accept: application/vnd.oci.image.manifest.v1+json" \
        "https://${HARBOR_REGISTRY}/v2/${HARBOR_PROJECT}/${HARBOR_TAG}/manifests/latest" 2>/dev/null || echo "0")

    if [[ "${HTTP_STATUS}" != "200" ]]; then
        rm -f "${TMPFILE}"
        return 1
    fi

    local VALID=false
    if jq -e '
      [
        .layers[]
        | {
            path: (.annotations["org.opencontainers.image.title"] // .annotations["org.opencontainers.image.ref.name"] // .digest),
            digest: .digest,
            size: .size
          }
      ]
      | sort_by(.path)
    ' "${TMPFILE}" > "${OUTFILE}"; then
        VALID=true
    fi
    rm -f "${TMPFILE}"
    [[ "${VALID}" == "true" ]]
}

report_model_drift() {
    local PVC_FILE="${1}"
    local HARBOR_FILE="${2}"
    local DRIFT_FILE
    DRIFT_FILE=$(mktemp)

    if ! jq -n \
        --slurpfile pvc "${PVC_FILE}" \
        --slurpfile harbor "${HARBOR_FILE}" '
      def by_path($items):
        reduce $items[] as $item ({}; .[$item.path] = $item);

      ($pvc[0] // []) as $pvc_items
      | ($harbor[0] // []) as $harbor_items
      | by_path($pvc_items) as $pvc_map
      | by_path($harbor_items) as $harbor_map
      | {
          missing_in_harbor: [
            $pvc_items[]
            | select($harbor_map[.path] == null)
            | .path
          ],
          extra_in_harbor: [
            $harbor_items[]
            | select($pvc_map[.path] == null)
            | .path
          ],
          digest_mismatches: [
            $pvc_items[]
            | select($harbor_map[.path] != null and $harbor_map[.path].digest != .digest)
            | {
                path: .path,
                pvc_digest: .digest,
                harbor_digest: $harbor_map[.path].digest
              }
          ]
        }
    ' > "${DRIFT_FILE}"; then
        rm -f "${DRIFT_FILE}"
        return 1
    fi

    local DRIFT_COUNT
    DRIFT_COUNT=$(jq '.missing_in_harbor | length' "${DRIFT_FILE}")
    DRIFT_COUNT=$((DRIFT_COUNT + $(jq '.extra_in_harbor | length' "${DRIFT_FILE}")))
    DRIFT_COUNT=$((DRIFT_COUNT + $(jq '.digest_mismatches | length' "${DRIFT_FILE}")))

    if [[ "${DRIFT_COUNT}" -eq 0 ]]; then
        echo "  Drift:  false"
        rm -f "${DRIFT_FILE}"
        return 0
    fi

    echo "  Drift:  true"
    if jq -e '.missing_in_harbor | length > 0' "${DRIFT_FILE}" >/dev/null; then
        echo "    Missing in Harbor:"
        jq -r '.missing_in_harbor[] | "      " + .' "${DRIFT_FILE}"
    fi
    if jq -e '.extra_in_harbor | length > 0' "${DRIFT_FILE}" >/dev/null; then
        echo "    Extra in Harbor:"
        jq -r '.extra_in_harbor[] | "      " + .' "${DRIFT_FILE}"
    fi
    if jq -e '.digest_mismatches | length > 0' "${DRIFT_FILE}" >/dev/null; then
        echo "    Digest mismatch:"
        jq -r '.digest_mismatches[] | "      " + .path + "\n        PVC:    " + .pvc_digest + "\n        Harbor: " + .harbor_digest' "${DRIFT_FILE}"
    fi

    rm -f "${DRIFT_FILE}"
    return 1
}

cmd_verify() {
    local MODEL_ID="${1}"
    if [[ -z "${MODEL_ID}" ]]; then
        echo "Usage: $0 verify <model-id>"
        echo "  e.g.: $0 verify Qwen/Qwen3-8B-AWQ"
        exit 1
    fi

    ensure_namespace_and_pvc
    echo "Verifying ${MODEL_ID}..."

    local PVC_VALID=false HARBOR_VALID=false DRIFT_FREE=false
    local PVC_FILE HARBOR_FILE
    PVC_FILE=$(mktemp)
    HARBOR_FILE=$(mktemp)

    # Basic validation checks that each side exists and is structurally usable.
    # PVC validation reads the mounted model directory; Harbor validation reads
    # the OCI manifest without treating registry blob HEAD quirks as drift.
    if validate_pvc_model "${MODEL_ID}"; then
        PVC_VALID=true
    fi
    if validate_harbor_model "${MODEL_ID}"; then
        HARBOR_VALID=true
    fi

    echo "  PVC:    ${PVC_VALID}"
    echo "  Harbor: ${HARBOR_VALID}"

    # Drift is a stronger check than validity: compare the PVC file set and
    # SHA-256 digests against the Harbor OCI layer names and digests. Only run
    # this expensive comparison after both sides pass basic validation.
    if ${PVC_VALID} && ${HARBOR_VALID}; then
        if collect_pvc_model_files "${MODEL_ID}" "${PVC_FILE}" && collect_harbor_model_files "${MODEL_ID}" "${HARBOR_FILE}"; then
            if report_model_drift "${PVC_FILE}" "${HARBOR_FILE}"; then
                DRIFT_FREE=true
            fi
        else
            echo "  Drift:  true"
            echo "    Could not compare file manifests from both PVC and Harbor."
        fi
    else
        echo "  Drift:  true"
        if ! ${PVC_VALID}; then
            echo "    PVC copy is missing or invalid."
        fi
        if ! ${HARBOR_VALID}; then
            echo "    Harbor copy is missing or invalid."
        fi
    fi
    rm -f "${PVC_FILE}" "${HARBOR_FILE}"

    # The verify command succeeds only when both copies are valid and the
    # content comparison reports no drift.
    ${PVC_VALID} && ${HARBOR_VALID} && ${DRIFT_FREE}
}

cmd_list() {
    ensure_namespace_and_pvc

    # --- Collect PVC models ---
    local POD_NAME="vllm-model-list-$(date +%s)"
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
        - find /mnt/models -mindepth 2 -maxdepth 2 -type d | sed 's|/mnt/models/||' | sort
      volumeMounts:
        - name: models
          mountPath: /mnt/models
          readOnly: true
      resources:
        requests:
          cpu: "100m"
          memory: "64Mi"
        limits:
          cpu: "500m"
          memory: "128Mi"
  volumes:
    - name: models
      persistentVolumeClaim:
        claimName: ${PVC_NAME}
        readOnly: true
EOF
    kubectl wait pod/"${POD_NAME}" \
        --for=jsonpath='{.status.phase}'=Succeeded \
        --namespace="${NAMESPACE}" \
        --timeout=60s >/dev/null
    local PVC_MODELS
    PVC_MODELS=$(kubectl logs "${POD_NAME}" --namespace="${NAMESPACE}")
    kubectl delete pod "${POD_NAME}" --namespace="${NAMESPACE}" --ignore-not-found >/dev/null

    # --- Collect Harbor models ---
    local HARBOR_USERNAME HARBOR_PASSWORD
    HARBOR_USERNAME=$(kubectl get secret harbor-credentials -n "${NAMESPACE}" -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null || true)
    HARBOR_PASSWORD=$(kubectl get secret harbor-credentials -n "${NAMESPACE}" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)

    local HARBOR_MODELS=""
    if [[ -z "${HARBOR_USERNAME}" ]]; then
        HARBOR_MODELS="(no credentials)"
    else
        local TMPFILE HTTP_CODE
        TMPFILE=$(mktemp)
        HTTP_CODE=$(curl -s -o "${TMPFILE}" -w "%{http_code}" \
            -u "${HARBOR_USERNAME}:${HARBOR_PASSWORD}" \
            "https://${HARBOR_REGISTRY}/api/v2.0/projects/${HARBOR_PROJECT}/repositories?page_size=100" 2>/dev/null || echo "0")
        if [[ "${HTTP_CODE}" == "200" ]]; then
            HARBOR_MODELS=$(jq -r '.[].name' "${TMPFILE}" | sed "s|${HARBOR_PROJECT}/||" | sort)
        else
            HARBOR_MODELS="(HTTP ${HTTP_CODE})"
        fi
        rm -f "${TMPFILE}"
    fi

    # --- Display PVC models with Harbor status ---
    printf "%-45s  %s\n" "MODEL" "HARBOR"
    printf "%-45s  %s\n" "-----" "------"

    if [[ "${HARBOR_MODELS}" == "("* ]]; then
        while IFS= read -r pvc; do
            [[ -z "${pvc}" ]] && continue
            printf "%-45s  %s\n" "${pvc}" "${HARBOR_MODELS}"
        done <<< "${PVC_MODELS}"
        return 0
    fi

    while IFS= read -r pvc; do
        [[ -z "${pvc}" ]] && continue
        local harbor_tag
        harbor_tag="$(echo "${pvc}" | tr '[:upper:]/.+' '[:lower:]---' | tr -cd 'a-z0-9-')"
        if echo "${HARBOR_MODELS}" | grep -qx "${harbor_tag}"; then
            printf "%-45s  %s\n" "${pvc}" "${HARBOR_REGISTRY}/${HARBOR_PROJECT}/${harbor_tag}:latest"
        else
            printf "%-45s  %s\n" "${pvc}" "-"
        fi
    done <<< "${PVC_MODELS}"
}

cmd_delete() {
    local MODEL_ID="${1}"
    if [[ -z "${MODEL_ID}" ]]; then
        echo "Usage: $0 delete <model-id>"
        echo "  e.g.: $0 delete Qwen/Qwen3-8B-AWQ"
        exit 1
    fi

    # Safety: refuse if the model is currently listed in the live
    # RayService's MODELS env var. Operator must remove it from
    # gitops/workloads/raw/ray/manifests/ray.yaml and commit first.
    if kubectl -n "${NAMESPACE}" get rayservice ray-vllm >/dev/null 2>&1; then
        local LIVE_MODELS
        LIVE_MODELS=$(kubectl -n "${NAMESPACE}" get rayservice ray-vllm \
            -o jsonpath='{.spec.serveConfigV2}' 2>/dev/null \
            | yq '.applications[0].runtime_env.env_vars.MODELS' - 2>/dev/null \
            | tr ',' '\n' \
            | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        if echo "${LIVE_MODELS}" | grep -Fxq -- "${MODEL_ID}"; then
            echo "Error: ${MODEL_ID} is still listed in RayService MODELS." >&2
            echo "Remove it from gitops/workloads/raw/ray/manifests/ray.yaml and commit first." >&2
            exit 1
        fi
    fi

    local HARBOR_TAG HARBOR_REF MODEL_SLUG JOB_NAME
    HARBOR_TAG="$(echo "${MODEL_ID}" | tr '[:upper:]/.+' '[:lower:]---' | tr -cd 'a-z0-9-')"
    HARBOR_REF="${HARBOR_REGISTRY}/${HARBOR_PROJECT}/${HARBOR_TAG}:latest"
    MODEL_SLUG="$(echo "${MODEL_ID}" | tr '[:upper:]/' '[:lower:]-' | tr -cd 'a-z0-9-')"
    JOB_NAME="vllm-delete-$(echo "${MODEL_SLUG}" | cut -c1-50)"

    ensure_namespace_and_pvc

    local HARBOR_USERNAME HARBOR_PASSWORD
    HARBOR_USERNAME=$(kubectl get secret harbor-credentials -n "${NAMESPACE}" -o jsonpath='{.data.username}' | base64 -d)
    HARBOR_PASSWORD=$(kubectl get secret harbor-credentials -n "${NAMESPACE}" -o jsonpath='{.data.password}' | base64 -d)

    echo "Deleting ${MODEL_ID} from PVC..."

    kubectl delete job "${JOB_NAME}" --namespace "${NAMESPACE}" --ignore-not-found >/dev/null
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
      nodeSelector:
        feature.node.kubernetes.io/pci-10de.present: "true"
      tolerations:
        - key: gpu
          value: "true"
          effect: NoSchedule
      containers:
        - name: delete
          image: busybox
          command:
            - sh
            - -c
            - |
              if [ -d "/mnt/models/${MODEL_ID}" ]; then
                rm -rf "/mnt/models/${MODEL_ID}"
                echo "Deleted from PVC: ${MODEL_ID}"
              else
                echo "Not found on PVC, skipping: ${MODEL_ID}"
              fi
          volumeMounts:
            - name: models
              mountPath: /mnt/models
          resources:
            requests:
              cpu: "100m"
              memory: "64Mi"
            limits:
              cpu: "500m"
              memory: "256Mi"
      volumes:
        - name: models
          persistentVolumeClaim:
            claimName: ${PVC_NAME}
EOF

    kubectl wait job/${JOB_NAME} \
        --for=condition=Complete \
        --namespace ${NAMESPACE} \
        --timeout=120s

    echo "Deleting ${MODEL_ID} from Harbor..."
    local HTTP_STATUS
    HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
        -X DELETE \
        -u "${HARBOR_USERNAME}:${HARBOR_PASSWORD}" \
        "https://${HARBOR_REGISTRY}/api/v2.0/projects/${HARBOR_PROJECT}/repositories/${HARBOR_TAG}" 2>/dev/null || echo "0")
    if [[ "${HTTP_STATUS}" == "200" ]]; then
        echo "Deleted from Harbor: ${HARBOR_REF}"
    elif [[ "${HTTP_STATUS}" == "404" ]]; then
        echo "Not found on Harbor, skipping: ${HARBOR_REF}"
    else
        echo "Harbor delete returned HTTP ${HTTP_STATUS}" >&2
        echo "Check that the robot account has delete permission on project '${HARBOR_PROJECT}'." >&2
        exit 1
    fi

    echo ""
    echo "Delete complete: ${MODEL_ID}"
}

SUBCOMMAND="${1:-}"
shift || true

case "${SUBCOMMAND}" in
    verify | check)  cmd_verify "$@" ;;
    list | status)   cmd_list ;;
    delete | remove) cmd_delete "$@" ;;
    *)               usage; exit 1 ;;
esac
