#!/usr/bin/env bash
set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-piraeus-datastore}"
NODE="${NODE:-c-02}"
PEER="${PEER:-c-01}"
POLL_SECONDS="${POLL_SECONDS:-30}"
RESOURCE_TIMEOUT_SECONDS="${RESOURCE_TIMEOUT_SECONDS:-7200}"
SLEEP_BETWEEN_SECONDS="${SLEEP_BETWEEN_SECONDS:-30}"
LOG_DIR="${LOG_DIR:-tmp}"
DRY_RUN=false
ONLY=""
LOG_FILE=""

usage() {
    cat <<'EOF'
Usage: drbd-verify-c02.sh [options]

Sequentially run `drbdadm verify` on every DRBD resource that is UpToDate on
both c-02 and c-01. Mismatches are logged; no automatic resync is triggered.

Options:
  --dry-run       List the resources that would be verified and exit
  --only RESOURCE Verify a single resource
  -h, --help      Show this help

Environment:
  POLL_SECONDS                 Status poll interval (default: 30)
  RESOURCE_TIMEOUT_SECONDS     Per-resource timeout (default: 7200)
  SLEEP_BETWEEN_SECONDS        Delay between resources (default: 30)
  LOG_DIR                      Log directory (default: tmp)
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        --only) ONLY="${2:?--only requires a resource name}"; shift 2 ;;
        -h | --help) usage; exit 0 ;;
        *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done

command -v kubectl >/dev/null 2>&1 || { echo "kubectl not found" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq not found" >&2; exit 1; }

mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/drbd-verify-${NODE}-$(date -u +%Y%m%dT%H%M%SZ).log"

log() {
    printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG_FILE"
}

SAT="$(kubectl -n "$NAMESPACE" get pods -l app.kubernetes.io/component=linstor-satellite -o json 2>/dev/null |
    jq -r --arg node "$NODE" '.items[] | select(.spec.nodeName == $node and .status.phase == "Running") | .metadata.name' |
    head -n1)"
[[ -n "$SAT" ]] || { echo "LINSTOR satellite for ${NODE} not found" >&2; exit 1; }

if [[ -n "$ONLY" ]]; then
    RESOURCES=("$ONLY")
else
    mapfile -t RESOURCES < <(
        kubectl linstor --no-color resource list 2>/dev/null |
            awk -F'│' -v node="$NODE" -v peer="$PEER" '
                { gsub(/ /, "", $2); gsub(/ /, "", $3); gsub(/ /, "", $7) }
                $2 == "" || $2 == "ResourceName" { next }
                $3 == peer && $7 == "UpToDate" { peer_ok[$2] = 1 }
                $3 == node && $7 == "UpToDate" { node_ok[$2] = 1 }
                END { for (r in node_ok) if (peer_ok[r]) print r }
            ' | sort
    )
fi

[[ ${#RESOURCES[@]} -gt 0 ]] || { echo "No resources to verify" >&2; exit 1; }

log "DRBD verify starting: node=${NODE} peer=${PEER} satellite=${SAT}"
log "Resources to verify: ${#RESOURCES[@]}"
printf '%s\n' "${RESOURCES[@]}" | tee -a "$LOG_FILE"

if [[ "$DRY_RUN" == true ]]; then
    log "Dry-run only; no verification started"
    exit 0
fi

RESULTS=()
FAILED=0

for rsc in "${RESOURCES[@]}"; do
    log "=== verify ${rsc} ==="

    if ! kubectl -n "$NAMESPACE" exec "$SAT" -c linstor-satellite -- drbdadm verify "$rsc" >>"$LOG_FILE" 2>&1; then
        log "FAILED start: ${rsc}"
        RESULTS+=("FAILED_START ${rsc}")
        FAILED=1
        sleep "$SLEEP_BETWEEN_SECONDS"
        continue
    fi

    deadline=$((SECONDS + RESOURCE_TIMEOUT_SECONDS))
    json=""
    state=""
    timed_out=false

    while :; do
        json="$(kubectl -n "$NAMESPACE" exec "$SAT" -c linstor-satellite -- drbdsetup status --json "$rsc" 2>/dev/null || true)"
        if [[ -n "$json" ]]; then
            state="$(jq -r --arg peer "$PEER" '[.[0].connections[]? | select(.name == $peer) | .peer_devices[0]["replication-state"]][0] // empty' <<<"$json")"
            case "$state" in
                Verify*) ;;
                "") log "WARN: peer ${PEER} not connected for ${rsc}" ;;
                *) break ;;
            esac
        else
            log "WARN: no DRBD status for ${rsc}"
        fi

        if ((SECONDS > deadline)); then
            log "TIMEOUT: ${rsc}"
            RESULTS+=("TIMEOUT ${rsc}")
            FAILED=1
            timed_out=true
            break
        fi
        sleep "$POLL_SECONDS"
    done

    if [[ "$timed_out" == true ]]; then
        sleep "$SLEEP_BETWEEN_SECONDS"
        continue
    fi

    if [[ -z "$json" ]]; then
        log "FAILED status: ${rsc}"
        RESULTS+=("FAILED_STATUS ${rsc}")
        FAILED=1
        sleep "$SLEEP_BETWEEN_SECONDS"
        continue
    fi

    oos="$(jq -r --arg peer "$PEER" '[.[0].connections[]? | select(.name == $peer) | .peer_devices[0]["out-of-sync"]][0] // 0' <<<"$json")"
    percent="$(jq -r --arg peer "$PEER" '[.[0].connections[]? | select(.name == $peer) | .peer_devices[0]["percent-in-sync"]][0] // 0' <<<"$json")"
    details="$(jq -r --arg peer "$PEER" '[.[0].connections[]? | select(.name == $peer) | .peer_devices[0]["has-online-verify-details"]][0] // false' <<<"$json")"

    if jq -e --arg peer "$PEER" '
        .[0].connections[]? | select(.name == $peer) | .peer_devices[0] |
        ((.["out-of-sync"] // 0) > 0) or
        ((.["percent-in-sync"] // 0) < 100) or
        (.["has-online-verify-details"] // false)
    ' <<<"$json" >/dev/null; then
        log "MISMATCH: ${rsc} out-of-sync=${oos} percent-in-sync=${percent} verify-details=${details}"
        printf '%s\n' "$json" >>"$LOG_FILE"
        RESULTS+=("MISMATCH ${rsc} out-of-sync=${oos} percent-in-sync=${percent}")
        FAILED=1
    else
        log "PASS: ${rsc} out-of-sync=${oos} percent-in-sync=${percent}"
        RESULTS+=("PASS ${rsc}")
    fi

    sleep "$SLEEP_BETWEEN_SECONDS"
done

log "=== SUMMARY ==="
for result in "${RESULTS[@]}"; do
    log "$result"
done
log "Log file: ${LOG_FILE}"

if ((FAILED != 0)); then
    log "One or more resources failed, timed out, or mismatched"
    exit 1
fi

log "All resources verified without mismatches"
