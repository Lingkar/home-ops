#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

CONFIG="${SCRIPT_DIR}/c02-shutdown.yaml"
EXTRA_CONFIG="${C02_EXTRA_CONFIG:-}"
APPLY=false
RESTORE=false
SKIP_DRAIN=false
SKIP_DRBD=false
SKIP_SHUTDOWN=false
FORCE_DRAIN=false
WRITE_STATE_ONLY=false
EXISTING_OUTAGE=false
SKIP_PATCHES=false
SKIP_PIN_CHECKS=false
YES=false
STATE_FILE_OPT=""
STATE_FILE=""
STATE_TMP=""

usage() {
    cat <<'EOF'
Usage: c02-shutdown.sh [options]

Shut c-02 down for a two-node maintenance window (default is DRY RUN).

Options:
  --config FILE        Config file (default: scripts/c02-shutdown.yaml)
  --extra-config FILE  Optional extra config (merged lists; useful for private workloads)
  --plan               Print the plan only (default)
  --apply              Execute the plan
  --restore            Reverse the change using the latest state file
  --state-file FILE    State file to write (apply) or read (restore)
  --write-state-only   Collect and write the state file, but make no changes
  --existing-outage     c-02 is already down; skip target-node checks and
                        drain/drbd/shutdown, only suspend/scale/verify
  --skip-patches        Do not sync the MySQL pod template from the CR
  --skip-pin-checks     Skip the MySQL/Harbor GitOps pin preflight checks
  --scale-only         Suspend Flux and scale apps, but do not drain/drbd/shutdown
  --no-drain           Do not run kubectl drain
  --no-drbd            Do not run drbdadm down all
  --no-shutdown        Do not run talosctl shutdown
  --force-drain        Add --disable-eviction to kubectl drain (bypass PDBs)
  --yes                Skip the interactive confirmation
  -h, --help           Show this help

Examples:
  task c02:shutdown
  task c02:shutdown:apply
  task c02:restore

  ./scripts/c02-shutdown.sh --config scripts/c02-shutdown.yaml --apply
  ./scripts/c02-shutdown.sh --apply --scale-only
  ./scripts/c02-shutdown.sh --apply --no-shutdown
  ./scripts/c02-shutdown.sh --restore --state-file tmp/c02-shutdown-state-...json
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)
            CONFIG="${2:?--config requires a path}"
            shift 2
            ;;
        --extra-config)
            EXTRA_CONFIG="${2:?--extra-config requires a path}"
            shift 2
            ;;
        --plan)
            APPLY=false
            shift
            ;;
        --apply)
            APPLY=true
            shift
            ;;
        --restore)
            RESTORE=true
            shift
            ;;
        --state-file)
            STATE_FILE_OPT="${2:?--state-file requires a path}"
            shift 2
            ;;
        --write-state-only)
            APPLY=false
            WRITE_STATE_ONLY=true
            shift
            ;;
        --existing-outage)
            APPLY=true
            EXISTING_OUTAGE=true
            SKIP_DRAIN=true
            SKIP_DRBD=true
            SKIP_SHUTDOWN=true
            shift
            ;;
        --skip-patches)
            SKIP_PATCHES=true
            shift
            ;;
        --skip-pin-checks)
            SKIP_PIN_CHECKS=true
            shift
            ;;
        --scale-only)
            APPLY=true
            SKIP_DRAIN=true
            SKIP_DRBD=true
            SKIP_SHUTDOWN=true
            shift
            ;;
        --no-drain)
            SKIP_DRAIN=true
            shift
            ;;
        --no-drbd)
            SKIP_DRBD=true
            shift
            ;;
        --no-shutdown)
            SKIP_SHUTDOWN=true
            shift
            ;;
        --force-drain)
            FORCE_DRAIN=true
            shift
            ;;
        --yes)
            YES=true
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            log error "Unknown argument: $1"
            ;;
    esac
done

[[ -f "${CONFIG}" ]] || log error "Config file not found: ${CONFIG}"
CONFIG="$(cd "$(dirname "${CONFIG}")" && pwd)/$(basename "${CONFIG}")"
CONFIG_FILES=("${CONFIG}")
if [[ -n "${EXTRA_CONFIG}" ]]; then
    [[ -f "${EXTRA_CONFIG}" ]] || log error "Extra config file not found: ${EXTRA_CONFIG}"
    EXTRA_CONFIG="$(cd "$(dirname "${EXTRA_CONFIG}")" && pwd)/$(basename "${EXTRA_CONFIG}")"
    CONFIG_FILES+=("${EXTRA_CONFIG}")
fi

if [[ -z "${KUBECONFIG:-}" && -f "${ROOT_DIR}/../home-ops-secrets/kubeconfig" ]]; then
    export KUBECONFIG="${ROOT_DIR}/../home-ops-secrets/kubeconfig"
fi
if [[ -z "${TALOSCONFIG:-}" && -f "${ROOT_DIR}/../home-ops-secrets/talos/talosconfig" ]]; then
    export TALOSCONFIG="${ROOT_DIR}/../home-ops-secrets/talos/talosconfig"
fi

check_cli kubectl jq yq
[[ -n "${KUBECONFIG:-}" ]] || log error "KUBECONFIG is not set"
if [[ "${RESTORE}" == false && "${SKIP_SHUTDOWN}" == false ]]; then
    check_cli talosctl
    [[ -n "${TALOSCONFIG:-}" ]] || log error "TALOSCONFIG is not set"
fi

NODE_NAME="$(yq -r '.node.name // ""' "${CONFIG}")"
NODE_IP="$(yq -r '.node.ip // ""' "${CONFIG}")"
REFUSE_CONTROL_PLANE="$(yq -r '.node.refuseControlPlane // true' "${CONFIG}")"
DRAIN="$(yq -r '.shutdown.drain // true' "${CONFIG}")"
DRBD_DOWN="$(yq -r '.shutdown.drbdDown // true' "${CONFIG}")"
TALOS_SHUTDOWN="$(yq -r '.shutdown.talosShutdown // true' "${CONFIG}")"
DRAIN_FORCE_CFG="$(yq -r '.shutdown.drainForce // false' "${CONFIG}")"
WAIT_TIMEOUT="$(yq -r '.shutdown.waitTimeoutSeconds // 900' "${CONFIG}")"
CR_WAIT="$(yq -r '.shutdown.customResourceWaitSeconds // 180' "${CONFIG}")"
POST_SHUTDOWN_WAIT="$(yq -r '.shutdown.postShutdownWaitSeconds // 180' "${CONFIG}")"
SCALED_POD_WAIT="$(yq -r '.shutdown.scaledPodWaitSeconds // 120' "${CONFIG}")"

[[ -n "${NODE_NAME}" ]] || log error "node.name is empty in ${CONFIG}"
[[ -n "${NODE_IP}" ]] || log error "node.ip is empty in ${CONFIG}"
if [[ "${NODE_NAME}" == "c-01" && "${REFUSE_CONTROL_PLANE}" == "true" ]]; then
    log error "${NODE_NAME} is the control-plane node; refusing to shut it down"
fi
if [[ "${FORCE_DRAIN}" == true ]]; then
    DRAIN_FORCE_CFG=true
fi

mapfile -t REQUIRE_ONLINE < <(yq -r '.node.requireOnline[]?' "${CONFIG_FILES[@]}" | grep -v '^---$')
mapfile -t KEEP_NAMESPACES < <(yq -r '.keep.namespaces[]?' "${CONFIG_FILES[@]}" | grep -v '^---$')
mapfile -t SUSPEND_KUSTOMIZATIONS < <(yq -r '.flux.suspendKustomizations[]?' "${CONFIG_FILES[@]}" | grep -v '^---$')
mapfile -t EXTRA_KUSTOMIZATIONS < <(yq -r '.flux.extraKustomizations[]?' "${CONFIG_FILES[@]}" | grep -v '^---$')
mapfile -t EXTRA_HELMRELEASES < <(yq -r '.flux.extraHelmReleases[]?' "${CONFIG_FILES[@]}" | grep -v '^---$')
mapfile -t SCALE_NAMESPACES < <(yq -r '.scale.namespaces[]?' "${CONFIG_FILES[@]}" | grep -v '^---$')
mapfile -t SCALE_EXCLUDE < <(yq -r '.scale.exclude[]?' "${CONFIG_FILES[@]}" | grep -v '^---$')
mapfile -t STOP_DAEMONSETS < <(yq -r '.scale.daemonSets[]?' "${CONFIG_FILES[@]}" | grep -v '^---$')
mapfile -t SUSPEND_CRONJOBS < <(yq -r '.scale.cronJobs[]?' "${CONFIG_FILES[@]}" | grep -v '^---$')
mapfile -t PREDRAIN_DELETE_PODS < <(yq -r '.preDrainDeletePods[]?' "${CONFIG_FILES[@]}" | grep -v '^---$')

declare -a KUSTOMIZATIONS=()
declare -a HELMRELEASES=()
declare -a WORKLOADS=()
declare -a DAEMONSETS=()
declare -a CRONJOBS_DONE=()
declare -a CUSTOM_RESOURCE_KEYS=()
declare -A KUST_SEEN=()
declare -A HR_SEEN=()

in_array() {
    local needle="$1"
    shift
    local item
    for item in "$@"; do
        [[ "${item}" == "${needle}" ]] && return 0
    done
    return 1
}

is_yaml_entry() {
    [[ -n "${1:-}" && "${1}" != \#* && "${1}" != "---" ]]
}

cleanup() {
    if [[ -n "${STATE_TMP}" && -d "${STATE_TMP}" ]]; then
        rm -rf "${STATE_TMP}"
    fi
}
trap cleanup EXIT

linstor_cmd() {
    kubectl -n piraeus-datastore exec deploy/linstor-controller -- \
        linstor --no-pager "$@" 2>/dev/null
}

strip_ansi() {
    sed -E 's/\x1b\[[0-9;]*m//g'
}

linstor_node_online() {
    local node="$1"
    linstor_cmd node list 2>/dev/null | strip_ansi | awk -F'│' -v n="${node}" '
        { gsub(/ /, "", $2); gsub(/ /, "", $6) }
        $2 == n && $6 == "Online" { found = 1 }
        END { exit(found ? 0 : 1) }
    '
}

node_ready() {
    local node="$1"
    local ready
    ready="$(kubectl get node "${node}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
    [[ "${ready}" == "True" ]]
}

wait_for_node_ready() {
    local node="$1" deadline=$((SECONDS + WAIT_TIMEOUT))
    while ! node_ready "${node}"; do
        if ((SECONDS > deadline)); then
            return 1
        fi
        sleep 5
    done
    return 0
}

wait_for_linstor_online() {
    local node="$1" deadline=$((SECONDS + WAIT_TIMEOUT))
    while ! linstor_node_online "${node}"; do
        if ((SECONDS > deadline)); then
            return 1
        fi
        sleep 5
    done
    return 0
}

require_arch_pin() {
    local kind="$1" ns="$2" name="$3" arch
    if ! kubectl get "${kind}" "${name}" -n "${ns}" >/dev/null 2>&1; then
        log error "Expected ${kind}/${ns}/${name} not found; reconcile the GitOps commit first"
    fi
    arch="$(kubectl get "${kind}" "${name}" -n "${ns}" -o json |
        jq -r '.spec.template.spec.nodeSelector["kubernetes.io/arch"] // ""')"
    [[ "${arch}" == "amd64" ]] || log error "${kind}/${ns}/${name} is not pinned to amd64 (nodeSelector.kubernetes.io/arch=${arch:-<unset>}); reconcile the GitOps right-size commit first"
}

require_harbor_pins() {
    require_arch_pin Deployment harbor-system harbor-core
    require_arch_pin Deployment harbor-system harbor-jobservice
    require_arch_pin Deployment harbor-system harbor-portal
    require_arch_pin Deployment harbor-system harbor-registry
    require_arch_pin StatefulSet harbor-system harbor-trivy
    require_arch_pin StatefulSet harbor-system harbor-redis

    local cr
    cr="$(kubectl get cluster cnpg-harbor -n harbor-system -o json 2>/dev/null || true)"
    [[ -n "${cr}" ]] || log error "Cluster/harbor-system/cnpg-harbor not found"
    if ! jq -e '.spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[]?.matchExpressions[]? | select(.key == "kubernetes.io/arch") | .values | index("amd64")' <<<"${cr}" >/dev/null; then
        log error "cnpg-harbor is not pinned to amd64; reconcile the GitOps right-size commit first"
    fi
}

require_mysql_matches_git() {
    local manifest="${ROOT_DIR}/kubernetes/apps/mysql/_base/innodbcluster.yaml"
    [[ -f "${manifest}" ]] || log error "MySQL manifest not found: ${manifest}"
    local ms_ready desired live desired_node live_node desired_router live_router desired_mysql live_mysql desired_sidecar live_sidecar
    ms_ready="$(kubectl get kustomization -n flux-system mysql-system -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
    [[ "${ms_ready}" == "True" ]] || log error "mysql-system is not Ready; fix/reconcile the mysql-operator chart dependency first"

    desired="$(yq -o=json -I=0 '.' "${manifest}")"
    live="$(kubectl get innodbcluster -n mysql mysql-0 -o json 2>/dev/null || true)"
    [[ -n "${live}" ]] || log error "InnoDBCluster/mysql/mysql-0 not found"

    desired_node="$(jq -cS '.spec.podSpec.nodeSelector // {}' <<<"${desired}")"
    live_node="$(jq -cS '.spec.podSpec.nodeSelector // {}' <<<"${live}")"
    desired_router="$(jq -cS '.spec.router.podSpec.nodeSelector // {}' <<<"${desired}")"
    live_router="$(jq -cS '.spec.router.podSpec.nodeSelector // {}' <<<"${live}")"
    desired_mysql="$(jq -r '.spec.podSpec.containers[]? | select(.name == "mysql") | .resources.requests.memory // ""' <<<"${desired}")"
    live_mysql="$(jq -r '.spec.podSpec.containers[]? | select(.name == "mysql") | .resources.requests.memory // ""' <<<"${live}")"
    desired_sidecar="$(jq -r '.spec.podSpec.containers[]? | select(.name == "sidecar") | .resources.requests.memory // ""' <<<"${desired}")"
    live_sidecar="$(jq -r '.spec.podSpec.containers[]? | select(.name == "sidecar") | .resources.requests.memory // ""' <<<"${live}")"

    [[ "${desired_node}" == "${live_node}" && "${desired_router}" == "${live_router}" ]] ||         log error "MySQL CR nodeSelector differs from Git; reconcile the GitOps commit first"
    [[ "${desired_mysql}" == "${live_mysql}" && "${desired_sidecar}" == "${live_sidecar}" ]] ||         log error "MySQL CR container requests differ from Git (live mysql=${live_mysql:-unset} sidecar=${live_sidecar:-unset}); reconcile the GitOps commit first"
}

preflight() {
    log info "Preflight node=${NODE_NAME} ip=${NODE_IP}"
    kubectl get node "${NODE_NAME}" >/dev/null 2>&1 || log error "Node ${NODE_NAME} not found"

    local n
    local readiness_nodes=("${REQUIRE_ONLINE[@]}")
    if [[ "${EXISTING_OUTAGE}" == false ]]; then
        readiness_nodes+=("${NODE_NAME}")
    fi
    for n in "${readiness_nodes[@]}"; do
        [[ -n "${n}" ]] || continue
        node_ready "${n}" || log error "Node ${n} is not Ready"
    done

    if [[ "${SKIP_PIN_CHECKS}" == false ]]; then
        require_harbor_pins
        require_mysql_matches_git
    else
        log warn "Skipping MySQL/Harbor pin checks"
    fi

    linstor_cmd node list >/dev/null 2>&1 || log error "LINSTOR controller is not reachable"
    local linstor_nodes=("${REQUIRE_ONLINE[@]}")
    if [[ "${EXISTING_OUTAGE}" == false ]]; then
        linstor_nodes+=("${NODE_NAME}")
    fi
    for n in "${linstor_nodes[@]}"; do
        [[ -n "${n}" ]] || continue
        linstor_node_online "${n}" || log error "LINSTOR node ${n} is not Online"
    done

    local resources bad_states no_c01 pvc_map r ns
    resources="$(linstor_cmd resource list | strip_ansi)"
    bad_states="$(awk -F'│' '
        { gsub(/ /, "", $2); gsub(/ /, "", $3); gsub(/ /, "", $7) }
        $3 == "c-01" && $7 != "UpToDate" && $7 != "Diskless" { print $2 " " $7 }
    ' <<<"${resources}")"
    if [[ -n "${bad_states}" ]]; then
        log warn "c-01 LINSTOR resources with non-UpToDate state:"
        printf '%s\n' "${bad_states}"
    fi

    pvc_map="$(kubectl get pvc -A -o json | jq -r '.items[] | [.spec.volumeName, .metadata.namespace] | @tsv')"
    no_c01="$(awk -F'│' '
        { gsub(/ /, "", $2); gsub(/ /, "", $3); gsub(/ /, "", $7) }
        $2 == "" || $2 == "ResourceName" { next }
        $3 == "c-01" && $7 == "UpToDate" { ok[$2] = 1 }
        { res[$2] = 1 }
        END { for (r in res) if (!ok[r]) print r }
    ' <<<"${resources}")"
    for r in ${no_c01}; do
        [[ -n "${r}" ]] || continue
        ns="$(awk -v v="${r}" '$1 == v { print $2; exit }' <<<"${pvc_map}")"
        if [[ -n "${ns}" ]] && in_array "${ns}" "${KEEP_NAMESPACES[@]}"; then
            log error "LINSTOR resource ${r} has no c-01 UpToDate replica but is used by kept namespace ${ns}"
        fi
        log warn "LINSTOR resource has no c-01 UpToDate replica (will be offline on c-02): ${r} namespace=${ns:-unknown}"
    done
}

add_kustomization() {
    local ns="$1" name="$2" suspend
    [[ -n "${name}" ]] || return 0
    local key="${ns}/${name}"
    [[ -n "${KUST_SEEN[${key}]:-}" ]] && return 0
    if ! kubectl get kustomization -n "${ns}" "${name}" >/dev/null 2>&1; then
        log warn "Kustomization not found, skipping: ${key}"
        return 0
    fi
    KUST_SEEN["${key}"]=1
    suspend="$(kubectl get kustomization -n "${ns}" "${name}" -o jsonpath='{.spec.suspend}' 2>/dev/null || true)"
    [[ -z "${suspend}" ]] && suspend=false
    jq -nc --arg ns "${ns}" --arg name "${name}" --argjson suspend "${suspend}" \
        '{namespace:$ns,name:$name,suspend:$suspend}' >>"${STATE_TMP}/kustomizations.ndjson"
    KUSTOMIZATIONS+=("${key}")
}

add_helmrelease() {
    local ns="$1" name="$2" suspend
    [[ -n "${name}" ]] || return 0
    local key="${ns}/${name}"
    [[ -n "${HR_SEEN[${key}]:-}" ]] && return 0
    if ! kubectl get helmrelease -n "${ns}" "${name}" >/dev/null 2>&1; then
        log warn "HelmRelease not found, skipping: ${key}"
        return 0
    fi
    HR_SEEN["${key}"]=1
    suspend="$(kubectl get helmrelease -n "${ns}" "${name}" -o jsonpath='{.spec.suspend}' 2>/dev/null || true)"
    [[ -z "${suspend}" ]] && suspend=false
    jq -nc --arg ns "${ns}" --arg name "${name}" --argjson suspend "${suspend}" \
        '{namespace:$ns,name:$name,suspend:$suspend}' >>"${STATE_TMP}/helmreleases.ndjson"
    HELMRELEASES+=("${key}")
}

collect_state() {
    STATE_TMP="$(mktemp -d)"
    : >"${STATE_TMP}/kustomizations.ndjson"
    : >"${STATE_TMP}/helmreleases.ndjson"
    : >"${STATE_TMP}/workloads.ndjson"
    : >"${STATE_TMP}/daemonsets.ndjson"
    : >"${STATE_TMP}/cronjobs.ndjson"
    : >"${STATE_TMP}/customresources.ndjson"

    local spec ns name target
    for spec in "${SUSPEND_KUSTOMIZATIONS[@]}" "${EXTRA_KUSTOMIZATIONS[@]}"; do
        [[ -n "${spec}" ]] || continue
        if [[ "${spec}" == */* ]]; then
            ns="${spec%%/*}"
            name="${spec#*/}"
        else
            ns="flux-system"
            name="${spec}"
        fi
        add_kustomization "${ns}" "${name}"
    done
    if [[ "$(yq -r '.flux.autoSuspendKustomizationsForNamespaces // true' "${CONFIG}")" == "true" ]]; then
        while IFS=$'\t' read -r name target; do
            [[ -n "${name}" && -n "${target}" ]] || continue
            if in_array "${target}" "${SCALE_NAMESPACES[@]}"; then
                add_kustomization "flux-system" "${name}"
            fi
        done < <(kubectl get kustomizations -n flux-system -o json 2>/dev/null |
            jq -r '.items[] | [.metadata.name, (.spec.targetNamespace // "")] | @tsv' || true)
    fi

    for spec in "${EXTRA_HELMRELEASES[@]}"; do
        [[ -n "${spec}" ]] || continue
        ns="${spec%%/*}"
        name="${spec#*/}"
        add_helmrelease "${ns}" "${name}"
    done
    if [[ "$(yq -r '.flux.suspendHelmReleasesInNamespaces // true' "${CONFIG}")" == "true" ]]; then
        for ns in "${SCALE_NAMESPACES[@]}"; do
            while read -r name; do
                [[ -n "${name}" ]] && add_helmrelease "${ns}" "${name}"
            done < <(kubectl get helmreleases -n "${ns}" -o json 2>/dev/null |
                jq -r '.items[].metadata.name' || true)
        done
    fi

    local kind replicas key
    for ns in "${SCALE_NAMESPACES[@]}"; do
        for kind in Deployment StatefulSet; do
            while IFS=$'\t' read -r name replicas; do
                [[ -n "${name}" ]] || continue
                key="${ns}/${kind}/${name}"
                if in_array "${key}" "${SCALE_EXCLUDE[@]}"; then
                    log info "Keeping excluded workload ${key}"
                    continue
                fi
                jq -nc --arg ns "${ns}" --arg kind "${kind}" --arg name "${name}" \
                    --argjson replicas "${replicas:-1}" \
                    '{namespace:$ns,kind:$kind,name:$name,replicas:$replicas}' >>"${STATE_TMP}/workloads.ndjson"
                WORKLOADS+=("${key}")
            done < <(kubectl get "${kind}" -n "${ns}" -o json 2>/dev/null |
                jq -r '.items[] | [.metadata.name, (.spec.replicas // 1)] | @tsv' || true)
        done
    done

    local node_selector
    for spec in "${STOP_DAEMONSETS[@]}"; do
        [[ -n "${spec}" ]] || continue
        ns="${spec%%/*}"
        name="${spec#*/}"
        if ! kubectl get daemonset -n "${ns}" "${name}" >/dev/null 2>&1; then
            log warn "DaemonSet not found, skipping: ${spec}"
            continue
        fi
        node_selector="$(kubectl get daemonset -n "${ns}" "${name}" -o json 2>/dev/null |
            jq -c '.spec.template.spec.nodeSelector // {}' || true)"
        [[ -z "${node_selector}" ]] && node_selector='{}'
        jq -nc --arg ns "${ns}" --arg name "${name}" --argjson nodeSelector "${node_selector}" \
            '{namespace:$ns,name:$name,nodeSelector:$nodeSelector}' >>"${STATE_TMP}/daemonsets.ndjson"
        DAEMONSETS+=("${spec}")
    done

    local suspend
    for spec in "${SUSPEND_CRONJOBS[@]}"; do
        [[ -n "${spec}" ]] || continue
        ns="${spec%%/*}"
        name="${spec#*/}"
        if ! kubectl get cronjob -n "${ns}" "${name}" >/dev/null 2>&1; then
            log warn "CronJob not found, skipping: ${spec}"
            continue
        fi
        suspend="$(kubectl get cronjob -n "${ns}" "${name}" -o jsonpath='{.spec.suspend}' 2>/dev/null || true)"
        [[ -z "${suspend}" ]] && suspend=false
        jq -nc --arg ns "${ns}" --arg name "${name}" --argjson suspend "${suspend}" \
            '{namespace:$ns,name:$name,suspend:$suspend}' >>"${STATE_TMP}/cronjobs.ndjson"
        CRONJOBS_DONE+=("${spec}")
    done

    local entry api_version kind_cr ns_cr name_cr field value obj
    while IFS= read -r entry; do
        is_yaml_entry "${entry}" || continue
        api_version="$(jq -r '.apiVersion' <<<"${entry}")"
        kind_cr="$(jq -r '.kind' <<<"${entry}")"
        ns_cr="$(jq -r '.namespace' <<<"${entry}")"
        name_cr="$(jq -r '.name' <<<"${entry}")"
        field="$(jq -r '.restoreField' <<<"${entry}")"
        obj="$(kubectl get "${kind_cr}" "${name_cr}" -n "${ns_cr}" -o json 2>/dev/null || true)"
        if [[ -z "${obj}" ]]; then
            log warn "Custom resource not found, skipping: ${api_version} ${kind_cr}/${ns_cr}/${name_cr}"
            continue
        fi
        value="$(jq -c --arg f "${field}" 'getpath($f | split("."))' <<<"${obj}")"
        jq -nc --arg apiVersion "${api_version}" --arg kind "${kind_cr}" \
            --arg ns "${ns_cr}" --arg name "${name_cr}" --arg field "${field}" \
            --argjson value "${value}" \
            '{apiVersion:$apiVersion,kind:$kind,namespace:$ns,name:$name,restoreField:$field,value:$value}' \
            >>"${STATE_TMP}/customresources.ndjson"
        CUSTOM_RESOURCE_KEYS+=("${kind_cr}/${ns_cr}/${name_cr}")
    done < <(yq -o=json -I=0 '.customResources[]?' "${CONFIG_FILES[@]}")
}

write_state() {
    local unschedulable default_state
    unschedulable="$(kubectl get node "${NODE_NAME}" -o jsonpath='{.spec.unschedulable}' 2>/dev/null || true)"
    [[ -z "${unschedulable}" ]] && unschedulable=false

    if [[ -n "${STATE_FILE_OPT}" ]]; then
        STATE_FILE="${STATE_FILE_OPT}"
    else
        default_state="${ROOT_DIR}/tmp/c02-shutdown-state-$(date -u +%Y%m%dT%H%M%SZ).json"
        STATE_FILE="${default_state}"
    fi
    mkdir -p "$(dirname "${STATE_FILE}")"
    [[ -e "${STATE_FILE}" ]] && log error "State file already exists: ${STATE_FILE}"

    jq -n \
        --arg node "${NODE_NAME}" \
        --arg ip "${NODE_IP}" \
        --argjson unschedulable "${unschedulable}" \
        --slurpfile kust <(jq -s . "${STATE_TMP}/kustomizations.ndjson") \
        --slurpfile hr <(jq -s . "${STATE_TMP}/helmreleases.ndjson") \
        --slurpfile workloads <(jq -s . "${STATE_TMP}/workloads.ndjson") \
        --slurpfile daemonsets <(jq -s . "${STATE_TMP}/daemonsets.ndjson") \
        --slurpfile cronjobs <(jq -s . "${STATE_TMP}/cronjobs.ndjson") \
        --slurpfile crs <(jq -s . "${STATE_TMP}/customresources.ndjson") \
        '{
            node: {name: $node, ip: $ip, unschedulable: $unschedulable},
            kustomizations: ($kust[0] // []),
            helmReleases: ($hr[0] // []),
            workloads: ($workloads[0] // []),
            daemonSets: ($daemonsets[0] // []),
            cronJobs: ($cronjobs[0] // []),
            customResources: ($crs[0] // [])
        }' >"${STATE_FILE}"
    chmod 600 "${STATE_FILE}"
}

print_plan() {
    log info "Plan for ${NODE_NAME} (${NODE_IP})"
    log info "Keep namespaces: ${KEEP_NAMESPACES[*]:-none}"
    log info "Scale namespaces: ${SCALE_NAMESPACES[*]:-none}"
    log info "Suspend Kustomizations: ${KUSTOMIZATIONS[*]:-none}"
    log info "Suspend HelmReleases: ${HELMRELEASES[*]:-none}"
    log info "Scale workloads: ${WORKLOADS[*]:-none}"
    log info "Stop DaemonSets: ${DAEMONSETS[*]:-none}"
    log info "Suspend CronJobs: ${CRONJOBS_DONE[*]:-none}"
    log info "Stop custom resources: ${CUSTOM_RESOURCE_KEYS[*]:-none}"
    log info "Pre-drain delete pods: ${PREDRAIN_DELETE_PODS[*]:-none}"
    if [[ "${SKIP_PATCHES}" == true ]]; then
        log info "MySQL live pod template: skipped"
    else
        log info "MySQL live pod template: synced from InnoDBCluster CR (operator podSpec is build-time only)"
    fi
    if [[ "${SKIP_PIN_CHECKS}" == true ]]; then
        log info "Harbor/MySQL amd64 pins: preflight checks skipped"
    else
        log info "Harbor/MySQL amd64 pins: verified in preflight"
    fi
    if [[ "${SKIP_DRAIN}" == false && "${DRAIN}" == "true" ]]; then
        log info "Cordon + drain: yes (force=${DRAIN_FORCE_CFG})"
    else
        log info "Cordon + drain: no"
    fi
    if [[ "${SKIP_DRBD}" == false && "${DRBD_DOWN}" == "true" ]]; then
        log info "drbdadm down all: yes"
    else
        log info "drbdadm down all: no"
    fi
    if [[ "${SKIP_SHUTDOWN}" == false && "${TALOS_SHUTDOWN}" == "true" ]]; then
        log info "talosctl shutdown: yes"
    else
        log info "talosctl shutdown: no"
    fi
}

suspend_flux() {
    local key ns name
    for key in "${KUSTOMIZATIONS[@]}"; do
        ns="${key%%/*}"
        name="${key#*/}"
        log info "Suspending Kustomization ${key}" "namespace=${ns}" "name=${name}"
        kubectl patch kustomization -n "${ns}" "${name}" --type=merge \
            -p '{"spec":{"suspend":true}}' >/dev/null
    done
    for key in "${HELMRELEASES[@]}"; do
        ns="${key%%/*}"
        name="${key#*/}"
        log info "Suspending HelmRelease ${key}" "namespace=${ns}" "name=${name}"
        kubectl patch helmrelease -n "${ns}" "${name}" --type=merge \
            -p '{"spec":{"suspend":true}}' >/dev/null
    done
}

sync_mysql_podspec() {
    local cr node_selector containers router_selector router_resources sts_patch
    cr="$(kubectl get innodbcluster -n mysql mysql-0 -o json)"
    node_selector="$(jq -c '.spec.podSpec.nodeSelector // {}' <<<"${cr}")"
    containers="$(jq -c '[.spec.podSpec.containers[]? | select(.resources != null) | {name, resources}]' <<<"${cr}")"
    router_selector="$(jq -c '.spec.router.podSpec.nodeSelector // {}' <<<"${cr}")"
    router_resources="$(jq -c '.spec.router.podSpec.resources // {}' <<<"${cr}")"

    log info "Syncing MySQL StatefulSet pod template from InnoDBCluster CR"
    sts_patch="$(jq -nc --argjson ns "${node_selector}" --argjson c "${containers}"         '{spec:{template:{spec:{nodeSelector:$ns,containers:$c}}}}')"
    kubectl patch statefulset -n mysql mysql-0 --type=strategic -p "${sts_patch}" >/dev/null

    log info "Syncing MySQL router nodeSelector from InnoDBCluster CR"
    kubectl patch deployment -n mysql mysql-0-router --type=strategic         -p "$(jq -nc --argjson ns "${router_selector}" '{spec:{template:{spec:{nodeSelector:$ns}}}}')" >/dev/null

    if [[ "${router_resources}" != "{}" ]]; then
        log info "Syncing MySQL router resources from InnoDBCluster CR"
        kubectl patch deployment -n mysql mysql-0-router --type=strategic             -p "$(jq -nc --argjson r "${router_resources}"                 '{spec:{template:{spec:{containers:[{name:"router",resources:$r}]}}}}')" >/dev/null
    fi
}

apply_patches() {
    if [[ "${SKIP_PATCHES}" == true ]]; then
        log warn "Skipping patches/MySQL pod template sync"
        return 0
    fi
    local entry kind ns name ptype patch_json desc
    while IFS= read -r entry; do
        is_yaml_entry "${entry}" || continue
        kind="$(jq -r '.kind' <<<"${entry}")"
        ns="$(jq -r '.namespace' <<<"${entry}")"
        name="$(jq -r '.name' <<<"${entry}")"
        ptype="$(jq -r '.patchType // "merge"' <<<"${entry}")"
        patch_json="$(jq -c '.patch' <<<"${entry}")"
        desc="$(jq -r '.description // ""' <<<"${entry}")"
        log info "Patching ${kind}/${ns}/${name}" "type=${ptype}" "description=${desc}"
        kubectl patch "${kind}" "${name}" -n "${ns}" --type="${ptype}" -p "${patch_json}" >/dev/null
    done < <(yq -o=json -I=0 '.patches[]?' "${CONFIG_FILES[@]}")

    sync_mysql_podspec

    local wait_entry wait_kind wait_ns wait_name
    while IFS= read -r wait_entry; do
        is_yaml_entry "${wait_entry}" || continue
        wait_kind="$(jq -r '.kind' <<<"${wait_entry}" | tr '[:upper:]' '[:lower:]')"
        wait_ns="$(jq -r '.namespace' <<<"${wait_entry}")"
        wait_name="$(jq -r '.name' <<<"${wait_entry}")"
        log info "Waiting for rollout ${wait_kind}/${wait_ns}/${wait_name}"
        if ! kubectl rollout status "${wait_kind}/${wait_name}" -n "${wait_ns}" --timeout="${WAIT_TIMEOUT}s"; then
            log error "Rollout did not complete for ${wait_kind}/${wait_ns}/${wait_name}; aborting before shutdown"
        fi
    done < <(yq -o=json -I=0 '.patchesWait[]?' "${CONFIG_FILES[@]}")
}

stop_custom_resources() {
    local entry kind ns name patch_json
    while IFS= read -r entry; do
        is_yaml_entry "${entry}" || continue
        kind="$(jq -r '.kind' <<<"${entry}")"
        ns="$(jq -r '.namespace' <<<"${entry}")"
        name="$(jq -r '.name' <<<"${entry}")"
        patch_json="$(jq -c '.stopPatch' <<<"${entry}")"
        if ! kubectl get "${kind}" "${name}" -n "${ns}" >/dev/null 2>&1; then
            log warn "Custom resource not found, skipping stop: ${kind}/${ns}/${name}"
            continue
        fi
        log info "Stopping ${kind}/${ns}/${name}"
        kubectl patch "${kind}" "${name}" -n "${ns}" --type=merge -p "${patch_json}" >/dev/null
    done < <(yq -o=json -I=0 '.customResources[]?' "${CONFIG_FILES[@]}")
}

wait_for_cr_pods_gone() {
    local deadline=$((SECONDS + CR_WAIT)) entry ns pod_re remaining names
    while :; do
        remaining=0
        names=""
        while IFS= read -r entry; do
            is_yaml_entry "${entry}" || continue
            ns="$(jq -r '.namespace' <<<"${entry}")"
            pod_re="$(jq -r '.pod' <<<"${entry}")"
            local found
            found="$(kubectl get pods -n "${ns}" -o json 2>/dev/null |
                jq -r --arg re "${pod_re}" '.items[] | select(.metadata.name | test($re)) | .metadata.name' || true)"
            if [[ -n "${found}" ]]; then
                remaining=1
                names+=" ${ns}/${found//$'\n'/,}"
            fi
        done < <(yq -o=json -I=0 '.waitForPodsGone[]?' "${CONFIG_FILES[@]}")
        if ((remaining == 0)); then
            return 0
        fi
        if ((SECONDS > deadline)); then
            log warn "Timed out waiting for custom-resource pods to stop:${names}"
            return 0
        fi
        log info "Waiting for custom-resource pods to stop:${names}"
        sleep 5
    done
}

scale_namespaces() {
    local ns kind name replicas key
    for ns in "${SCALE_NAMESPACES[@]}"; do
        [[ -n "${ns}" ]] || continue
        for kind in Deployment StatefulSet; do
            while read -r name replicas; do
                [[ -n "${name}" ]] || continue
                key="${ns}/${kind}/${name}"
                if in_array "${key}" "${SCALE_EXCLUDE[@]}"; then
                    continue
                fi
                log info "Scaling ${key} to 0"
                kubectl scale "${kind}" "${name}" -n "${ns}" --replicas=0 >/dev/null || \
                    log warn "Failed to scale ${key}; continuing"
            done < <(kubectl get "${kind}" -n "${ns}" -o json 2>/dev/null |
                jq -r '.items[] | [.metadata.name, (.spec.replicas // 1)] | @tsv' || true)
        done
    done
}

delete_remaining_scaled_pods() {
    local ns pod owner_kind owner_name key
    for ns in "${SCALE_NAMESPACES[@]}"; do
        [[ -n "${ns}" ]] || continue
        while IFS=$'\t' read -r pod owner_kind owner_name; do
            [[ -n "${pod}" ]] || continue
            [[ "${owner_kind}" == "DaemonSet" ]] && continue
            key="${ns}/${owner_kind}/${owner_name}"
            if in_array "${key}" "${SCALE_EXCLUDE[@]}"; then
                continue
            fi
            log info "Deleting remaining pod ${ns}/${pod} directly (bypasses PDB)"
            kubectl delete pod -n "${ns}" "${pod}" --grace-period=30 --wait=false >/dev/null 2>&1 || true
        done < <(kubectl get pods -n "${ns}" -o json 2>/dev/null |
            jq -r '.items[] | [.metadata.name, (.metadata.ownerReferences[0].kind // ""), (.metadata.ownerReferences[0].name // "")] | @tsv' || true)
    done
}

force_delete_remaining_scaled_pods() {
    local ns pod owner_kind owner_name key
    for ns in "${SCALE_NAMESPACES[@]}"; do
        [[ -n "${ns}" ]] || continue
        while IFS=$'\t' read -r pod owner_kind owner_name; do
            [[ -n "${pod}" ]] || continue
            [[ "${owner_kind}" == "DaemonSet" ]] && continue
            key="${ns}/${owner_kind}/${owner_name}"
            if in_array "${key}" "${SCALE_EXCLUDE[@]}"; then
                continue
            fi
            log warn "Force-deleting remaining pod ${ns}/${pod} (finalizer/PDB bypass)"
            kubectl delete pod -n "${ns}" "${pod}" --force --grace-period=0 --wait=false >/dev/null 2>&1 || true
        done < <(kubectl get pods -n "${ns}" -o json 2>/dev/null |
            jq -r '.items[] | [.metadata.name, (.metadata.ownerReferences[0].kind // ""), (.metadata.ownerReferences[0].name // "")] | @tsv' || true)
    done
}

wait_for_scaled_pods_gone() {
    local deadline=$((SECONDS + SCALED_POD_WAIT)) ns remaining found
    while :; do
        remaining=0
        for ns in "${SCALE_NAMESPACES[@]}"; do
            [[ -n "${ns}" ]] || continue
            found="$(kubectl get pods -n "${ns}" -o json 2>/dev/null |
                jq -r '[.items[] | select((.metadata.ownerReferences[0].kind // "") != "DaemonSet")] | length' || true)"
            [[ "${found}" =~ ^[0-9]+$ ]] || found=0
            ((found > 0)) && remaining=$((remaining + found))
        done
        if ((remaining == 0)); then
            return 0
        fi
        if ((SECONDS > deadline)); then
            log warn "${remaining} pod(s) still present in scaled namespaces"
            return 1
        fi
        log info "Waiting for ${remaining} pod(s) in scaled namespaces to terminate"
        sleep 5
    done
}

verify_scaled_namespaces() {
    local failed=0 ns kind name replicas key pod owner_kind owner_name
    for ns in "${SCALE_NAMESPACES[@]}"; do
        [[ -n "${ns}" ]] || continue
        for kind in Deployment StatefulSet; do
            while IFS=$'\t' read -r name replicas; do
                [[ -n "${name}" ]] || continue
                key="${ns}/${kind}/${name}"
                if in_array "${key}" "${SCALE_EXCLUDE[@]}"; then
                    continue
                fi
                if (( ${replicas:-0} > 0 )); then
                    log warn "Still scaled: ${key} replicas=${replicas}"
                    failed=1
                fi
            done < <(kubectl get "${kind}" -n "${ns}" -o json 2>/dev/null |
                jq -r '.items[] | [.metadata.name, (.spec.replicas // 1)] | @tsv' || true)
        done
        while IFS=$'\t' read -r pod owner_kind owner_name; do
            [[ -n "${pod}" ]] || continue
            [[ "${owner_kind}" == "DaemonSet" ]] && continue
            key="${ns}/${owner_kind}/${owner_name}"
            if in_array "${key}" "${SCALE_EXCLUDE[@]}"; then
                continue
            fi
            log warn "Pod still present in scaled namespace: ${ns}/${pod} owner=${owner_kind}/${owner_name}"
            failed=1
        done < <(kubectl get pods -n "${ns}" -o json 2>/dev/null |
            jq -r '.items[] | [.metadata.name, (.metadata.ownerReferences[0].kind // ""), (.metadata.ownerReferences[0].name // "")] | @tsv' || true)
    done
    if ((failed != 0)); then
        log error "Scaled namespaces are not clean; refusing to continue"
    fi
}

pin_harbor_primary_label() {
    local pod deadline
    pod="$(kubectl -n harbor-system get pods -l 'cnpg.io/cluster=cnpg-harbor,cnpg.io/podRole=instance' -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [[ -z "${pod}" ]]; then
        log warn "Harbor CNPG instance pod not found; cannot pin primary label"
        return 0
    fi
    log info "Pinning Harbor CNPG primary label on ${pod}"
    kubectl -n harbor-system label pod "${pod}" cnpg.io/instanceRole=primary --overwrite >/dev/null
    deadline=$((SECONDS + 60))
    while :; do
        if kubectl -n harbor-system get endpoints cnpg-harbor-rw -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null | grep -q .; then
            log info "Harbor CNPG rw service has an endpoint"
            return 0
        fi
        if ((SECONDS > deadline)); then
            log warn "Harbor CNPG rw service still has no endpoint"
            return 0
        fi
        sleep 5
    done
}

verify_daemonsets_and_cronjobs() {
    local failed=0 spec ns name sentinel suspend
    for spec in "${DAEMONSETS[@]}"; do
        [[ -n "${spec}" ]] || continue
        ns="${spec%%/*}"
        name="${spec#*/}"
        sentinel="$(kubectl get daemonset -n "${ns}" "${name}" -o jsonpath='{.spec.template.spec.nodeSelector.maintenance\.c02-shutdown}' 2>/dev/null || true)"
        if [[ "${sentinel}" != "true" ]]; then
            log warn "DaemonSet not stopped: ${spec}"
            failed=1
        fi
    done
    for spec in "${CRONJOBS_DONE[@]}"; do
        [[ -n "${spec}" ]] || continue
        ns="${spec%%/*}"
        name="${spec#*/}"
        suspend="$(kubectl get cronjob -n "${ns}" "${name}" -o jsonpath='{.spec.suspend}' 2>/dev/null || true)"
        if [[ "${suspend}" != "true" ]]; then
            log warn "CronJob not suspended: ${spec}"
            failed=1
        fi
    done
    if ((failed != 0)); then
        log error "DaemonSet/CronJob verification failed"
    fi
    log info "Verification passed: scaled namespaces, DaemonSets, CronJobs"
}

stop_daemonsets() {
    local spec ns name pod
    for spec in "${DAEMONSETS[@]}"; do
        [[ -n "${spec}" ]] || continue
        ns="${spec%%/*}"
        name="${spec#*/}"
        log info "Stopping DaemonSet ${spec}"
        kubectl patch daemonset -n "${ns}" "${name}" --type=merge \
            -p '{"spec":{"template":{"spec":{"nodeSelector":{"maintenance.c02-shutdown":"true"}}}}}' >/dev/null || \
            log warn "Failed to patch DaemonSet ${spec}"
        while read -r pod; do
            [[ -n "${pod}" ]] || continue
            kubectl delete pod -n "${ns}" "${pod}" --wait=false >/dev/null 2>&1 || true
        done < <(kubectl get pods -n "${ns}" -o json 2>/dev/null |
            jq -r --arg n "${name}" '.items[] | select(any(.metadata.ownerReferences[]?; .kind == "DaemonSet" and .name == $n)) | .metadata.name' || true)
    done
}

suspend_cronjobs() {
    local spec ns name suspend
    for spec in "${CRONJOBS_DONE[@]}"; do
        [[ -n "${spec}" ]] || continue
        ns="${spec%%/*}"
        name="${spec#*/}"
        log info "Suspending CronJob ${spec}"
        kubectl patch cronjob -n "${ns}" "${name}" --type=merge -p '{"spec":{"suspend":true}}' >/dev/null || \
            log warn "Failed to suspend CronJob ${spec}"
    done
}

pre_drain_delete() {
    local spec ns name node ready deadline
    for spec in "${PREDRAIN_DELETE_PODS[@]}"; do
        [[ -n "${spec}" ]] || continue
        ns="${spec%%/*}"
        name="${spec#*/}"
        node="$(kubectl get pod -n "${ns}" "${name}" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
        if [[ -z "${node}" ]]; then
            log info "Pod ${ns}/${name} not found, skipping pre-drain delete"
            continue
        fi
        if [[ "${node}" != "${NODE_NAME}" ]]; then
            log info "Pod ${ns}/${name} already on ${node}, skipping pre-drain delete"
            continue
        fi
        log info "Moving ${ns}/${name} off ${NODE_NAME} before drain"
        kubectl delete pod -n "${ns}" "${name}" --wait=true --timeout="${WAIT_TIMEOUT}s" >/dev/null
        deadline=$((SECONDS + WAIT_TIMEOUT))
        while :; do
            node="$(kubectl get pod -n "${ns}" "${name}" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
            ready="$(kubectl get pod -n "${ns}" "${name}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
            if [[ -n "${node}" && "${node}" != "${NODE_NAME}" && "${ready}" == "True" ]]; then
                log info "Pod ${ns}/${name} is Ready on ${node}"
                break
            fi
            if ((SECONDS > deadline)); then
                log error "Pod ${ns}/${name} did not become Ready off ${NODE_NAME}; aborting before drain"
            fi
            sleep 5
        done
    done
}

drain_node() {
    local args=(--ignore-daemonsets --delete-emptydir-data --force --timeout="${WAIT_TIMEOUT}s")
    if [[ "${DRAIN_FORCE_CFG}" == "true" ]]; then
        args+=(--disable-eviction)
    fi
    log info "Draining ${NODE_NAME}" "args=${args[*]}"
    if ! kubectl drain "${NODE_NAME}" "${args[@]}"; then
        log warn "Drain failed; PDBs:"
        kubectl get pdb -A || true
        log warn "Pods still on ${NODE_NAME}:"
        kubectl get pods -A --field-selector "spec.nodeName=${NODE_NAME}" -o wide || true
        log error "Aborting before drbdadm down/shutdown; the node remains cordoned"
    fi
}

wait_for_non_daemonset_pods() {
    local deadline=$((SECONDS + WAIT_TIMEOUT)) remaining
    while :; do
        remaining="$(kubectl get pods -A --field-selector "spec.nodeName=${NODE_NAME}" -o json 2>/dev/null |
            jq -r '[.items[] | select((.metadata.ownerReferences[0].kind // "") != "DaemonSet") | select(.status.phase != "Succeeded" and .status.phase != "Failed")] | length' || true)"
        if [[ "${remaining}" == "0" ]]; then
            return 0
        fi
        if ((SECONDS > deadline)); then
            log warn "Non-DaemonSet pods still on ${NODE_NAME}:"
            kubectl get pods -A --field-selector "spec.nodeName=${NODE_NAME}" -o wide || true
            log error "Aborting before drbdadm down/shutdown"
        fi
        log info "Waiting for ${remaining} non-DaemonSet pod(s) to leave ${NODE_NAME}"
        sleep 5
    done
}

find_satellite() {
    kubectl -n piraeus-datastore get pods -l app.kubernetes.io/component=linstor-satellite -o json 2>/dev/null |
        jq -r --arg n "${NODE_NAME}" '.items[] | select(.spec.nodeName == $n and .status.phase == "Running") | .metadata.name' |
        head -n1
}

drbd_down() {
    local sat
    sat="$(find_satellite)"
    if [[ -z "${sat}" ]]; then
        log error "LINSTOR satellite pod for ${NODE_NAME} not found"
    fi
    log info "Running drbdadm down all in ${sat}"
    if ! kubectl -n piraeus-datastore exec "${sat}" -c linstor-satellite -- drbdadm down all; then
        log warn "drbdadm down all failed; checking host mounts"
        talosctl --nodes "${NODE_IP}" read /proc/mounts 2>/dev/null | grep -i drbd || true
        log error "Aborting before shutdown; c-02 remains cordoned"
    fi
    log info "drbdadm status after down:"
    kubectl -n piraeus-datastore exec "${sat}" -c linstor-satellite -- drbdadm status 2>/dev/null || true
}

shutdown_node() {
    local deadline=$((SECONDS + POST_SHUTDOWN_WAIT)) ready
    log info "Shutting down ${NODE_NAME} (${NODE_IP})"
    talosctl --nodes "${NODE_IP}" shutdown --force --wait=false
    while :; do
        ready="$(kubectl get node "${NODE_NAME}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
        if [[ "${ready}" != "True" ]]; then
            log info "Node ${NODE_NAME} is no longer Ready"
            break
        fi
        if ((SECONDS > deadline)); then
            log warn "Node ${NODE_NAME} is still Ready after shutdown request; check talosctl/power state"
            break
        fi
        sleep 5
    done
}

restore_from_state() {
    if [[ -z "${STATE_FILE_OPT}" ]]; then
        STATE_FILE="$(ls -1t "${ROOT_DIR}"/tmp/c02-shutdown-state-*.json 2>/dev/null | head -n1 || true)"
        [[ -n "${STATE_FILE}" ]] || log error "No state file found; pass --state-file"
    else
        STATE_FILE="${STATE_FILE_OPT}"
    fi
    [[ -f "${STATE_FILE}" ]] || log error "State file not found: ${STATE_FILE}"
    jq -e . "${STATE_FILE}" >/dev/null 2>&1 || log error "Invalid state file: ${STATE_FILE}"

    log info "Restoring from ${STATE_FILE}"
    wait_for_node_ready "${NODE_NAME}" || log error "Node ${NODE_NAME} is not Ready; power it on first"
    if ! wait_for_linstor_online "${NODE_NAME}"; then
        log error "LINSTOR node ${NODE_NAME} is not Online; refusing to uncordon"
    fi

    if [[ "$(jq -r '.node.unschedulable // false' "${STATE_FILE}")" == "false" ]]; then
        log info "Uncordoning ${NODE_NAME}"
        kubectl uncordon "${NODE_NAME}" >/dev/null
    else
        log info "${NODE_NAME} was cordoned before shutdown; leaving it cordoned"
    fi

    local cr kind ns name field value patch_json
    while IFS= read -r cr; do
        [[ -n "${cr}" ]] || continue
        kind="$(jq -r '.kind' <<<"${cr}")"
        ns="$(jq -r '.namespace' <<<"${cr}")"
        name="$(jq -r '.name' <<<"${cr}")"
        field="$(jq -r '.restoreField' <<<"${cr}")"
        value="$(jq -c '.value' <<<"${cr}")"
        if [[ "${value}" == "null" ]]; then
            log warn "No saved value for ${kind}/${ns}/${name} ${field}; skipping"
            continue
        fi
        patch_json="$(jq -nc --arg f "${field}" --argjson v "${value}" \
            'reduce ($f | split(".") | reverse[]) as $k ($v; {($k): .})')"
        log info "Restoring ${kind}/${ns}/${name} ${field}=${value}"
        kubectl patch "${kind}" "${name}" -n "${ns}" --type=merge -p "${patch_json}" >/dev/null || \
            log warn "Failed to restore ${kind}/${ns}/${name}"
    done < <(jq -c '.customResources[]?' "${STATE_FILE}")

    local ds sel pod
    while IFS= read -r ds; do
        [[ -n "${ds}" ]] || continue
        ns="$(jq -r '.namespace' <<<"${ds}")"
        name="$(jq -r '.name' <<<"${ds}")"
        sel="$(jq -c '.nodeSelector' <<<"${ds}")"
        log info "Restoring DaemonSet ${ns}/${name} nodeSelector=${sel}"
        kubectl patch daemonset -n "${ns}" "${name}" --type=json \
            -p '[{"op":"remove","path":"/spec/template/spec/nodeSelector"}]' >/dev/null 2>&1 || true
        if [[ "${sel}" != "{}" ]]; then
            kubectl patch daemonset -n "${ns}" "${name}" --type=merge \
                -p "{\"spec\":{\"template\":{\"spec\":{\"nodeSelector\":${sel}}}}}" >/dev/null || \
                log warn "Failed to restore nodeSelector on ${ns}/${name}"
        fi
        while read -r pod; do
            [[ -n "${pod}" ]] || continue
            kubectl delete pod -n "${ns}" "${pod}" --wait=false >/dev/null 2>&1 || true
        done < <(kubectl get pods -n "${ns}" -o json 2>/dev/null |
            jq -r --arg n "${name}" '.items[] | select(any(.metadata.ownerReferences[]?; .kind == "DaemonSet" and .name == $n)) | .metadata.name' || true)
    done < <(jq -c '.daemonSets[]?' "${STATE_FILE}")

    local wl replicas
    while IFS= read -r wl; do
        [[ -n "${wl}" ]] || continue
        kind="$(jq -r '.kind' <<<"${wl}")"
        ns="$(jq -r '.namespace' <<<"${wl}")"
        name="$(jq -r '.name' <<<"${wl}")"
        replicas="$(jq -r '.replicas' <<<"${wl}")"
        log info "Restoring ${kind}/${ns}/${name} replicas=${replicas}"
        kubectl scale "${kind}" "${name}" -n "${ns}" --replicas="${replicas}" >/dev/null || \
            log warn "Failed to restore ${kind}/${ns}/${name}"
    done < <(jq -c '.workloads[]?' "${STATE_FILE}")

    local cj suspend
    while IFS= read -r cj; do
        [[ -n "${cj}" ]] || continue
        ns="$(jq -r '.namespace' <<<"${cj}")"
        name="$(jq -r '.name' <<<"${cj}")"
        suspend="$(jq -r '.suspend' <<<"${cj}")"
        log info "Restoring CronJob ${ns}/${name} suspend=${suspend}"
        kubectl patch cronjob -n "${ns}" "${name}" --type=merge \
            -p "{\"spec\":{\"suspend\":${suspend}}}" >/dev/null || \
            log warn "Failed to restore CronJob ${ns}/${name}"
    done < <(jq -c '.cronJobs[]?' "${STATE_FILE}")

    local hr ns_hr name_hr suspend_hr
    while IFS=$'\t' read -r ns_hr name_hr suspend_hr; do
        [[ -n "${name_hr}" ]] || continue
        log info "Unsuspending HelmRelease ${ns_hr}/${name_hr} suspend=${suspend_hr}"
        kubectl patch helmrelease -n "${ns_hr}" "${name_hr}" --type=merge \
            -p "{\"spec\":{\"suspend\":${suspend_hr}}}" >/dev/null || \
            log warn "Failed to restore HelmRelease ${ns_hr}/${name_hr}"
    done < <(jq -r '.helmReleases | reverse[] | [.namespace, .name, .suspend] | @tsv' "${STATE_FILE}")

    local k ns_k name_k suspend_k
    while IFS=$'\t' read -r ns_k name_k suspend_k; do
        [[ -n "${name_k}" ]] || continue
        log info "Unsuspending Kustomization ${ns_k}/${name_k} suspend=${suspend_k}"
        kubectl patch kustomization -n "${ns_k}" "${name_k}" --type=merge \
            -p "{\"spec\":{\"suspend\":${suspend_k}}}" >/dev/null || \
            log warn "Failed to restore Kustomization ${ns_k}/${name_k}"
    done < <(jq -r '.kustomizations | reverse[] | [.namespace, .name, .suspend] | @tsv' "${STATE_FILE}")

    while IFS=$'\t' read -r ns_k name_k; do
        [[ -n "${name_k}" ]] || continue
        kubectl annotate --overwrite kustomization -n "${ns_k}" "${name_k}" \
            reconcile.fluxcd.io/requestedAt="$(date +%s)" >/dev/null 2>&1 || true
    done < <(jq -r '.kustomizations[] | [.namespace, .name] | @tsv' "${STATE_FILE}")
    while IFS=$'\t' read -r ns_hr name_hr; do
        [[ -n "${name_hr}" ]] || continue
        kubectl annotate --overwrite helmrelease -n "${ns_hr}" "${name_hr}" \
            reconcile.fluxcd.io/requestedAt="$(date +%s)" >/dev/null 2>&1 || true
    done < <(jq -r '.helmReleases[] | [.namespace, .name] | @tsv' "${STATE_FILE}")

    log info "Restore requested. Watch Flux, LINSTOR resync, MySQL and Harbor."
    log info "State file: ${STATE_FILE}"
}

if [[ "${RESTORE}" == true ]]; then
    restore_from_state
    exit 0
fi

preflight
collect_state
print_plan

if [[ "${WRITE_STATE_ONLY}" == true ]]; then
    write_state
    log info "State file written without changes: ${STATE_FILE}"
    exit 0
fi

if [[ "${APPLY}" == false ]]; then
    log info "Dry-run only. Re-run with --apply to execute."
    exit 0
fi

if [[ "${YES}" == false ]]; then
    printf 'Type %s to continue: ' "${NODE_NAME}"
    read -r answer
    [[ "${answer}" == "${NODE_NAME}" ]] || log error "Aborted"
fi

write_state
trap 'rc=$?; if [[ $rc -ne 0 ]]; then echo "FAILED (rc=$rc). State file: ${STATE_FILE:-<none>}" >&2; fi; cleanup' EXIT
log info "State file written: ${STATE_FILE}"

suspend_flux
apply_patches
stop_custom_resources
wait_for_cr_pods_gone

# Cordon and move kept PDB-protected pods before stopping the CNPG operator.
# Harbor's CNPG pod must be recreated on c-01 while the operator is still
# running; after that the operator is scaled down with cnpg-system.
if [[ "${SKIP_DRAIN}" == false && "${DRAIN}" == "true" ]]; then
    log info "Cordoning ${NODE_NAME}"
    kubectl cordon "${NODE_NAME}" >/dev/null
    pre_drain_delete
fi

scale_namespaces
delete_remaining_scaled_pods
if ! wait_for_scaled_pods_gone; then
    force_delete_remaining_scaled_pods
    wait_for_scaled_pods_gone || log error "Pods remain in scaled namespaces after force delete; aborting"
fi
verify_scaled_namespaces
pin_harbor_primary_label
stop_daemonsets
suspend_cronjobs
verify_daemonsets_and_cronjobs

if [[ "${SKIP_DRAIN}" == false && "${DRAIN}" == "true" ]]; then
    drain_node
    wait_for_non_daemonset_pods
    log info "Pending pods after drain (review before shutting down):"
    kubectl get pods -A --field-selector status.phase=Pending -o wide || true
else
    log info "Skipping drain"
fi

if [[ "${SKIP_DRBD}" == false && "${DRBD_DOWN}" == "true" ]]; then
    drbd_down
else
    log info "Skipping drbdadm down"
fi

if [[ "${SKIP_SHUTDOWN}" == false && "${TALOS_SHUTDOWN}" == "true" ]]; then
    shutdown_node
else
    log info "Skipping talosctl shutdown"
fi

log info "Done. State file: ${STATE_FILE}"
log warn "Do not reboot or drain c-01/rpi-00 while c-02 is down; LINSTOR quorum relies on the rpi-00 tiebreaker."
log info "After powering c-02 back on: ./scripts/c02-shutdown.sh --restore --state-file ${STATE_FILE}"
