# shellcheck shell=bash
#
# Runs one CLI in a one-shot pod with the caller's args, piped stdin, streamed
# output and the tool's exit code. Used by the CLI-wrapper plugins.

if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required" >&2
    exit 1
fi

# oneshot_run NAMESPACE NAME IMAGE SCRIPT CONTAINER_JSON VOLUMES_JSON [ARGS...]
#
# SCRIPT runs in bash with ARGS as "$@" and must exec the tool; CONTAINER_JSON
# is merged into the container, VOLUMES_JSON is the pod's volumes.
oneshot_run() {
    local namespace="$1" name="$2" image="$3" script="$4" container="$5" volumes="$6"
    shift 6

    local pod="homelab-${name}-cli-$$-${RANDOM}"
    local tty=false
    [[ -t 0 && -t 1 ]] && tty=true

    # Hold the tool until kubectl attaches, else a fast command exits first and
    # kubectl prints it twice via the logs fallback. Attach shows as the pty
    # getting a size (busybox stty prints nothing before) or the sentinel line.
    local wait_attach='read -r -t 60 _ || { echo "kubectl never attached" >&2; exit 1; }'
    # shellcheck disable=SC2016 # expands in the container, not here
    [[ "$tty" == true ]] && wait_attach='for _ in $(seq 600); do s=$(stty size 2>/dev/null); [[ -n "$s" && "$s" != "0 0" ]] && break; sleep 0.1; done'

    local overrides
    overrides=$(jq -nc \
        --arg pod "$pod" \
        --arg name "$name" \
        --arg image "$image" \
        --arg script "set -euo pipefail
${wait_attach}
${script}" \
        --argjson tty "$tty" \
        --argjson container "$container" \
        --argjson volumes "$volumes" \
        '{
            apiVersion: "v1",
            kind: "Pod",
            metadata: { name: $pod },
            spec: {
                restartPolicy: "Never",
                containers: [({
                    name: $name,
                    image: $image,
                    stdin: true,
                    stdinOnce: true,
                    tty: $tty,
                    command: ["bash", "-c", $script, $name],
                    args: $ARGS.positional
                } + $container)],
                volumes: $volumes
            }
        }' \
        --args -- "$@")

    # Drop kubectl's redundant "pod ... terminated (Error)" line.
    local noise="^pod ${namespace}/${pod} terminated"

    if [[ "$tty" == true ]]; then
        kubectl run "$pod" -n "$namespace" --rm -it --quiet --restart=Never \
            --image="$image" --overrides="$overrides" 2> >(grep -v "$noise" >&2)
        return $?
    fi

    # Feed stdin through a FIFO from a background cat, killed when kubectl
    # returns, so a tool that never reads stdin can't leave it blocked.
    ONESHOT_POD="$pod"
    ONESHOT_NAMESPACE="$namespace"
    ONESHOT_FIFO_DIR=$(mktemp -d)
    trap oneshot_cleanup EXIT
    trap 'exit 130' INT TERM
    mkfifo "$ONESHOT_FIFO_DIR/stdin"
    exec 3<&0
    ( echo; exec cat <&3 ) >"$ONESHOT_FIFO_DIR/stdin" &
    ONESHOT_FEEDER=$!

    kubectl run "$pod" -n "$namespace" --restart=Never --attach --stdin --quiet \
        --image="$image" --overrides="$overrides" <"$ONESHOT_FIFO_DIR/stdin" \
        2> >(grep -v "$noise" >&2)

    local phase=""
    for _ in $(seq 60); do
        phase=$(kubectl get pod "$pod" -n "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null)
        [[ "$phase" == "Succeeded" || "$phase" == "Failed" ]] && break
        sleep 1
    done

    local code
    code=$(kubectl get pod "$pod" -n "$namespace" \
        -o jsonpath="{.status.containerStatuses[?(@.name==\"${name}\")].state.terminated.exitCode}" 2>/dev/null)
    [[ "$code" =~ ^[0-9]+$ ]] || code=1
    return "$code"
}

oneshot_cleanup() {
    [[ -n "${ONESHOT_FEEDER:-}" ]] && { kill "$ONESHOT_FEEDER" 2>/dev/null; wait "$ONESHOT_FEEDER" 2>/dev/null; }
    [[ -n "${ONESHOT_FIFO_DIR:-}" ]] && rm -rf "$ONESHOT_FIFO_DIR"
    [[ -n "${ONESHOT_POD:-}" ]] && kubectl delete pod "$ONESHOT_POD" -n "$ONESHOT_NAMESPACE" \
        --ignore-not-found --wait=false --grace-period=1 >/dev/null 2>&1
}
