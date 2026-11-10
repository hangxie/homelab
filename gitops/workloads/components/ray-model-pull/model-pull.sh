#!/bin/bash
# Init container that makes sure each model is under /mnt/models, pulling from
# the Harbor cache first and HuggingFace second, then pushing a fresh download
# back to Harbor. The model list is MODEL_IDS (comma-separated) when set, else
# the MODELS_VAR env var of Serve application RAYSERVE_APP in the live RayService
# RAYSERVICE_NAME (the Ray GPU workers). HF_EXCLUDE adds space-separated globs to
# skip on a HuggingFace download.
set -eu
export PATH="/shared:$PATH"
mkdir -p /mnt/models

if [ -n "${MODEL_IDS:-}" ]; then
  MODELS=$(echo "${MODEL_IDS}" | tr ',' '\n')
else
  MODELS=$(kubectl get rayservice "${RAYSERVICE_NAME}" \
             -o jsonpath='{.spec.serveConfigV2}' \
           | yq '.applications[] | select(.name == strenv(RAYSERVE_APP)) | .runtime_env.env_vars[strenv(MODELS_VAR)]' - \
           | tr ',' '\n')
fi

if [ -z "${MODELS}" ] || [ "${MODELS}" = "null" ]; then
  echo "No models configured; nothing to pull."
  exit 0
fi

# Mistral repos also ship a consolidated.safetensors copy of the weights in
# Mistral format, which vLLM never reads here.
read -ra EXTRA_EXCLUDES <<< "${HF_EXCLUDE:-}"
EXCLUDES=('consolidated*' "${EXTRA_EXCLUDES[@]}")

slug() {
  echo "$1" | tr '[:upper:]/.+_' '[:lower:]----' \
            | tr -cd 'a-z0-9-' | tr -s '-'
}

for MODEL_ID in ${MODELS}; do
  MODEL_ID="$(echo "${MODEL_ID}" | xargs)"
  [ -z "${MODEL_ID}" ] && continue
  DEST="/mnt/models/${MODEL_ID}"
  LOCK="/mnt/models/.pull.lock.$(slug "${MODEL_ID}")"
  HARBOR_TAG="$(slug "${MODEL_ID}")"
  HARBOR_REF="${HARBOR_REGISTRY}/${HARBOR_PROJECT}/${HARBOR_TAG}:latest"

  (
    exec 9>"${LOCK}"
    flock -w 3600 -x 9 || { echo "ERROR: lock not acquired for ${MODEL_ID}" >&2; exit 1; }

    harbor_has_model() {
      HARBOR_REPO="${HARBOR_TAG}" python - <<'PY'
import base64
import os
import sys
import urllib.error
import urllib.request

registry = os.environ["HARBOR_REGISTRY"]
project = os.environ["HARBOR_PROJECT"]
repo = os.environ["HARBOR_REPO"]
username = os.environ["HARBOR_USERNAME"]
password = os.environ["HARBOR_PASSWORD"]
url = f"https://{registry}/v2/{project}/{repo}/manifests/latest"
request = urllib.request.Request(
    url,
    headers={
        "Accept": "application/vnd.oci.image.manifest.v1+json",
        "Authorization": "Basic "
        + base64.b64encode(f"{username}:{password}".encode()).decode(),
    },
)
try:
    with urllib.request.urlopen(request, timeout=20) as response:
        sys.exit(0 if response.status == 200 else 1)
except urllib.error.HTTPError as exc:
    sys.exit(1 if exc.code == 404 else 2)
except Exception:
    sys.exit(2)
PY
    }
    push_to_harbor() {
      echo "Pushing to Harbor: ${HARBOR_REF}"
      (
        cd "${DEST}"
        # Top-level files and directories, minus hf's .cache. oras packs each
        # directory (e.g. Qwen3-TTS's speech_tokenizer/) as one tarball and pull
        # unpacks it. Word-split intentionally so each entry is a separate arg.
        ENTRIES=$(find . -mindepth 1 -maxdepth 1 ! -name .cache | sed 's|^\./||' | tr '\n' ' ')
        if [ -z "${ENTRIES}" ]; then
          echo "ERROR: nothing found under ${DEST}" >&2
          exit 1
        fi
        echo "${HARBOR_PASSWORD}" | oras push -u "${HARBOR_USERNAME}" --password-stdin \
             "${HARBOR_REF}" ${ENTRIES}
      )
    }

    # hf download writes config.json before the weights and leaves
    # *.incomplete files behind when interrupted, so config.json alone
    # doesn't mean the copy is whole.
    pvc_complete() {
      [ -f "${DEST}/config.json" ] \
        && [ -z "$(find "${DEST}/.cache" -name '*.incomplete' 2>/dev/null | head -1)" ]
    }

    if pvc_complete; then
      if harbor_has_model; then
        echo "PVC and Harbor ok: ${MODEL_ID}"
        exit 0
      fi
      echo "PVC ok but Harbor cache missing: ${MODEL_ID}"
      push_to_harbor || { echo "ERROR: Harbor push failed for ${HARBOR_REF}" >&2; exit 1; }
      echo "Pushed to Harbor: ${HARBOR_REF}"
      exit 0
    fi

    mkdir -p "${DEST}"
    chmod -R 777 "/mnt/models/$(dirname "${MODEL_ID}")"

    echo "Attempting Harbor pull: ${HARBOR_REF}"
    if echo "${HARBOR_PASSWORD}" | oras pull -u "${HARBOR_USERNAME}" --password-stdin \
         "${HARBOR_REF}" --output "${DEST}" \
       && [ -f "${DEST}/config.json" ]; then
      echo "Pulled from Harbor: ${MODEL_ID}"
      exit 0
    fi

    if [ -z "${HF_TOKEN:-}" ]; then
      echo "ERROR: HF_TOKEN empty; homelab policy requires a token." >&2
      exit 1
    fi

    echo "Downloading from HuggingFace: ${MODEL_ID}"
    # errexit is off inside this ( ... ) || exit 1 subshell, so a failed
    # download has to stop the push explicitly.
    # The library, not the `hf` CLI: the CLI in Open WebUI's huggingface_hub
    # exits non-zero after a successful download. Reads HF_TOKEN from the env.
    python - "${MODEL_ID}" "${DEST}" "${EXCLUDES[@]}" <<'PY' \
      || { echo "ERROR: HF download failed for ${MODEL_ID}" >&2; exit 1; }
import sys
from huggingface_hub import snapshot_download

snapshot_download(repo_id=sys.argv[1], local_dir=sys.argv[2], ignore_patterns=sys.argv[3:])
PY
    pvc_complete || { echo "ERROR: HF download incomplete" >&2; exit 1; }

    push_to_harbor || { echo "ERROR: Harbor push failed for ${HARBOR_REF}" >&2; exit 1; }
    echo "Pushed to Harbor: ${HARBOR_REF}"
  ) || exit 1
done

echo "All configured models present on PVC."
