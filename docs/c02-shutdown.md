# c-02 shutdown and two-node maintenance

Run this when `c-02` must be powered off for a while and the critical
workloads should keep running on `c-01` + `rpi-00`.

The script is `scripts/c02-shutdown.sh`; the reviewed app lists and
shutdown toggles live in `scripts/c02-shutdown.yaml`.

## What the script does

1. Preflight: node readiness, LINSTOR satellites Online, storage health,
   and a check that no kept namespace has a volume with no `c-01` UpToDate
   replica. The two LLM volumes are single-replica on `c-02`; they are
   allowed to go offline because `llm` is scaled down.
2. Writes a restore state file to `tmp/c02-shutdown-state-*.json`.
3. Suspends Flux:
   - top-level `flux-system` Kustomization first,
   - `infra`/`apps` roots,
   - every Kustomization whose `spec.targetNamespace` is in the scaled
     namespaces,
   - every HelmRelease in those namespaces.
4. Applies the MySQL live patches:
   - pins the InnoDBCluster CR + live StatefulSet/router Deployment to
     `kubernetes.io/arch: amd64`,
   - sets MySQL memory to `1408Mi` + sidecar `192Mi`.
   The operator only reads `podSpec` when it builds the StatefulSet, so the
   live patch is what moves the current pod. The Git CR change covers future
   rebuilds.
5. Stops operator-managed resources:
   - Keycloak `spec.instances: 0`,
   - Prometheus/Alertmanager `spec.replicas: 0`.
6. Waits for those pods to disappear.
7. Cordons `c-02` and moves the kept, PDB-protected Harbor CNPG pod
   (`harbor-system/cnpg-harbor-1`) off the node while the CNPG operator is
   still running.
8. Scales the configured namespaces to 0. `cnpg-system` is scaled after the
   Harbor DB is safe on `c-01`; this also stops the CNPG operator so the
   Immich/Keycloak CNPG StatefulSets stay at 0.
9. Stops selected DaemonSets via a sentinel `nodeSelector` and suspends
   selected CronJobs.
10. Drains `c-02` (PDB-aware by default), waits for non-DaemonSet pods to
    leave, runs `drbdadm down all` in the `c-02` LINSTOR satellite, and then
    runs `talosctl shutdown`.
11. Leaves a state file for `--restore`.

## Prerequisites

- The right-size commit is merged and reconciled. If it is not live, the
  original (larger) requests remain and kept pods may stay Pending after the
  drain.
- `c-02` is Ready and uncordoned.
- `c-01` and `rpi-00` are Ready, and all three LINSTOR satellites are
  Online.
- `KUBECONFIG` and `TALOSCONFIG` are set (the repo's `.mise.toml`/Taskfile
  point them at `../home-ops-secrets/`).
- `kubectl`, `jq`, `yq`, `talosctl` are available (via `mise`).
- You have reviewed `scripts/c02-shutdown.yaml`.

## Commands

```sh
# Dry run: preflight + full plan, no changes
task c02:shutdown

# Execute (prompts for the node name)
task c02:shutdown:apply

# Collect the state file without changing anything
./scripts/c02-shutdown.sh --write-state-only --state-file tmp/c02-state.json

# Prepare only: suspend Flux + scale apps, but no cordon/drain/drbd/shutdown
./scripts/c02-shutdown.sh --apply --scale-only

# Drain + drbdadm down, but do not power off (power it off yourself)
./scripts/c02-shutdown.sh --apply --no-shutdown

# Bypass PDBs if a drain is stuck (use deliberately)
./scripts/c02-shutdown.sh --apply --force-drain
```

The script defaults to a dry run. `--apply` requires typing the node name
unless `--yes` is passed.

## Configuration

Edit `scripts/c02-shutdown.yaml` for the public workload set. For workloads
managed outside this repository, keep a separate extra config and pass it
without committing private names here:

```sh
./scripts/c02-shutdown.sh --config scripts/c02-shutdown.yaml \
  --extra-config /path/to/private-extra.yaml
# or:
C02_EXTRA_CONFIG=/path/to/private-extra.yaml task c02:shutdown:apply
```

The extra config is merged only for list fields (`keep.namespaces`,
`suspendKustomizations`, `scale.namespaces`, `daemonSets`, `cronJobs`,
`customResources`, `patches`, and related lists). Scalars (node, timeouts,
shutdown toggles) come from the base config.

- `keep.namespaces`: documentation/preflight only. The current keep set is
  the two-node critical set; `phela` and the Cloudflare tunnel are explicitly
  kept.
- `scale.namespaces`: Deployments/StatefulSets in these public namespaces
  are scaled to 0. The default stops Immich, Keycloak, monitoring, LLM, ATE,
  kagent, Crossplane, RabbitMQ, Velero, Falco, and portfolio. `phela` is
  intentionally kept. Add out-of-repo namespaces with `--extra-config` or
  `C02_EXTRA_CONFIG`.
- `scale.exclude`: `namespace/kind/name` exceptions.
- `scale.daemonSets`: DaemonSets that cannot be scaled; the script patches
  their nodeSelector to a sentinel and deletes their pods.
- `scale.cronJobs`: CronJobs paused while the node is down.
- `customResources`: operator resources stopped before scaling. Currently
  Keycloak, Prometheus, and Alertmanager.
- `waitForPodsGone`: CR-managed pods the script waits for before scaling
  their namespaces.
- `preDrainDeletePods`: kept, PDB-protected pods moved off `c-02` before
  drain. Currently Harbor's CNPG primary.
- `patches`: MySQL amd64 pin and live resource requests, plus the CR patch.
- `shutdown`: drain/drbd/talos toggles and timeouts.

### Why `cnpg-system` is scaled

CNPG's `Cluster.spec.instances` has a minimum of 1; it cannot represent
"stopped". To keep the Immich/Keycloak databases down on two nodes, the
script stops the CNPG operator after the Harbor DB has been moved and the
CNPG StatefulSets are scaled to 0. The Harbor DB keeps running on `c-01`
without the operator during the window. On restore the operator is scaled
back and reconciles the clusters.

### Why Harbor CNPG is deleted before drain

`cnpg-harbor-primary` has `maxUnavailable: 0` for its single instance, so a
normal drain blocks. The script cordons `c-02`, deletes the old primary pod,
and waits for `cnpg-harbor-1` to become Ready on another node while the CNPG
operator is still running. MySQL's PDB allows one disruption, so it is
handled by the drain.

## DRBD and quorum

`drbdadm down all` runs in the `c-02` `linstor-satellite` container after
all non-DaemonSet pods have left the node. If it fails (for example a stale
kubelet mount), the script prints the host DRBD mounts and aborts before
power-off. See `docs/linstor-recovery.md` section 4 before forcing anything.

While `c-02` is down:

- LINSTOR quorum is `c-01` + the `rpi-00` diskless tiebreaker. **Do not
  reboot or drain `c-01` or `rpi-00`.**
- Do not run large Velero/Kopia data-mover backups; see the 2026-10-21 case
  study in `docs/linstor-recovery.md`.
- The two LLM single-replica volumes on `c-02` are offline by design.

## Restore

1. Power `c-02` back on.
2. Wait for `kubectl get node c-02` to be Ready and for the LINSTOR
   satellite to be Online.
3. Run:

```sh
task c02:restore
# or, for a specific state file:
./scripts/c02-shutdown.sh --restore \
  --state-file tmp/c02-shutdown-state-YYYYMMDDTHHMMSSZ.json
```

The restore script waits for the node and LINSTOR satellite, uncordons,
restores the custom-resource fields, DaemonSet nodeSelectors, workload
replicas, and CronJobs, then unsuspends HelmReleases and Kustomizations in
reverse order. It annotates Flux objects for immediate reconciliation.

Watch:

```sh
kubectl -n flux-system get kustomizations
kubectl -n piraeus-datastore exec deploy/linstor-controller -- linstor resource list
kubectl -n mysql get pods
kubectl -n harbor-system get pods
kubectl get pods -A --field-selector status.phase=Pending
```

The LINSTOR `c-02` replicas will resync from `c-01`; do not power-cycle
`c-01`/`rpi-00` while that is in progress.

## Troubleshooting

- **Drain blocked**: inspect `kubectl get pdb -A` and the pods on `c-02`.
  Do not use `--force-drain` unless you accept bypassing PDBs.
- **`drbdadm down all` failed**: the script aborts. Check the mounts with
  `talosctl --nodes 192.168.68.254 read /proc/mounts | grep drbd`; follow
  `docs/linstor-recovery.md`.
- **MySQL router CrashLoop on rpi**: the live Deployment patch pins it to
  amd64. Verify `kubectl -n mysql get deploy mysql-0-router -o
  jsonpath='{.spec.template.spec.nodeSelector}'`.
- **Flux root gets un-suspended**: the flux-operator may reconcile the
  FluxInstance. Check `kubectl -n flux-system get kustomization
  flux-system -o jsonpath='{.spec.suspend}'`; re-apply the script or
  suspend the flux-operator if necessary.
- **Right-size not live**: merge/reconcile the right-size commit before
  running the shutdown, otherwise capacity is tighter than planned.
- **State file**: `tmp/c02-shutdown-state-*.json` is the source of truth for
  restore. Keep it until c-02 is back and the cluster is verified.
