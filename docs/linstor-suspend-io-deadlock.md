# DRBD `suspend-io` deadlock (`bdev_freeze` -> `super_lock`)

Deep-dive analysis of the 2026-11-01 LINSTOR/DRBD wedge that made `c-02`'s
satellite unrecoverable on 2026-11-06. Operational recovery steps are in
`docs/linstor-recovery.md` §8; this file keeps the evidence, root-cause analysis,
and a ready-to-fill upstream report so it can be reported again if it recurs on a
later version.

Status: analysed from a live but wedged node on 2026-11-06; resolved by a
physical power cycle. The exact lock holder could not be observed after the
reboot, so the lock-order analysis below is inferred from the captured stacks,
DRBD source, and the timestamped satellite log.

## TL;DR

DRBD 9.3.4's admin `suspend-io` command calls `bdev_freeze()` on the DRBD block
device. The evidence points to the device already being I/O-suspended by an
internal operation (online resize/size negotiation; a quorum suspend or resync
is also possible). The filesystem freeze then waited for JBD2/LVM writes to
drain, those writes were blocked in `__drbd_make_request` by the internal
suspend, and the internal suspend was waiting for application I/O to drain.
Circular wait; no timeout; `drbdsetup` in `D` state forever; only a
reboot/power cycle clears it.

The missing guard is in DRBD: `drbd_nl_suspend_io_doit()` skips `bdev_freeze()`
only when the block device was already frozen by a **user** suspend
(`BDEV_FROZEN`), not when it is already suspended for an internal resize/resync
or quorum. DRBD's own commit introducing the freeze says:

> Since we probably get stuck if we try to freeze an already suspend device, we
> also need to set a flag on which devices are already suspended.

That flag is only `BDEV_FROZEN`.

## Affected versions

| Component | Version at incident |
|---|---|
| DRBD kernel module | 9.3.4 (`api:2/proto:118-125`, GIT-hash `e59b287b199f7224468af85b68a10e83c68213f5`) |
| drbd-utils | 9.34.3 (`DRBDADM_VERSION_CODE=0x092203`) |
| Kernel | `6.18.58-talos` |
| Talos | v1.14.5, DRBD extension `drbd 9.3.4-v1.14.5` |
| LINSTOR server | 1.35.2 (`quay.io/piraeusdatastore/piraeus-server:v1.35.2`) |
| Piraeus CSI | 1.13.0 (`quay.io/piraeusdatastore/piraeus-csi:v1.13.0`) |
| Velero | v1.18.1 |

Storage: LVM thin (`ssd-lvm-thin`, `vg1/thin`), ext4 on `/dev/drbd1017`,
resource `pvc-5c5f4d81-cdfe-4e99-915b-d53c78d3a963` (`scroop/lidarr-config`,
256 MiB, 2 diskful + 1 diskless tiebreaker).

## Trigger timeline (2026-11-01, UTC)

- `16:00`: Velero schedule `velero-pv-snapshots-local` (`0 */4 * * *`,
  `snapshotVolumes: true`, `snapshotMoveData: false`) starts a CSI snapshot
  batch. This path calls LINSTOR snapshot creation, which does
  `drbdadm suspend-io` on the DRBD layer.
- `16:03:43.386`: satellite registers
  `snapshot-39b2d01d-14d3-4da5-bc58-201d05740672` for
  `pvc-5c5f4d81-cdfe-4e99-915b-d53c78d3a963` and logs an online size
  alignment:
  ```text
  Snapshot 'snapshot-39b2d01d-...' of resource 'pvc-5c5f4d81-...' registered.
  Aligning /dev/vg1/pvc-5c5f4d81-..._00000 size from 262240 KiB to 266240 KiB
    to be a multiple of extent size 4096 KiB (from Storage Pool)
  ```
  DeviceManager cycle 191 had started at `16:03:39.471`; there is no matching
  `End DeviceManager cycle 191`.
- `16:03:43`: `drbdsetup suspend-io 1017` starts and never returns. It remains
  in `D` state for ~4 days 17 hours.
- The same alignment had repeatedly appeared earlier (`15:05`, `15:14`, `15:35`,
  `15:53`, `16:02`), suggesting an online resize / size-normalisation was active
  around the snapshot. In the first ~3 hours after the recovery reboot, no
  further alignment was logged for this volume, so we could not confirm whether
  it was a persistent LINSTOR resize bug or a one-off state.
- Snapshots after this point fail: `VolumeSnapshot.status.readyToUse: false`,
  `SnapshotDeleteError` events; Velero backups containing this PVC go
  `PartiallyFailed`. `linstor snapshot list` accumulates `Incomplete` entries.
- The c-02 satellite stays `Online` until the LINSTOR controller is
  restarted/moved at `2026-11-06 05:52`. The new controller can open TCP to
  `:3366` but never completes satellite authentication, so c-02 becomes
  `OFFLINE` with an empty `Platform`.
- Consequence: `lost-quorum` taints on c-01/c-02, ~10 s taint flapping on
  rpi-00, mass pod evictions/Pending. Recovery required a forced reboot and a
  physical power cycle (`docs/linstor-recovery.md` §6/§8).

## Evidence

### `drbdadm status` hangs

On c-02:

```text
$ drbdadm status
Command 'drbdsetup status' did not terminate within 5 seconds
```

The satellite can serve the LINSTOR control connection but cannot run DRBD
tooling.

### Interrupted processes (host `/proc`, privileged pod with `hostPID`)

```text
drbdsetup super_lock
lvm __drbd_make_request
jbd2/drbd1017-8 __drbd_make_request
kworker/...+flush-147:1017 __drbd_make_request
drbd_r_pvc-5c5f4d81-cdfe-4e99-915b-d53c78d3a963 drbd_suspend_io
drbd_r_pvc-5c5f4d81-cdfe-4e99-915b-d53c78d3a963 drbd_suspend_io
```

Command used:

```sh
for d in /proc/[0-9]*; do
  st=$(awk '{print $3}' "$d/stat" 2>/dev/null)
  [ "$st" = D ] && echo "${d#/proc/} $(cat "$d/comm") $(cat "$d/wchan")"
done
```

### `drbdsetup` kernel stack

```text
[<0>] super_lock+0x107/0x180
[<0>] bdev_super_lock+0x46/0xb0
[<0>] fs_bdev_freeze.llvm.7447930331512143966+0x1c/0xe0
[<0>] bdev_freeze+0x5f/0xc0
[<0>] drbd_nl_suspend_io_doit+0x136/0x590 [drbd]
[<0>] genl_family_rcv_msg_doit+0xfd/0x160
[<0>] genl_rcv_msg+0x242/0x260
[<0>] netlink_rcv_skb+0x184/0x1c0
```

The process was `drbdsetup suspend-io 1017` (minor 1017 maps to the lidarr
volume).

### JBD2 / LVM stacks

```text
jbd2/drbd1017-8:
  __drbd_make_request+0xb3/0x640 [drbd]
  drbd_submit_bio+0x33f/0x4f0 [drbd]
  __submit_bio+0x172/0x260
  journal_submit_commit_record+0x158/0x1a0
  jbd2_journal_commit_transaction+0x1043/0x18d0
  kjournald2+0xbc/0x240

lvm:
  __drbd_make_request+0xb3/0x640 [drbd]
  drbd_submit_bio+0x33f/0x4f0 [drbd]
  __submit_bio+0x172/0x260
  blkdev_direct_IO+0x254/0x6a0
  blkdev_read_iter+0x95/0x160
  aio_read+0x1c0/0x250
  io_submit_one+0x5a7/0x9d0
```

### DRBD receiver stacks

```text
drbd_r_pvc-5c5f4d81-... (thread 1):
  drbd_suspend_io+0x10c/0x1c0 [drbd]
  drbd_uuid_detect_finished_resyncs+0x89a/0xe00 [drbd]
  __receive_uuids+0x336/0x530 [drbd]
  receive_uuids110+0x4da/0x630 [drbd]
  drbd_receiver+0x98a/0xdd0 [drbd]

drbd_r_pvc-5c5f4d81-... (thread 2):
  drbd_suspend_io+0x10c/0x1c0 [drbd]
  drbd_determine_dev_size+0x3f/0x780 [drbd]
  receive_sizes+0x447/0xc90 [drbd]
  drbd_receiver+0x98a/0xdd0 [drbd]
```

`receive_sizes` / `drbd_determine_dev_size` is the size-negotiation path, i.e.
the internal suspend was almost certainly the online resize/resize-adjust
triggered by the LINSTOR size alignment.

### LINSTOR/DRBD state before recovery

- c-01: `disk:Outdated quorum:no blocked:upper`, `c-02 connection:Connecting`.
- c-02: all resources `Unknown` (satellite `OFFLINE`).
- rpi-00: diskless tiebreaker, `Connecting(c-02)`.
- `linstor snapshot list` for the RD contains many `Incomplete` entries plus
  one old `Successful` snapshot (`2026-10-10`) and later successful snapshots
  after recovery.
- HA controller events: `NodeStorageQuorumLost` / `NodeStorageQuorumRegained`
  every ~10 s on rpi-00; `VolumeWithoutQuorum` evictions.

## Root cause analysis

### What DRBD does

DRBD 9.3.4 `drbd_nl_suspend_io_doit()` (simplified):

```c
struct suspend_io_parms params = {
    .bdev_freeze = true,
};

if (params.bdev_freeze && !test_bit(BDEV_FROZEN, &device->flags)) {
    err = bdev_freeze(device->vdisk->part0);
    if (err)
        goto out_thaw;
    set_bit(BDEV_FROZEN, &device->flags);
}

stable_state_change(resource, change_io_susp_user(resource, true, ...));
/* then wait until I/O is drained */
```

`bdev_freeze()` enters the kernel VFS/block freeze path:

```text
bdev_freeze
  -> bd_holder_ops->freeze == fs_bdev_freeze
    -> bdev_super_lock(bdev, ...)
      -> super_lock(sb, ...)          # s_umount
    -> freeze_super(sb, ...)
    -> sync_blockdev(bdev)
```

So the freeze tries to take the mounted filesystem's `s_umount` and then sync
it. If the underlying DRBD device is already I/O-suspended, pending writes
(ext4 journal commit, LVM direct I/O) are stuck in `__drbd_make_request` and
cannot drain. The freeze waits; the filesystem cannot quiesce; DRBD never
returns from `suspend-io`.

### The most likely circular wait

This sequence is inferred from the captured stacks and log timing; the exact
task holding `s_umount` was not observed after the reboot. If it recurs, capture
all `D`-state stacks **before** rebooting.

1. A resize / size negotiation is in progress (repeated LINSTOR `Aligning ...`
   messages and receiver stacks in `receive_sizes`). Its internal
   `drbd_suspend_io()` has incremented `suspend_cnt`.
2. Normal writeback (JBD2 journal commit, LVM I/O) is blocked in
   `__drbd_make_request` because the device is suspended.
3. The admin snapshot `suspend-io` calls `bdev_freeze()`.
4. `bdev_freeze()` waits for the filesystem to freeze/sync, which requires the
   blocked writeback to complete.
5. The internal `drbd_suspend_io()` waits for application I/O (including that
   writeback) to drain.
6. Nothing can progress. There is no timeout in the freeze path; the netlink
   call stays in `D` state.

### Why the existing guard is insufficient

The `BDEV_FROZEN` bit only prevents a **second user suspend-io** from freezing
again. It does not represent:

- `drbd_suspended()` from an internal resize/resync (`suspend_cnt`),
- `on-no-quorum: suspend-io` / `on-no-data-accessible: suspend-io` suspension,
- an in-flight size negotiation (`receive_sizes` /
  `drbd_determine_dev_size`).

The upstream commit that added this behavior already warns about freezing an
"already suspend device", but the implementation only checks the user-freeze
flag. This is the concrete gap to report.

### Caveat

The exact task holding `s_umount` at the instant of the wedge was not captured
(the reboot destroyed the state). The inference is based on:

- the `bdev_super_lock`/`super_lock` stack,
- JBD2/LVM blocked in `__drbd_make_request`,
- receiver threads in `drbd_suspend_io` from `receive_sizes` /
  `drbd_determine_dev_size`,
- the simultaneous snapshot and repeated LINSTOR size alignment in the
  satellite log.

If it recurs, capture all D-state stacks and kernel `dmesg` **before** rebooting.

## Upstream status and where to report

Primary: **LINBIT/drbd** (kernel module). The deadlock is in the DRBD netlink
handler and its use of the kernel freeze path:

- Open related report: <https://github.com/LINBIT/drbd/issues/159>
  (DRBD 9.3.4, `drbd_suspend_io` D-state, LINSTOR 1.35.2, reboot required;
  different trigger: attach + udev probing).
- No existing report was found for `bdev_freeze` / `super_lock` in the DRBD
  tracker as of 2026-11-06.
- Relevant DRBD commits:
  - `27ca01bf67` "drbd: call bdev_freeze on user suspend-io command"
  - `e9d4b48d15` "drbd: let I/O drain when userspace freezes I/O on a DRBD device"
  - `28219cfbcd` "drbd: make call to bdev_freeze user-controllable"
  - `19796a154e49` "drbd: drain application I/O before committing a cluster-wide resize"
    (in 9.3.5-rc.1; related resize/I/O-drain fix)
  - `147ab386e0` "drbd: wait for the barrier acks with wait_for_barrier_acks() in suspend-io"
- DRBD 9.3.5 status: `9.3.5-rc.1` exists in the ChangeLog and includes the
  online-resize drain and suspend-io barrier changes; no stable 9.3.5 release
  was available at the time of writing. Verify with LINBIT whether it fixes this
  exact path before upgrading.

Secondary: **LINBIT/linstor-server**. The snapshot orchestration
(`SuspendManager` / `SuspendLayerUtils`) should avoid snapshotting while an
online resize/resync is in progress, or use `--bdev-freeze=no` for volumes where
crash-consistency is acceptable. Related issue:
<https://github.com/LINBIT/linstor-server/issues/540> (closed; LUKS-layer
suspend deadlock, not identical). LINSTOR 1.35.3 contains related snapshot /
suspend fixes and an `ExactSize` resize-race fix; this cluster ran 1.35.2.

Optional: **siderolabs/extensions**. The Talos extension is
`drbd 9.3.4-v1.14.5`; request a bump once a fixed DRBD release exists and has
been packaged. The kernel side is Talos `6.18.58-talos`.

### Version check before reporting again

When this recurs on a later DRBD version, inspect that version's
`drbd_nl_suspend_io_doit()` (or its renamed equivalent) before filing:

- If `bdev_freeze()` is still guarded only by `BDEV_FROZEN` (or an equivalent
  user-suspend flag), the gap is probably still present.
- If it is also guarded by `drbd_suspended()` / resize / resync state, or the
  freeze was removed/serialized, the behavior may already be fixed; compare the
  stacks carefully and note the difference.

Update the version in the issue title and environment block; the template below
is intentionally version-specific to the 2026-11-01 incident.

## Recurrence checklist (capture before rebooting)

Record versions first; the report is only useful if it says which DRBD/kernel/
LINSTOR/CSI combination reproduced it. The `LS` and `sat` helpers are defined in
`docs/linstor-recovery.md`.

```sh
# Versions
drbdadm --version
drbdsetup --version
talosctl -n <node-ip> get extensions | grep drbd
talosctl -n <node-ip> read /proc/version
kubectl -n piraeus-datastore get deploy linstor-controller \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
kubectl -n piraeus-datastore get deploy linstor-csi-controller \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'

# LINSTOR state
LS node list
LS resource list
LS resource list -r <pvc-...>
LS snapshot list | grep <pvc-...>

# DRBD tooling (expected to time out on the wedged node)
timeout 10 drbdadm status <pvc-...> ; echo rc=$?

# Host D-state + kernel stacks (privileged pod with hostPID=true)
for d in /proc/[0-9]*; do
  st=$(awk '{print $3}' "$d/stat" 2>/dev/null)
  [ "$st" = D ] && echo "${d#/proc/} $(cat "$d/comm") $(cat "$d/wchan")"
done
cat /proc/<pid>/stack

# Kernel messages (hung-task warnings, drbd resize/suspend messages)
talosctl -n <node-ip> dmesg

# Kubernetes side
kubectl get events -A | grep -iE 'quorum|drbd|linstor'
kubectl get volumesnapshot -A
kubectl get pods -A | grep -vE 'Running|Completed'
```

Satellite log markers to save around the event:

```sh
kubectl -n piraeus-datastore logs <satellite-pod> -c linstor-satellite \
  --since=<start> | grep -iE 'snapshot|suspend|Aligning|adjusted|cycle'
```

Controller markers:

```sh
kubectl -n piraeus-datastore logs deploy/linstor-controller \
  | grep -iE "No active connection|Establishing connection|authenticated|OFFLINE|ONLINE"
```

## Upstream issue template

Copy/adapt this into `LINBIT/drbd/issues/new`.

```markdown
Title: 9.3.4: suspend-io deadlocks with an internal resize / already-suspended
       device (bdev_freeze -> super_lock); node requires reboot

Environment
- DRBD kernel module: 9.3.4 (GIT-hash e59b287b...), drbd-utils 9.34.3
- Kernel: 6.18.58-talos (Talos v1.14.5, DRBD extension 9.3.4-v1.14.5)
- LINSTOR: 1.35.2, Piraeus CSI: 1.13.0, Velero 1.18.1
- Backing: LVM thin, ext4 mounted on /dev/drbdNNNN, 2 diskful + 1 diskless

What happened
- A Velero CSI snapshot triggered `drbdadm suspend-io` on a mounted ext4
  volume at the same time as an online DRBD resize / size alignment. The
  satellite log showed the snapshot registration and an `Aligning ...` size
  adjustment immediately before the hang; the DeviceManager cycle never ended.
- `drbdsetup suspend-io <minor>` stayed in D state indefinitely.
- `drbdadm status` then fails with "Command 'drbdsetup status' did not
  terminate within 5 seconds".
- The satellite stayed connected until the controller restarted, then could
  not authenticate; node became OFFLINE. A reboot/power cycle was required.

Stacks
- drbdsetup:
  super_lock
  bdev_super_lock
  fs_bdev_freeze
  bdev_freeze
  drbd_nl_suspend_io_doit [drbd]
- jbd2 and lvm:
  __drbd_make_request [drbd]
  drbd_submit_bio
  __submit_bio
  (journal commit / direct IO)
- receivers:
  drbd_suspend_io
  drbd_determine_dev_size
  receive_sizes

Analysis
`drbd_nl_suspend_io_doit()` calls `bdev_freeze()` unless BDEV_FROZEN is set.
BDEV_FROZEN only covers a previous user suspend; it does not cover an
internal `drbd_suspend_io()` (online resize/size negotiation) or a quorum
suspend. The freeze waits for the filesystem to drain, while JBD2/LVM writes
are blocked in __drbd_make_request by the internal suspend, which is itself
waiting for I/O to drain. This is a circular wait with no timeout.

Questions
1. Is this fixed by the 9.3.5-rc.1 online-resize I/O drain changes?
2. Should suspend-io skip bdev_freeze when drbd_suspended() is true, or
   serialize the freeze with an in-progress resize/resync?
3. Should there be a timeout/failure instead of an indefinite D-state wait?
4. Is `--bdev-freeze=no` the recommended workaround for this case?

Related
- LINBIT/drbd#159 (9.3.4, drbd_suspend_io D-state, reboot required)
- LINBIT/linstor-server#540 (suspend layer deadlock)
- Commits: 27ca01bf67, e9d4b48d15, 28219cfbcd, 19796a154e49
```

## Mitigations and prevention

### Real fix

- Track a DRBD release containing the fix (9.3.5-rc.1 has related resize /
  suspend-io changes but was not confirmed for this exact stack).
- Wait for the Talos `drbd` extension to be bumped; the kernel is
  `6.18.58-talos`.
- After upgrading, re-run the recurrence test: snapshot a mounted ext4 volume
  while it is resizing/resyncing and watch for `D`-state.

### Patch upgrades that are safe now

- LINSTOR `1.35.2` -> `1.35.3` (snapshot/suspend and `ExactSize` resize-race
  fixes).
- Piraeus CSI `1.13.0` -> `1.13.2`.
- These do not guarantee a fix for this kernel deadlock; they reduce related
  snapshot/resize races.

### Workaround

- `drbdadm suspend-io --bdev-freeze=no` is supported by drbd-utils, but
  LINSTOR does not expose it (it calls `drbdadm suspend-io <res>` with the
  default `bdev_freeze=yes`). Passing it avoids the freeze deadlock but yields
  crash-consistent snapshots instead of quiesced ones; request upstream rather
  than patching the satellite globally.

### Reduce exposure

- The local Velero schedule (`snapshotMoveData: false`, every 4 hours) is the
  direct CSI-snapshot path. For small, frequently written config volumes,
  consider excluding them from CSI snapshots and using Kopia/fs-backup instead
  (slower restore, no DRBD `suspend-io`).
- Avoid taking snapshots during maintenance that triggers a volume resize or
  resync.
- If the repeated LINSTOR size alignment (`262240 -> 266240 KiB`) reappears,
  investigate it as a resize loop; it was present immediately before the wedge
  and may be the trigger. Check `DrbdOptions/ExactSize` / LINSTOR 1.35.3.

### Monitoring

- Alert on `drbd_device_state{drbd_device_state=~"suspended.*|blocked.*"}`.
- Alert when `drbdadm status` times out (small privileged DaemonSet/CronJob
  with `hostPID`, or a satellite-side probe).
- Alert on `VolumeSnapshot.status.readyToUse == false` older than ~30 minutes.
- Alert on Velero `PartiallyFailed` / `Failed` backup phases. Do not rely on
  `velero_backup_last_status` alone: during this incident it reported `1`
  while backups were `PartiallyFailed`, and `velero_backup_partial_failure_total`
  stayed `0`.
- Alert on `NodeStorageQuorumLost` / `VolumeWithoutQuorum` events.
- If a node's `drbdadm status` hangs, do **not** restart the LINSTOR controller
  as a first step: a controller restart is what converted the latent wedge into
  a node `OFFLINE` here. Schedule a reboot/power cycle instead.

### Quorum setting trade-off

Piraeus defaults `on-no-quorum: suspend-io` and `on-no-data-accessible:
suspend-io`. Switching to `io-error` would make failures visible instead of
hanging, but changes failure semantics for applications and is not a proven fix
for the resize/freeze path. Do not change it without reproducing the bug with
the quorum suspend as the active condition.

## References

- `docs/linstor-recovery.md` — operational runbook, §6 and §8
- `docs/linstor-snapshot-gc.md` — snapshot cleanup
- LINBIT/drbd issue #159 — <https://github.com/LINBIT/drbd/issues/159>
- LINBIT/linstor-server issue #540 — <https://github.com/LINBIT/linstor-server/issues/540>
- DRBD commit `27ca01bf67` — "drbd: call bdev_freeze on user suspend-io command"
- DRBD commit `e9d4b48d15` — "drbd: let I/O drain when userspace freezes I/O on a DRBD device"
- DRBD commit `28219cfbcd` — "drbd: make call to bdev_freeze user-controllable"
- DRBD commit `19796a154e49` — "drbd: drain application I/O before committing a cluster-wide resize"
- DRBD commit `147ab386e0` — "drbd: wait for the barrier acks with wait_for_barrier_acks() in suspend-io"
- LINSTOR v1.35.3 release notes — snapshot/suspend and `ExactSize` resize fixes
