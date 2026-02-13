# Home Ops

## Projects & Links

- Personal site (maintenance mode): https://jan.buijnsters.com/

## Highlights

- GitOps-driven Kubernetes cluster management with Flux and Helm releases
- SOPS + age encryption for secrets in Git
- Talos-based cluster configuration and lifecycle management
- Automated bootstrap workflow for infra and applications

## Tech Stack

- Kubernetes + Talos Linux
- Flux CD (GitOps)
- Cilium
- Piraeus Datastore (LINSTOR)
- SOPS + age
- Velero
- cert-manager
- Renovate + GitHub Actions

## Overview

This repository manages my personal homelab using a GitOps workflow. It captures infrastructure, platform services, and applications as declarative Kubernetes manifests, with Talos handling the cluster lifecycle. Changes are made in Git and reconciled automatically into the running cluster.

## Repository Layout

- `bootstrap/`: Helmfile-based bootstrap and initial infrastructure
- `kubernetes/`: Apps, infra, clusters, and reusable components
- `talos/`: Talos configuration, patches, and secrets
- `scripts/`: Bootstrap helpers
- `toolkit/`: Utility manifests for operational tasks

## GitOps Workflow (Short)

1. Declarative changes land in Git under `kubernetes/` and `talos/`.
2. Flux reconciles the cluster to match the repository state.
3. Secrets are encrypted in Git and decrypted in-cluster with SOPS.

## Operations Notes

- `task bootstrap:talos`: Initialize the Talos cluster
- `task bootstrap:apps`: Install core infrastructure and apps
- `task reconcile`: Force Flux to reconcile

## Secrets Management

Secrets are stored as SOPS-encrypted manifests in Git and decrypted in-cluster using age keys.

## Credits

- Originally forked from the onedr0p home-ops/cluster-template ecosystem.
