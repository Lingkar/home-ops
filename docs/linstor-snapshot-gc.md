# LINSTOR snapshot garbage collection (manual runbook)

Run this periodically to reclaim LINSTOR snapshots that K8s no longer tracks.
It is the main control for the snapshot leak until upstream fixes land.

## Why

Piraeus/LINSTOR creates CSI snapshots for Velero. Deletion is unreliable in
this stack, so LINSTOR keeps snapshots after the K8s `VolumeSnapshot` /
`VolumeSnapshotContent` objects are gone. Upstream:

- `piraeusdatastore/linstor-csi#290` - snapshots not deleted, orphaned
  snapshots accumulate (open).
- `piraeusdatastore/linstor-csi#286` - ZFS/replica deletion race, snapshot
  stuck in `DELETING` on one replica (open).
- `LINBIT/linstor-server#440` - deletion blocked by a stuck backup-shipping
  queue (open).

Contributing configuration: `pv-snapshots-local` snapshots every PVC every
4 hours (`snapshotMoveData: false`). That is intentional; this runbook handles
the fallout. The unused `snap.linstor.csi.linbit.com/allow-incremental` param
was removed from the `linstor` VolumeSnapshotClass to stop snapshots being
flagged for backup shipping.

Root cause summary: the aggressive local schedule generates a high volume of
snapshots, and the driver/LINSTOR sometimes fails to delete them (HTTP 500,
`DELETING`/`Failed` states), so they accumulate unbounded.

## Key facts about this cluster

- LINSTOR uses the Kubernetes CRD DB backend. The LINSTOR internal CRDs live in
  group `internal.linstor.linbit.com` and ARE the live database. Do not delete
  them by hand unless the corresponding object is already gone from LINSTOR.
- `ResourceDefinitions` (`resourcedefinitions.internal.linstor.linbit.com`)
  stores both resource definitions and snapshot definitions:
  - live RD: `spec.snapshot_dsp_name` is empty, `spec.resource_name` is `PVC-<uuid>`
  - snapshot def: `spec.snapshot_dsp_name` = `snapshot-<uuid>`
- `PropsContainers` rows for snapshots have a `spec.props_instance` containing
  `SNAP_DFNS_RSC_DFN`.
- Counts are consistent when healthy: `ResourceDefinitions` CRs =
  live RDs + snapshot definitions.

## Helper

```sh
LINSTOR_POD=$(kubectl -n piraeus-datastore get pods --no-headers | awk '/^linstor-controller-/{print $1; exit}')
linstor() { kubectl -n piraeus-datastore exec "$LINSTOR_POD" -c linstor-controller -- linstor "$@"; }
```

## Step 1 - Inventory (read-only)

Current K8s snapshot objects and in-progress restores:

```sh
kubectl get volumesnapshot -A
kubectl get volumesnapshotcontent
kubectl get restores.velero.io -A
kubectl get backups.velero.io -n velero --sort-by=.metadata.creationTimestamp | tail
```

LINSTOR snapshots, including state and age:

```sh
linstor snapshot list --no-color
```

Build the list of snapshots with no matching K8s `VolumeSnapshot` and older
than 24h. 24h is chosen to be longer than the local TTL (12h) but short enough
to keep the backlog bounded:

```sh
linstor snapshot list --no-color | awk -F'│' 'NF>=3 && $2 ~ /pvc-/{gsub(/ /,"",$2);gsub(/ /,"",$3);gsub(/ /,"",$6);gsub(/ /,"",$7); print $2"|"$3"|"$6"|"$7}' \
  | while IFS='|' read -r rd snap created state; do
      echo "$rd $snap $created $state"
    done
```

Cross-check against `kubectl get volumesnapshot -A` (RD/snapshot come from the
`VolumeSnapshotContent.status.snapshotHandle` of the form
`InCluster:///<rd>/<snapshot>`).

## Step 2 - Delete the safe ones

Only delete snapshots that have no K8s `VolumeSnapshot` reference and are older
than 24h. Delete via the CLI so the DB CRs are cleaned up too:

```sh
linstor snapshot delete <rd> <snapshot>
```

Do them in small batches and watch the controller:

```sh
kubectl -n piraeus-datastore logs "$LINSTOR_POD" -c linstor-controller -f | rg -i 'snapshot.*(delete|error|fail)'
```

## Step 3 - Handle `Failed` / `DELETING`

Snapshots left in `Failed` or `DELETING` will not clear on their own.

- Retry `linstor snapshot delete <rd> <snapshot>` a few times.
- Check for a stuck shipping queue: `linstor backup queue list` (should be
  empty). If entries exist, `linstor backup abort ...` per the error message.
- The `DELETING`-with-partial-replica case (upstream #286): delete the snapshot
  manually on the satellite that still holds it, then restart that satellite
  pod. Example: shell into the `linstor-satellite.<node>` pod and run
  `zfs destroy`/`lvm lvremove` on the snapshot, then
  `kubectl -n piraeus-datastore delete pod <linstor-satellite-pod>`.
- Re-check `linstor error-reports list` after each step.

## Step 4 - Verify DB CRs were cleaned

The CRs should shrink to match `linstor snapshot list`:

```sh
# total resource-definition rows (live RDs + snapshot definitions)
kubectl get resourcedefinitions.internal.linstor.linbit.com --no-headers | wc -l
# snapshot definitions specifically
kubectl get resourcedefinitions.internal.linstor.linbit.com -o json \
  | jq '[.items[] | select(.spec.snapshot_dsp_name != "")] | length'
# snapshot props
kubectl get propscontainers.internal.linstor.linbit.com -o json \
  | jq '[.items[] | select(.spec.props_instance | test("SNAP_DFNS_RSC_DFN"))] | length'
linstor snapshot list --no-color   # compare counts
```

If a CR remains for a snapshot that no longer appears in `linstor snapshot
list`, it is an orphaned DB row. Only then, and after confirming no live RD uses
it, remove that single CR:

```sh
kubectl delete resourcedefinitions.internal.linstor.linbit.com <hash>
```

Never delete a CR whose snapshot still appears in `linstor snapshot list`.

## Step 5 - Resource-definition (RD) analysis

The same backlog also leaves orphaned *resource definitions* (a RD with no PV).
`Retain` StorageClasses (`ssd-lvm-thin-2`, `hdd-raidz-thin-1`) plus PVC/PV
churn leave these behind; a RD with snapshots refuses to delete until the
snapshots are gone.

Find orphan RDs (no matching PV):

```sh
linstor_rds() { linstor resource-definition list --no-color | awk -F'│' 'NF>=3 {gsub(/ /,"",$2); if($2 ~ /^pvc-/) print $2}'; }
pvs() { kubectl get pv -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'; }
comm -23 <(linstor_rds | sort) <(pvs | sort)
```

For each: confirm no `VolumeSnapshotContent` references it, clear its snapshots
(Step 2/3), then `linstor resource-definition delete <rd>`.

### What was already cleaned (2026-09-20)

- Phase 1: 15 orphaned RDs with no K8s reference deleted, ~405 GiB reclaimed
  (largest `scroop/media` ~395 GiB). Included keycloak/harbor/tgoo/mysql
  leftovers and a stuck `velero` temp RD.
- Phase 2: 82 leaked `VolumeSnapshot`s + 88 `VolumeSnapshotContent`s removed
  (all from Velero backups that no longer existed), then the 26 RDs they
  anchored deleted.
- Result: LINSTOR RDs 73 -> 32, matching the 32 PVs; orphans 41 -> 0.
- What remained after Phases 1-2: 463 LINSTOR snapshots on live RDs with no K8s
  object reference (452 `Successful`, 8 `Failed`, 3 `DELETING`).
- Same-day Step-2 backlog run: deleted the 365 `Successful` snapshots older
  than 24h, plus all 8 `Failed` and 3 `DELETING` ones (376 total). This freed
  ~130 GiB on c-01 and ~100 GiB on c-02. 87 `Successful` snapshots younger
  than 24h were left for the next GC run.

## Step 6 - Monitor

- Piraeus "Failed"/"DELETING" snapshot count should be 0.
- `ResourceDefinitions` CR count should equal live RDs + intended snapshots.
- `PropsContainers` count should not grow without bound (`#290`).
- Alert on repeated `SnapshotDeleteError` events.
