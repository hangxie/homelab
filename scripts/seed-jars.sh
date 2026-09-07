#!/usr/bin/env bash
# Seed the Harbor `jars` project with the runtime jars workload init containers
# pull at pod start, replacing per-start downloads from GitHub Releases and
# Maven Central.
#
# Prereqs:
#   - oras and curl on PATH
#   - The `jars` project and its push robot created on the media server, like
#     `llm-models` and `robot$llm-models+ci`. This script does not create them.
#     The project must be public: consumers pull anonymously, so no workload
#     ever holds a registry credential.
#   - Push credentials, from either:
#       HARBOR_USERNAME + HARBOR_PASSWORD env vars
#       VAULT_ADDR + VAULT_TOKEN  (reads harbor/jars from Vault)
#
# Idempotent: an existing tag is left alone; --force re-pushes.
#
# Pull-only, unlike the self-seeding llm-models path: the init containers have
# no upstream fallback, so seed a jar here before merging the manifest that
# references it, or the consuming pods will not start.

set -euo pipefail

HARBOR_REGISTRY="${HARBOR_REGISTRY:-media.xiehang.com}"
HARBOR_PROJECT="${HARBOR_PROJECT:-jars}"
KV_MOUNT="homelab"
FORCE=false

usage() {
  cat >&2 <<EOF
usage: $(basename "$0") [--force] [artifact:tag ...]

With no artifact arguments every artifact below is seeded.

  --force   re-push even when the tag already exists in Harbor

env:
  HARBOR_REGISTRY   default media.xiehang.com
  HARBOR_PROJECT    default jars
  HARBOR_USERNAME   push robot; falls back to Vault harbor/jars
  HARBOR_PASSWORD   push robot; falls back to Vault harbor/jars
EOF
  exit 2
}

# The tag names the version that pins each set: the agent release, the Hive
# version the auxlib set is built for, the hadoop-aws version for Spark.
ALL_ARTIFACTS=(
  jmx-prometheus-javaagent:1.6.0
  hive-metastore-auxlib:4.2.1
  spark-history-s3a:3.3.4
)

# "<filename> <url>" per line. Filenames are the contract with the init
# containers: `oras pull` restores them verbatim, and the -javaagent and
# METASTORE_AUX_JARS_PATH paths in the manifests are written against them.
artifact_files() {
  local M=https://repo1.maven.org/maven2
  local G=https://github.com/prometheus/jmx_exporter/releases/download
  case "$1" in
    jmx-prometheus-javaagent:1.6.0)
      echo "jmx_prometheus_javaagent.jar $G/1.6.0/jmx_prometheus_javaagent-1.6.0.jar"
      ;;
    # 2.24.6 is the aws-java-sdk-v2.version hadoop-aws 3.4.1 is built against;
    # a mismatch surfaces as NoSuchMethodError on s3a init.
    hive-metastore-auxlib:4.2.1)
      echo "postgresql.jar $M/org/postgresql/postgresql/42.7.13/postgresql-42.7.13.jar"
      echo "hadoop-aws.jar $M/org/apache/hadoop/hadoop-aws/3.4.1/hadoop-aws-3.4.1.jar"
      echo "aws-sdk-bundle.jar $M/software/amazon/awssdk/bundle/2.24.6/bundle-2.24.6.jar"
      ;;
    # apache/spark:3.5.5 is built against Hadoop 3.3.4, hence SDK v1. Do not
    # bump these two independently.
    spark-history-s3a:3.3.4)
      echo "hadoop-aws-3.3.4.jar $M/org/apache/hadoop/hadoop-aws/3.3.4/hadoop-aws-3.3.4.jar"
      echo "aws-java-sdk-bundle-1.12.262.jar $M/com/amazonaws/aws-java-sdk-bundle/1.12.262/aws-java-sdk-bundle-1.12.262.jar"
      ;;
    *)
      echo "unknown artifact: $1" >&2
      return 1
      ;;
  esac
}

log() { printf '[seed-jars] %s\n' "$*"; }

ARTIFACTS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=true ;;
    -h|--help) usage ;;
    -*) echo "unknown flag: $1" >&2; usage ;;
    *) ARTIFACTS+=("$1") ;;
  esac
  shift
done
[[ ${#ARTIFACTS[@]} -gt 0 ]] || ARTIFACTS=("${ALL_ARTIFACTS[@]}")

# Reject unknown names up front: artifact_files runs in a process substitution
# below, where its non-zero return neither trips set -e nor reaches the loop.
for artifact in "${ARTIFACTS[@]}"; do
  artifact_files "$artifact" >/dev/null
done

for cmd in oras curl; do
  command -v "$cmd" >/dev/null || { echo "$cmd not on PATH" >&2; exit 1; }
done
# Same resolution order as seed-certs.sh: explicit env first, Vault second.
if [[ -z "${HARBOR_USERNAME:-}" || -z "${HARBOR_PASSWORD:-}" ]]; then
  if command -v vault >/dev/null 2>&1 \
     && [[ -n "${VAULT_ADDR:-}" && -n "${VAULT_TOKEN:-}" ]]; then
    HARBOR_USERNAME="$(vault kv get -field=username "$KV_MOUNT/harbor/jars")"
    HARBOR_PASSWORD="$(vault kv get -field=password "$KV_MOUNT/harbor/jars")"
  else
    echo "set HARBOR_USERNAME + HARBOR_PASSWORD, or VAULT_ADDR + VAULT_TOKEN to read from Vault" >&2
    exit 1
  fi
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

for artifact in "${ARTIFACTS[@]}"; do
  ref="$HARBOR_REGISTRY/$HARBOR_PROJECT/$artifact"

  if ! $FORCE && oras manifest fetch --descriptor "$ref" >/dev/null 2>&1; then
    log "$ref already present; skipping"
    continue
  fi

  dir="$WORK_DIR/${artifact%%:*}"
  mkdir -p "$dir"
  names=()
  while read -r name url; do
    [[ -n "$name" ]] || continue
    log "downloading $name"
    curl -fsSL -o "$dir/$name" "$url"
    names+=("$name")
  done < <(artifact_files "$artifact")

  log "pushing $ref"
  # Subshell so the cd does not leak; oras records the paths it is given and
  # the init containers expect bare filenames.
  (
    cd "$dir"
    printf '%s' "$HARBOR_PASSWORD" |
      oras push -u "$HARBOR_USERNAME" --password-stdin "$ref" "${names[@]}"
  )
done

log "done"
