# AGENTS.md

GitOps homelab: Kubernetes (Talos Linux) + Flux CD. `main` branch is live; Flux reconciles the running cluster from this repo.

## Critical environment setup

- **All CLI tools come from `mise`** (`.mise.toml` pins exact versions of task, flux, sops, age, talhelper, talosctl, helm, helmfile, kubectl, kustomize, kubeconform, yq, jq, cilium-cli, pre-commit). Run `mise` before using tools; do not assume system-installed versions.
- **Credentials/keys live OUTSIDE this repo**, in the sibling directory `../home-ops-secrets/` (`age.key`, `kubeconfig`, `talos` dir only `talosconfig`). `KUBECONFIG`, `SOPS_AGE_KEY_FILE`, `TALOSCONFIG` env vars point there (set by `.mise.toml`). Anything needing cluster access or SOPS decryption silently fails without this dir.
- The empty `kubeconfig/` directory in the repo root is **not** used; the real kubeconfig comes from the sibling dir.

## Command runner

`task` (go-task). Run `task --list`. Key tasks:
- `task reconcile` — force Flux to pull changes (precondition: flux-cli + kubeconfig).
- `task talos:generate-config`, `task talos:apply-node IP=…`, `task talos:upgrade-node IP=…`, `task talos:upgrade-k8s`, `task talos:reset`.
- `task bootstrap:talos` / `task bootstrap:apps` — bootstrap only, not for day-to-day.

## How manifests are wired

- Flux-instance syncs path `kubernetes/clusters/home` from the `main` branch GitRepository.
- `kubernetes/clusters/home/artifacts.yaml` defines an **ArtifactGenerator** producing two ExternalArtifacts: `infra` (copies `kubernetes/infra/**` + `kubernetes/components/**`) and `apps` (copies `kubernetes/apps/**` + `kubernetes/components/**` + `kubernetes/utils/**`).
- `kubernetes/clusters/home/ks.yaml` contains the two root Kustomizations (`infra`, `apps`) that point at `./kubernetes/clusters/home/{infra,apps}`.
- Each app/component gets **two things**: a Flux `Kustomization` object in `kubernetes/clusters/home/{apps,infra}/<name>.yaml` (path `./<name>/_base`, component `../../components/common` or `../../../components/common` for infra, `sourceRef: ExternalArtifact {apps,infra}`, `targetNamespace`) plus the manifests themselves in `kubernetes/{apps,infra}/<name>/_base/`.
- To add an app: create `kubernetes/apps/<name>/_base/kustomization.yaml` + manifests, create `kubernetes/clusters/home/apps/<name>.yaml`, and add it to `kubernetes/clusters/home/apps/kustomization.yaml`.
- `kubernetes/components/common` is a shared kustomize Component (creates Namespace, HelmRepositories, cluster-secrets). It currently has netpol commented out.
- Common component pattern: `configMapGenerator` produces `values-<name>` ConfigMaps carrying `values.yaml`; HelmReleases consume them via `valuesFrom`; `kubernetes/utils/helm/kustomizeconfig.yaml` wires name references.
- `${SECRET_DOMAIN}` is a placeholder substituted by Flux via `postBuild.substituteFrom` of the `cluster-secrets` secret. Use it in hostnames (e.g. `ntfy.${SECRET_DOMAIN}`) — never hardcode the domain (currently `buijnsters.com`).

## Secrets: SOPS + age

- Encrypted files end in `.sops.yaml` (rules in `.sops.yaml`: talos files fully encrypted; kubernetes/bootstrap files encrypt only `data|stringData|spec`). Never commit plaintext secrets or the age key.
- Decrypt for reading with `sops -d <file>` (needs `../home-ops-secrets/age.key`). To add/update a secret, edit as an sops file. Renovate and codespell pre-commit both ignore `*.sops.*`.
- Version/image updates always come through `renovate:` annotations (see `talos/talenv.yaml`, helm/container comments). Don't hand-bump versions outside the rename convention.

## Talos cluster

- 3 nodes: `rpi-00` 192.168.68.252 (arm64, worker, Raspberry Pi), `c-01` 192.168.68.253 (amd64, control plane, VIP `192.168.69.5`), `c-02` 192.168.68.254 (amd64, worker). Cluster endpoint `https://192.168.69.5:6443`.
- Storage (Piraeus/LINSTOR): `c-01` and `c-02` are storage nodes (label `piraeus.io/storage: true`); `rpi-00` is not.
- Node config = `talos/talconfig.yaml` + `talos/talenv.yaml` (version numbers, renovate-managed) + `talos/talsecret.sops.yaml` (encrypted); per-node patches in `talos/patches/`.
- Upgrade flow: bump versions in `talos/talenv.yaml`, then `task talos:generate-config`, then `task talos:apply-node IP=…` / `task talos:upgrade-node IP=…`, then `task talos:upgrade-k8s`.
- Note `.mise.toml` will install a talos CLI that may be newer than the cluster version in `talenv.yaml` — they are independent.

## Validation

- No useful CI — `.github/workflows/ci.yaml` is a stub. Renovate (GH Actions on a 4-hour cron) is the real automation; it auto-applies patch+minor+digest bumps and raises PRs for majors.
- Local checks: `pre-commit run --all-files` (trailing-whitespace, yaml, codespell, semgrep secrets scan). `kubeconform` is available via mise for schema validation.
- Commit style is conventional (`fix(helm):`, `chore(container):`, `feat(helm):`) — match it.

## Doc pointers

- `docs/` has ops runbooks: `velero-restore.md`, `managing-garage.md`, `control-plane-shutdown.md` (drbdadm down before storagenode shutdown), `zfs.md`.
- `logs.md` is a running TODO/notes file (netpol rollout strategy, known issues). `toolkit/` has throwaway debug manifests. `tmp/`, `.private/`, `.venv/` are gitignored local scratch.
