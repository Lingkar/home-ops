# LINSTOR orphan resource cleanup

LINSTOR accumulates `resource-definitions` (RDs) whose PV/PVC no longer exists in
the API server. These consume storage-pool space and clutter the dashboard.

## Background

As of 2026-09-20 the cluster has 73 LINSTOR RDs but only 32 PVs/PVCs, i.e. 41
orphaned RDs (~56%). Two situations:

- **Snapshot anchors (26 RDs):** the PV is gone, but the RD still holds LINSTOR
  snapshots referenced by a `VolumeSnapshotContent`. All of these trace back to
  Velero backups that no longer exist (expired `velero-pv-snapshots-local-*`
  and one-off `migrate-*` runs), so they are leaked snapshots rather than
  usable restore points.
- **True garbage (15 RDs):** no PV/PVC and no `VolumeSnapshotContent` reference.
  About 405 GiB reclaimable, almost all in the old `scroop/media` SSD volume.

Orphans come from three sources:

1. `Retain` reclaim policy on `ssd-lvm-thin-2` and `hdd-raidz-thin-1`: PVs left
   behind, and LINSTOR snapshots blocking RD deletion.
2. CNPG/StatefulSet churn (keycloak, harbor, tgoo, mysql): every recreate or
   restore makes a new PVC UID; old PVs are removed but RDs are not.
3. Expired Velero backups whose `VolumeSnapshot`/`VolumeSnapshotContent` objects
   are never garbage-collected (the leak is ongoing).

## Helper

All commands run against the LINSTOR controller pod. Define these in the shell
first:

```sh
LINSTOR_POD=$(kubectl -n piraeus-datastore get pods --no-headers | awk '/^linstor-controller-/{print $1; exit}')
linstor() { kubectl -n piraeus-datastore exec "$LINSTOR_POD" -c linstor-controller -- linstor "$@"; }
```

## Phase 0 - Preflight

Record the current state and confirm cluster access:

```sh
kubectl get pv -o custom-columns='PV:.metadata.name,CLAIM:.spec.claimRef.name'
kubectl get pvc -A
linstor resource-definition list
linstor snapshot list
```

Rules:

- Never delete by name; always by RD UUID (`pvc-<uid>`).
- Before each delete, re-verify the PV is really gone:
  `kubectl get pv <pvc-uid>` must return `NotFound`.
- A live PVC/PV always has a different UID than any orphan listed here, so
  UUID-based deletes cannot affect a running volume even when the original PVC
  name matches.

Recompute the orphan list at any time:

```sh
linstor_rds() { linstor resource-definition list | awk -F'│' 'NF>=3 {gsub(/ /,"",$2); if($2 ~ /^pvc-/) print $2}'; }
pvs() { kubectl get pv -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'; }
comm -23 <(linstor_rds | sort) <(pvs | sort)
```

## Phase 1 - Delete the 15 true-garbage RDs

These have no PV/PVC and are not referenced by any `VolumeSnapshotContent`.
LINSTOR refuses to delete an RD while it still has snapshots, so delete the
snapshots first.

### 1a. RDs with snapshots (9)

| RD (UUID) | Original PVC |
|---|---|
| `pvc-19bad50f-75a3-4669-bc37-e9525074b615` | keycloak-system/cnpg-keycloak-2 |
| `pvc-44251dd3-03a9-41fd-b83f-0deb2bf3175d` | keycloak-system/cnpg-keycloak-5 |
| `pvc-54502e6f-115e-434e-9c72-1993774740cd` | keycloak-system/cnpg-keycloak-4 |
| `pvc-97e9a450-ef53-4cd7-822d-4516e2c2d4b6` | keycloak-system/cnpg-keycloak-3 |
| `pvc-da67d80d-915c-457c-b74d-c5d9b01e676f` | keycloak-system/cnpg-keycloak-1 |
| `pvc-daf2c4ee-b85b-4976-a05c-de41c54ba1ec` | keycloak-system/cnpg-keycloak-1 |
| `pvc-f0406c44-5903-4530-a41b-6fe2bdbda895` | keycloak-system/cnpg-keycloak-3 |
| `pvc-f0d31807-363a-454e-8473-c6d1ad1103bc` | harbor-system/cnpg-harbor-6 |
| `pvc-f7f82e9a-ba5f-425b-8760-c2ea6fe2ab71` | tgoo/cnpg-tgoo-1 |

Delete their snapshots, then the RDs:

```sh
for rd in \
  pvc-19bad50f-75a3-4669-bc37-e9525074b615 \
  pvc-44251dd3-03a9-41fd-b83f-0deb2bf3175d \
  pvc-54502e6f-115e-434e-9c72-1993774740cd \
  pvc-97e9a450-ef53-4cd7-822d-4516e2c2d4b6 \
  pvc-da67d80d-915c-457c-b74d-c5d9b01e676f \
  pvc-daf2c4ee-b85b-4976-a05c-de41c54ba1ec \
  pvc-f0406c44-5903-4530-a41b-6fe2bdbda895 \
  pvc-f0d31807-363a-454e-8473-c6d1ad1103bc \
  pvc-f7f82e9a-ba5f-425b-8760-c2ea6fe2ab71; do
  linstor snapshot list "$rd" | awk -F'│' 'NF>=3 {gsub(/ /,"",$3); if($3 ~ /^snapshot-/) print $3}' | \
    while read -r snap; do linstor snapshot delete "$rd" "$snap"; done
  linstor resource-definition delete "$rd"
done
```

### 1b. RDs without snapshots (6)

| RD (UUID) | Original PVC | Notes |
|---|---|---|
| `pvc-6b5705c0-22ac-40e5-9ac9-47748ab84698` | scroop/media | ~395 GiB on `ssd-lvm-thin` (c-02) |
| `pvc-4b3ee321-efa2-496e-be78-bb1b6eb7d98a` | mysql/datadir-mysql-1 | ~1 GiB |
| `pvc-7dfd27a2-0a4e-4bc7-a1ef-37c98ccfbec8` | tgoo/cnpg-tgoo-3 | |
| `pvc-8f64b386-0eb9-4456-83eb-bd5142cc0728` | tgoo/cnpg-tgoo-2 | |
| `pvc-93fab1d1-6838-493d-b75d-405e2520f76e` | scroop/kodi-data | |
| `pvc-089d3997-40fd-46b0-8767-eeb0da3b4d0b` | velero temp snapshot PVC | RD stuck in `DELETE` state |

Before deleting `scroop/media`, confirm the old SSD media library is superseded
by `nfs-media`/`nfs-media-books` on `hdd-raidz-thin-1`.

```sh
for rd in \
  pvc-6b5705c0-22ac-40e5-9ac9-47748ab84698 \
  pvc-4b3ee321-efa2-496e-be78-bb1b6eb7d98a \
  pvc-7dfd27a2-0a4e-4bc7-a1ef-37c98ccfbec8 \
  pvc-8f64b386-0eb9-4456-83eb-bd5142cc0728 \
  pvc-93fab1d1-6838-493d-b75d-405e2520f76e \
  pvc-089d3997-40fd-46b0-8767-eeb0da3b4d0b; do
  linstor resource-definition delete "$rd"
done
```

`pvc-089d3997` may already be in `DELETE`; re-issue the delete and check
`linstor error-reports list` if it remains stuck.

## Phase 2 - Clear leaked VolumeSnapshots (frees the 26 snapshot anchors)

Do **not** delete the LINSTOR snapshots directly. Delete the orphaned
`VolumeSnapshot` objects and let the CSI driver (VolumeSnapshotClass `linstor`,
`deletionPolicy: Delete`) remove the LINSTOR snapshot. The RD then becomes empty
and can be deleted with the Phase 1 procedure.

The 26 anchor RDs and their original PVCs:

| RD (UUID) | Original PVC | Origin |
|---|---|---|
| `pvc-0145a2b3-727b-469d-a9e1-c838b9b6ee5f` | scroop/radarr-config | velero-local + migrate-scroop |
| `pvc-1a8e21d3-20e7-466d-9957-0a5f42575752` | mysql/datadir-mysql-1 | velero-local + migrate-mysql-0 |
| `pvc-24e0c6a2-ac76-4afe-a6b6-990408dda438` | keycloak-system/cnpg-keycloak-2 | velero-local |
| `pvc-2e320fa6-2ae6-4fcf-9430-e4bdb699d6a3` | piraeus-datastore/nfs-test-pvc | velero-local |
| `pvc-2f3a68f3-e200-4929-b112-bcc79561dd1d` | harbor-system/cnpg-harbor-4 | velero-local |
| `pvc-31124de1-5cb5-49f6-8055-4aeba2a7de62` | harbor-system/cnpg-harbor-5 | velero-local |
| `pvc-3e0b0af8-8311-48f0-899f-8ce5755643bc` | harbor-system/cnpg-harbor-1 | unlabeled + velero-local |
| `pvc-3e5f45da-87e4-4c9c-968b-1da14e8b8256` | mysql/datadir-mysql-0 | velero-local + migrate-mysql-0 |
| `pvc-4a911f67-4907-4510-b4d7-cc173602269f` | home-assistant/home-assistant | velero-local + migrate-ha |
| `pvc-4de4da91-bf57-47ed-b8e4-65d266f2bf2d` | harbor-system/cnpg-harbor-2 | velero-local + unlabeled |
| `pvc-5e7a5470-17b3-4085-bed8-37971141579e` | scroop/prowlarr-config | velero-local + migrate-scroop |
| `pvc-6017f080-ba9a-4044-a1cc-3e2248331914` | scroop/sonarr-config | velero-local + migrate-scroop |
| `pvc-71373115-d501-4885-93da-68949081274a` | scroop/lazylibrarian-config | velero-local + migrate-scroop |
| `pvc-7792c7c1-2123-4c76-a823-f50fef3600c9` | velero temp snapshot PVC | migrate-monitoring-2 |
| `pvc-7b5b4c25-c4ec-4e5d-8462-139544a34fbb` | phela/phela | velero-local + migrate-phela |
| `pvc-82c1be86-04ef-4152-b4f1-be900d9c8c4e` | scroop/media-books | velero-local + migrate-scroop |
| `pvc-8e3c6d64-0b3e-459c-9242-a62df6b467cc` | keycloak-system/cnpg-keycloak-1 | velero-local |
| `pvc-915ac854-6607-415f-85b6-1d5d3a76feed` | zigbee2mqtt/data-volume-zigbee2mqtt-0 | velero-local + migrate-zigbee |
| `pvc-a4801000-5d5e-4a09-a099-455a2d1e8e34` | mysql/mysql-backup | velero-local + migrate-mysql-0 |
| `pvc-a774e6a0-531e-45f7-91d9-b49f73236cfb` | scroop/calibre-config | velero-local + migrate-scroop |
| `pvc-bfa18b49-09e7-49dd-a6a9-f1e653f07dd8` | scroop/lidarr-config | velero-local + migrate-scroop |
| `pvc-c9d92d57-6534-4ae2-85ba-d4841f4d77cb` | harbor-system/cnpg-harbor-3 | velero-local |
| `pvc-d3c4b00d-d3e7-4520-9790-cc67d59899cb` | scroop/cross-seed-config | velero-local + migrate-scroop |
| `pvc-dc88a703-cd2e-4679-a66c-4033e2d9b0b1` | keycloak-system/cnpg-keycloak-6 | velero-local |
| `pvc-e1fbe144-1ae9-4c89-b45e-a0d95b31ed7f` | scroop/qbittorrent-config | velero-local + migrate-scroop |
| `pvc-f9f1629e-9033-4b1d-a9f3-75978d99d891` | portfolio/data-volume | velero-local |

### 2a. Inventory the leaked objects

Map each `VolumeSnapshotContent` to its RD, originating backup and whether that
backup still exists:

```sh
EXIST=$(kubectl get backups.velero.io -n velero -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
kubectl get volumesnapshotcontent -o jsonpath='{range .items[*]}{.metadata.name}|{.metadata.labels.velero\.io/backup-name}|{.metadata.creationTimestamp}|{.status.snapshotHandle}{"\n"}{end}' \
  | grep InCluster
```

Anchoring backups observed (all `GONE` at time of writing):

| Backup | VSCs | Date |
|---|---|---|
| `migrate-scroop` | 9 | 2026-05-29 |
| `migrate-mysql-0` | 4 | 2026-05-29/30 |
| `migrate-ha`, `migrate-zigbee`, `migrate-phela`, `migrate-monitoring-2` | 1 each | 2026-05-29 |
| `velero-pv-snapshots-local-20260518000027` | 21 | 2026-05-18 |
| `velero-pv-snapshots-local-20260322120028` | 8 | 2026-03-22 |
| `velero-pv-snapshots-local-20260531120005` | 3 | 2026-05-31 |
| `…-local-20260325080004`, `…-20260529160015`, `…-20260531000008`, `…-20260617080041` | 1 each | Mar-Jun |
| (unlabeled) | 2 | 2026-05-25/27 |

Current schedules (`local` 4h/TTL 12h, `remote-daily` TTL 168h, `remote-weekly`
TTL 850h) do not retain any of them.

### 2b. Delete leaked VolumeSnapshots

For every `VolumeSnapshot` whose `velero.io/backup-name` is not in `$EXIST`,
delete the VolumeSnapshot CR. Newer objects that only implement the CSI
snapshot API can be removed directly:

```sh
kubectl get volumesnapshot -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"|"}{.metadata.name}{"|"}{.metadata.labels.velero\.io/backup-name}{"\n"}{end}' \
  | while IFS='|' read -r ns name backup; do
      printf '%s\n' "$EXIST" | grep -qx "$backup" || echo "kubectl -n $ns delete volumesnapshot $name"
    done
```

Review the printed `delete` commands before running them. The CSI driver removes
the corresponding LINSTOR snapshot; re-run the Phase 1 RD delete afterwards.

For the dangling `VolumeSnapshotContent`s (4 at time of writing, e.g.
`scroop/7eff9733…` -> `pvc-5cd75007…`, an RD that no longer exists) delete the
content and drop its finalizer if needed:

```sh
kubectl delete volumesnapshotcontent snapcontent-<id>
```

## Phase 3 - Live-volume snapshot hygiene

These anomalies sit on live volumes and are worth cleaning separately:

- `DELETING` LINSTOR snapshots: `pvc-0145a2b3`, `pvc-3ec820ea` (radarr),
  `pvc-73d61467` (nfs-media-books), `pvc-a4801000`, `pvc-ff3e2abd` (mysql).
- `Failed` LINSTOR snapshots: `pvc-66ca7fb9` (kodi-data), `pvc-e7b7d2d6`
  (mysql-backup), `pvc-ead28951` (cross-seed-config), `pvc-eed2bfce`
  (falcosidekick redis).

Inspect with `linstor snapshot list` and `linstor error-reports list`; delete
the ones that are no longer referenced by a `VolumeSnapshotContent`.

## Phase 4 - Prevent recurrence

The remaining leak is **LINSTOR snapshots not being deleted**, not Velero
object cleanup. Root cause and the running procedure are in
`docs/linstor-snapshot-gc.md`. Summary:

- `pv-snapshots-local` creates a CSI snapshot of every PVC every 4h
  (`snapshotMoveData: false`); deletion is unreliable
  (`piraeusdatastore/linstor-csi#290`, `#286`, `LINBIT/linstor-server#440`), so
  orphaned LINSTOR snapshots accumulate.
- The unused `snap.linstor.csi.linbit.com/allow-incremental` param was removed
  from the `linstor` VolumeSnapshotClass.
- A manual 24h GC runbook (`docs/linstor-snapshot-gc.md`) is the interim
  control. Automate it later.
- Consider whether `Retain` is still desired on `ssd-lvm-thin-2` and
  `hdd-raidz-thin-1`.
- Add an alert when `count(LINSTOR resource-definitions)` diverges from
  `count(PersistentVolumes)`, or when `Failed`/`DELETING` snapshots appear.

## Execution results (2026-09-20)

- Phase 1: 15 orphaned RDs deleted (35 snapshots first), ~405 GiB reclaimed.
- Phase 2: 82 leaked `VolumeSnapshot`s and 88 `VolumeSnapshotContent`s deleted
  (all belonged to non-existent Velero backups), then the 26 anchored RDs
  deleted. 2 VSCs stuck since 2026-05-30 needed finalizer removal.
- Outcome: LINSTOR RDs 73 -> 32 (= PVs), orphan RDs 41 -> 0, VolumeSnapshots
  and VSCs 0, all 32 PVCs stayed `Bound`, no pods disrupted.
- Leftover: 463 orphaned LINSTOR snapshots on live RDs (452 `Successful`,
  8 `Failed`, 3 `DELETING`). 376 older than 24h (incl. all Failed/DELETING)
  were deleted, freeing ~230 GiB; 87 `Successful` younger than 24h remain for
  the next run of `docs/linstor-snapshot-gc.md`.
