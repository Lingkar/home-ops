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

    # Kube-system
    local -r secrets_kube=(
        "${ROOT_DIR}/kubernetes/infra/kube-system/external-snapshotter/_base/s3-credentials.sops.yaml"
    )

    for secret in "${secrets_kube[@]}"; do
        if [ ! -f "${secret}" ]; then
            log warn "File does not exist" "file=${secret}"
            continue
        fi

        # Check if the secret resources are up-to-date
        if sops exec-file "${secret}" "kubectl --namespace kube-system diff --filename {}" &>/dev/null; then
            log info "Secret resource is up-to-date" "resource=$(basename "${secret}" ".sops.yaml")"
            continue
        fi

        # Apply secret resources
        if sops exec-file "${secret}" "kubectl --namespace kube-system apply --server-side --filename {}" &>/dev/null; then
            log info "Secret resource applied successfully" "resource=$(basename "${secret}" ".sops.yaml")"
        else
            log error "Failed to apply secret resource" "resource=$(basename "${secret}" ".sops.yaml")"
        fi
    done

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

# CRDs to be applied before the helmfile charts are installed
function apply_crds() {
    log debug "Applying CRDs"

    # external-snapshotter
    kubectl kustomize https://github.com/kubernetes-csi/external-snapshotter/client/config/crd | kubectl apply -f -

    local -r helmfile_file="${ROOT_DIR}/bootstrap/helmfile.d/00-crds.yaml"

    if [[ ! -f "${helmfile_file}" ]]; then
        log fatal "File does not exist" "file" "${helmfile_file}"
    fi

    if ! crds=$(helmfile --file "${helmfile_file}" template --quiet) || [[ -z "${crds}" ]]; then
        log fatal "Failed to render CRDs from Helmfile" "file" "${helmfile_file}"
    fi

    if echo "${crds}" | kubectl diff --filename - &>/dev/null; then
        log info "CRDs are up-to-date"
        return
    fi

    if ! echo "${crds}" | kubectl apply --server-side --filename - &>/dev/null; then
        log fatal "Failed to apply crds from Helmfile" "file" "${helmfile_file}"
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

    if ! helmfile --file "${helmfile_file}" sync --hide-notes; then
        log error "Failed to sync Helm releases"
    fi

    log info "Init infra synced successfully"
}

function main() {
    check_env KUBECONFIG TALOSCONFIG
    check_cli helmfile kubectl kustomize sops talhelper yq

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
