#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${0}")/lib/common.sh"

export LOG_LEVEL="debug"
export ROOT_DIR="$(git rev-parse --show-toplevel)"

# Talos requires the nodes to be 'Ready=False' before applying resources
function wait_for_nodes() {
    log debug "Waiting for nodes to be available"

    # Skip waiting if all nodes are 'Ready=True'
    if kubectl wait nodes --for=condition=Ready=True --all --timeout=10s &>/dev/null; then
        log info "Nodes are available and ready, skipping wait for nodes"
        return
    fi

    # Wait for all nodes to be 'Ready=False'
    until kubectl wait nodes --for=condition=Ready=False --all --timeout=10s &>/dev/null; do
        log info "Nodes are not available, waiting for nodes to be available. Retrying in 10 seconds..."
        sleep 10
    done
}

# SOPS secrets to be applied before the helmfile charts are installed
function apply_sops_secrets() {
    log debug "Applying secrets"

    # Flux-system
    kubectl get ns | grep -q "^flux-system" || kubectl create namespace flux-system

    local -r secrets_flux=(
        "${ROOT_DIR}/bootstrap/github-deploy-key.sops.yaml"
        "${ROOT_DIR}/kubernetes/components/common/sops/cluster-secrets.sops.yaml"
        "${ROOT_DIR}/kubernetes/infra/flux-system/flux-instance/_base/sops-age.sops.yaml"
    )

    for secret in "${secrets_flux[@]}"; do
        if [ ! -f "${secret}" ]; then
            log warn "File does not exist" "file=${secret}"
            continue
        fi

        # Check if the secret resources are up-to-date
        if sops exec-file "${secret}" "kubectl --namespace flux-system diff --filename {}" &>/dev/null; then
            log info "Secret resource is up-to-date" "resource=$(basename "${secret}" ".sops.yaml")"
            continue
        fi

        # Apply secret resources
        if sops exec-file "${secret}" "kubectl --namespace flux-system apply --server-side --filename {}" &>/dev/null; then
            log info "Secret resource applied successfully" "resource=$(basename "${secret}" ".sops.yaml")"
        else
            log error "Failed to apply secret resource" "resource=$(basename "${secret}" ".sops.yaml")"
        fi
    done

    # Velero
    kubectl get ns | grep -q "^velero" || kubectl create namespace velero

    local -r secrets_velero=(
        "${ROOT_DIR}/kubernetes/infra/velero/_base/s3-credentials.sops.yaml"
    )

    for secret in "${secrets_velero[@]}"; do
        if [ ! -f "${secret}" ]; then
            log warn "File does not exist" "file=${secret}"
            continue
        fi

        # Check if the secret resources are up-to-date
        if sops exec-file "${secret}" "kubectl --namespace velero diff --filename {}" &>/dev/null; then
            log info "Secret resource is up-to-date" "resource=$(basename "${secret}" ".sops.yaml")"
            continue
        fi

        # Apply secret resources
        if sops exec-file "${secret}" "kubectl --namespace velero apply --server-side --filename {}" &>/dev/null; then
            log info "Secret resource applied successfully" "resource=$(basename "${secret}" ".sops.yaml")"
        else
            log error "Failed to apply secret resource" "resource=$(basename "${secret}" ".sops.yaml")"
        fi
    done

    # Piraeus-datastore
    kubectl get ns | grep -q "^piraeus-datastore" || kubectl create namespace piraeus-datastore

    local -r secrets_pireaus=(
        "${ROOT_DIR}/kubernetes/infra/piraeus-datastore/piraeus-datastore/_base/passphrase.sops.yaml"
    )

    for secret in "${secrets_pireaus[@]}"; do
        if [ ! -f "${secret}" ]; then
            log warn "File does not exist" "file=${secret}"
            continue
        fi

        # Check if the secret resources are up-to-date
        if sops exec-file "${secret}" "kubectl --namespace piraeus-datastore diff --filename {}" &>/dev/null; then
            log info "Secret resource is up-to-date" "resource=$(basename "${secret}" ".sops.yaml")"
            continue
        fi

        # Apply secret resources
        if sops exec-file "${secret}" "kubectl --namespace piraeus-datastore apply --server-side --filename {}" &>/dev/null; then
            log info "Secret resource applied successfully" "resource=$(basename "${secret}" ".sops.yaml")"
        else
            log error "Failed to apply secret resource" "resource=$(basename "${secret}" ".sops.yaml")"
        fi
    done

    local -r manifests_pireaus=(
        "${ROOT_DIR}/kubernetes/infra/piraeus-datastore/piraeus-datastore/_base/volumesnapshotclass.yaml"
        "${ROOT_DIR}/kubernetes/infra/piraeus-datastore/piraeus-datastore/_base/storageclass.yaml"
    )

    for manifest in "${manifests_pireaus[@]}"; do
        if [ ! -f "${manifest}" ]; then
            log warn "File does not exist" "file=${manifest}"
            continue
        fi

        # Check if the manifest resources are up-to-date
        if kubectl --namespace piraeus-datastore diff -f $manifest &>/dev/null; then
            log info "manifest resource is up-to-date" "resource=$(basename "${manifest}" ".yaml")"
            continue
        fi

        # Apply manifest resources
        if kubectl --namespace piraeus-datastore apply --server-side -f $manifest &>/dev/null; then
            log info "manifest resource applied successfully" "resource=$(basename "${manifest}" ".yaml")"
        else
            log error "Failed to apply manifest resource" "resource=$(basename "${manifest}" ".yaml")"
        fi
    done
}

function confirm_action() {
    local -r prompt="$1"
    local response

    read -r -p "${prompt} [y/N] " response </dev/tty || true

    case "${response}" in
    [yY] | [yY][eE][sS])
        return 0
        ;;
    *)
        return 1
        ;;
    esac
}

function any_crd_exists() {
    local crd_names=("${@}")

    for crd_name in "${crd_names[@]}"; do
        if kubectl get crd "${crd_name}" &>/dev/null; then
            return 0
        fi
    done

    return 1
}

function confirm_sync_if_releases_exist() {
    local -r helmfile_file="$1"
    local releases

    if ! releases=$(helmfile --file "${helmfile_file}" list --output json | yq eval -r '.[] | (.name + "|" + (.namespace // "default"))' -); then
        log error "Failed to list Helm releases from Helmfile" "file=${helmfile_file}"
    fi

    if [[ -z "${releases}" ]]; then
        return 0
    fi

    local installed
    if ! installed=$(helm list --all-namespaces --output json | yq eval -r '.[] | (.name + "|" + .namespace)' -); then
        log error "Failed to list installed Helm releases"
    fi

    local existing=()
    while IFS= read -r release; do
        if [[ -n "${release}" ]] && grep -Fxq "${release}" <<<"${installed}"; then
            existing+=("${release}")
        fi
    done <<<"${releases}"

    if [[ ${#existing[@]} -eq 0 ]]; then
        return 0
    fi

    local existing_list
    existing_list=$(
        IFS=","
        echo "${existing[*]}"
    )

    log warn "Detected existing Helm releases from Helmfile" "releases=${existing_list}"

    if ! confirm_action "Helm releases already exist. Continue syncing ${helmfile_file}?"; then
        log warn "Skipping Helm sync" "file=${helmfile_file}"
        return 1
    fi

    return 0
}

# CRDs to be applied before the helmfile charts are installed
function apply_crds() {
    log debug "Applying CRDs"

    # external-snapshotter
    local snapshotter_crds
    if ! snapshotter_crds=$(kubectl kustomize https://github.com/kubernetes-csi/external-snapshotter/client/config/crd); then
        log fatal "Failed to render external-snapshotter CRDs"
    fi

    mapfile -t snapshotter_crd_names < <(echo "${snapshotter_crds}" | yq eval -r 'select(.kind == "CustomResourceDefinition") | .metadata.name' -)
    local snapshotter_diff
    snapshotter_diff=$(echo "${snapshotter_crds}" | kubectl diff --filename - || true)

    if [[ -z "${snapshotter_diff}" ]]; then
        log info "External-snapshotter CRDs are up-to-date"
    elif any_crd_exists "${snapshotter_crd_names[@]}"; then
        log warn "External-snapshotter CRDs differ from cluster"
        printf "%s\n" "${snapshotter_diff}"

        if confirm_action "Apply external-snapshotter CRD changes?"; then
            if ! echo "${snapshotter_crds}" | kubectl apply --server-side --filename - &>/dev/null; then
                log fatal "Failed to apply external-snapshotter CRDs"
            fi
        else
            log warn "Skipping external-snapshotter CRD apply"
        fi
    else
        if ! echo "${snapshotter_crds}" | kubectl apply --server-side --filename - &>/dev/null; then
            log fatal "Failed to apply external-snapshotter CRDs"
        fi
    fi

    local -r helmfile_file="${ROOT_DIR}/bootstrap/helmfile.d/00-crds.yaml"

    if [[ ! -f "${helmfile_file}" ]]; then
        log fatal "File does not exist" "file" "${helmfile_file}"
    fi

    if ! crds=$(helmfile --file "${helmfile_file}" template --quiet | yq eval-all --exit-status 'select(.kind == "CustomResourceDefinition")') || [[ -z "${crds}" ]]; then
        log fatal "Failed to render CRDs from Helmfile" "file" "${helmfile_file}"
        exit 1
    fi

    mapfile -t crd_names < <(echo "${crds}" | yq eval -r 'select(.kind == "CustomResourceDefinition") | .metadata.name' -)
    local crd_diff
    crd_diff=$(echo "${crds}" | kubectl diff --filename - || true)

    if [[ -z "${crd_diff}" ]]; then
        log info "CRDs are up-to-date"
        return
    fi

    if any_crd_exists "${crd_names[@]}"; then
        log warn "CRDs differ from cluster"
        printf "%s\n" "${crd_diff}"

        if ! confirm_action "Apply CRD changes from Helmfile?"; then
            log warn "Skipping Helmfile CRD apply" "file=${helmfile_file}"
            return
        fi
    fi

    if ! echo "${crds}" | kubectl apply --server-side=true --filename - &>/dev/null; then
        log fatal "Failed to apply crds from Helmfile" "file" "${helmfile_file}"
        exit 1
    fi

    log info "CRDs applied successfully"
}

# Sync Helm releases
function sync_init_infra() {
    log debug "Syncing init infra"

    local -r helmfile_file="${ROOT_DIR}/bootstrap/helmfile.d/01-init-infra.yaml"

    if [[ ! -f "${helmfile_file}" ]]; then
        log error "File does not exist" "file=${helmfile_file}"
    fi

    if ! confirm_sync_if_releases_exist "${helmfile_file}"; then
        return
    fi

    if ! helmfile --file "${helmfile_file}" sync --hide-notes; then
        log error "Failed to sync Helm releases"
    fi

    log info "Init infra synced successfully"
}

function sync_gitops_infra() {
    log debug "Syncing gitops infra"

    local -r helmfile_file="${ROOT_DIR}/bootstrap/helmfile.d/02-gitops-infra.yaml"

    if [[ ! -f "${helmfile_file}" ]]; then
        log error "File does not exist" "file=${helmfile_file}"
    fi

    if ! confirm_sync_if_releases_exist "${helmfile_file}"; then
        return
    fi

    if ! helmfile --file "${helmfile_file}" sync --hide-notes; then
        log error "Failed to sync Helm releases"
    fi

    log info "Init infra synced successfully"
}

function main() {
    check_env KUBECONFIG TALOSCONFIG
    check_cli helm helmfile kubectl kustomize sops talhelper yq

    # Apply resources and Helm releases
    wait_for_nodes

    apply_crds
    apply_sops_secrets

    sync_init_infra
    # TODO:: Create custom Velero logic for restoring of last backup!

    sync_gitops_infra

    log info "Congrats! The cluster is bootstrapped and Flux is syncing the Git repository"
}

main "$@"
