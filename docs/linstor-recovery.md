# LINSTOR runtime recovery (satellite offline, quorum loss, stuck volumes)

Practical runbook for the failure modes hit on 2026-10-19 when the `c-01`
satellite went `OFFLINE` and never reconnected. Covers:

1. satellite pod `Running` but LINSTOR node `OFFLINE` / controller holds a stale connection
2. `VolumeWithoutQuorum` force-demotion + disks stuck `Outdated`
3. `drbdadm down all` blocked by a stale kubelet mount
4. verification checklist

See also:
- `docs/linstor-orphan-cleanup.md` - deleting orphaned resource definitions / kernel leftovers
- `docs/linstor-snapshot-gc.md` - snapshot garbage collection
- `docs/control-plane-shutdown.md` - `drbdadm down` before shutdown

## Helpers

```sh
LS() { kubectl -n piraeus-datastore exec deploy/linstor-controller -- linstor --no-pager "$@"; }

# Run a command inside the satellite container for a node (pod names have random suffixes).
sat() {
  node=$1; shift
  pod=$(kubectl -n piraeus-datastore get pods -l app.kubernetes.io/component=linstor-satellite \
    -o wide --no-headers | awk -v n="$node" '$7==n{print $1}')
  kubectl -n piraeus-datastore exec "$pod" -c linstor-satellite -- "$@"
}
```

Nodes: `c-01` (control-plane + storage), `c-02` (storage), `rpi-00` (no storage
pool, only diskless tiebreaker replicas). Each node has its own operator-managed
satellite DaemonSet (`linstor-satellite.<node>`).

## 1. Satellite `Running` but node `OFFLINE`

Symptoms:

- `LS node list` shows `OFFLINE` and an **empty `Platform`** column (healthy
  nodes show `LINUX`).
- `linstor-csi-node-*` on that node is stuck `Init:0/1` (init container
  `linstor-wait-until satellite-online <node>` never exits).
- LINSTOR resources on that node show `Unknown`.
- The satellite pod is `2/2 Running` and listening on `3366`, but the controller
  has no live connection.

Diagnose:

```sh
LS node list

# controller's satellite sockets (look for the node's current pod IP)
kubectl -n piraeus-datastore exec deploy/linstor-controller -- \
  sh -c 'ss -tnp | grep -E ":3366"'

# controller view: stale CLOSE-WAIT/LAST-ACK to an OLD pod IP while the
# satellite pod now has a new IP means the controller never re-handshaked
kubectl -n piraeus-datastore logs deploy/linstor-controller --tail=300 | \
  grep -iE "Establishing connection|authenticated|ONLINE|OFFLINE|PeerClosing"
```

Fix (low risk, no data path change):

```sh
LS node reconnect c-01
```

Healthy reconnect log sequence:

```text
Establishing connection to node 'c-01' ...
Sending authentication to satellite 'c-01'
Changing connection state of node 'c-01' from OFFLINE -> CONNECTED
Satellite 'c-01' authenticated
Sending full sync to Node: 'c-01'
Changing connection state of node 'c-01' from CONNECTED -> ONLINE
```

If it does not reconnect, restart the controller (single replica; DRBD data path
keeps running, only the LINSTOR control API blips):

```sh
kubectl -n piraeus-datastore rollout restart deploy/linstor-controller
```

Note: `reconnect` triggers a **full sync** of every resource to the satellite.
Expect the satellite to churn `DeviceManager cycle N` and briefly spike CPU.
Do not reconnect while another node is already down (see section 2).

## 2. Quorum loss -> `VolumeWithoutQuorum` force-demotion

Most 3-replica resources use `DrbdOptions/Resource/quorum: majority` (2 of 3).
Replicas are usually 2 diskful (`c-01`, `c-02`) + 1 diskless tiebreaker
(`rpi-00`). If **two** nodes are unavailable at the same time - even for a few
seconds during a reconnect - quorum is lost and the `linstor-affinity-controller`
forces the volume down:

```text
Warning VolumeWithoutQuorum pod/garage-0: Pod was evicted because attached volume lost quorum
Warning VolumeWithoutQuorum pvc/...: Volume is forcefully demoted as there are Pods stuck terminating
```

Result: both diskful replicas can end up `Outdated`; the pod is evicted and
cannot remount (`NodePublishVolume failed ... failed to set source device
readwrite`).

Rules to avoid it:

- Make sure **all other nodes are `Online`** before `node reconnect` / controller
  restart. Watch `rpi-00`: it was the node that blipped and dropped quorum.
- Reconnect one node at a time and re-check `LS node list` between nodes.
- Do not reboot/drain two storage nodes together.

## 3. All diskful replicas `Outdated` (no UpToDate source)

Symptoms:

```sh
LS resource list -r <pvc-...>      # Outdated on all diskful replicas
sat c-02 drbdadm status <pvc-...>  # disk:Outdated, peer-disk:Outdated, WFBitMapS
```

This is a DRBD split-brain/generation mismatch. LINSTOR will not pick a source
automatically; you must choose the replica that has the newest data (typically
the node that was serving the pod, and/or was taking snapshots last).

### 3.1 Find the backing LVM thin volume (on the source node)

```sh
sat c-02 sh -c 'lvs -o lv_name,vg_name,lv_size,lv_attr,pool_lv --noheadings | grep <res-uuid>'
# e.g. pvc-<uuid>_00000  vg1  <20.01g  Vwi-aotz--  thin
```

### 3.2 Take a safety snapshot (thin LVs only)

```sh
sat c-02 lvcreate -s -n <lv>_presplit vg1/<lv>
sat c-02 sh -c 'lvs -o lv_name,lv_attr,pool_lv --noheadings | grep presplit'
```

Existing LINSTOR/Velero snapshots (`..._snapshot-<uuid>`) can also be used as a
fallback. Check `LS snapshot list` and `velero backup get`.

### 3.3 Promote the source and resolve the mismatch

```sh
# On the node that has the newest data (here c-02):
sat c-02 drbdadm primary --force <pvc-...>

# Check both sides:
sat c-02 drbdadm status <pvc-...>
sat c-01 drbdadm status <pvc-...>
```

In the 2026-10-19 recovery, `primary --force` alone made **both** disks
`UpToDate`/`Consistent` and no data had to be discarded.

If `WFBitMapS` persists and the out-of-sync backlog keeps growing while the
resource is `Primary`, the bitmap sync is stuck (LINSTOR may still report
`UpToDate`). Kick it from the **Secondary**:

```sh
sat c-01 drbdadm disconnect <pvc-...>
sat c-01 drbdadm connect <pvc-...>
sat c-02 drbdadm status <pvc-...>   # expect peer-disk:UpToDate, no replication: line
```

The Grafana "out-of-sync" panel is `drbd_peerdevice_outofsync_bytes > 0`. A
**constant** non-zero value while `replication:Established` and
`peer-disk:UpToDate` (e.g. 48 KiB on the Garage meta volume) is a stale bitmap
residual, not an active resync. It is safe to ignore; `drbdadm verify <pvc-...>`
(online verify) can reconcile/clear it if you want the panel at zero.

Only if the other side stays divergent (`Outdated`/`Inconsistent`) and will not
resync, discard the **loser's** data - never the source:

```sh
# DESTRUCTIVE: discards that node's local copy, then resyncs from the source.
sat c-01 drbdadm disconnect <pvc-...>
sat c-01 drbdadm connect --discard-my-data <pvc-...>
```

### 3.4 Verify and clean up

```sh
LS resource list -r <pvc-...>      # expect UpToDate on the source, InUse when pod mounts
kubectl -n <ns> get pods           # app pod should mount and start
# once satisfied, remove the temporary snapshot:
sat c-02 lvremove vg1/<lv>_presplit
```

## 4. `drbdadm down all` fails: "Device is held open by someone"

Example:

```text
pvc-...: State change failed: (-12) Device is held open by someone
/dev/drbdNNNN open_cnt:1, writable:1
opened by init ... / opened by mount ...
```

Cause: a pod was evicted (drain) but its kubelet bind mount under
`/var/lib/kubelet/pods/<pod-uid>/volumes/kubernetes.io~csi/<pv>/mount` was never
unmounted, because the CSI node plugin on that node was stuck (`satellite-online`
init) and could not run `NodeUnpublish`/`NodeUnstage`.

Diagnose from the host:

```sh
talosctl --nodes <node-ip> read /proc/mounts | grep drbd
# shows: /dev/drbdNNNN /var/lib/kubelet/pods/<uid>/volumes/kubernetes.io~csi/<pv>/mount ...
```

Why you cannot just `umount` from the satellite pod:

- The satellite pod is privileged but has **no host mount/PID namespace**
  (`hostPID=false`, only `hostIPC=true`), so the host mount is invisible to it.
- Talos' host root has **no `umount`, `nsenter`, `sh`, or `cat`**. From a
  `hostPID` helper, `nsenter -t 1 -m` resets root to the Talos root, so there is
  no userspace binary to execute.

Options:

1. **Reboot the node** - the kernel tears the mount down on shutdown. Safe for a
   single-replica volume (no peers to resync); expect a possible `fsck` on next
   mount if the journal was aborted.
2. If the volume is single-replica and the node is going down anyway, skipping
   `drbdadm down` for it is acceptable - the backing zvol/LV keeps the data.
3. Do not use `drbdsetup down --force` while it is still mounted; it can corrupt
   the filesystem.

Prevention: make sure `linstor-csi-node` is healthy (not stuck in `Init`) before
draining a node, so mounts are released cleanly.

## 5. Verification checklist

```sh
LS node list                  # all 3 Online, Platform=LINUX
LS resource list              # expect only UpToDate / Diskless, no Outdated/Unknown/Connecting
kubectl -n piraeus-datastore get pods | grep -E 'satellite|csi-node'
kubectl get pods -A | grep -vE 'Running|Completed'   # only known-unrelated failures
kubectl get nodes              # all Ready, not SchedulingDisabled
kubectl get events -A | grep -i VolumeWithoutQuorum  # should be old only
```

A healthy cluster shows, per resource, `c-01` and `c-02` `UpToDate` and
`rpi-00` `Diskless` (unless a volume is single-replica on a specific pool).

## 6. Kernel-wedged DRBD - forced reboot / physical power cycle

This is the escalation when the DRBD kernel state itself is stuck. A satellite
restart or `drbdadm` will not help; the tasks are in uninterruptible `D` state.

Symptoms:

- `drbdadm status` shows resources `suspended:quorum` / `blocked:upper`.
- `drbdadm down <res>` and `conn`/`disconnect` **hang**; connections are stuck in
  `Disconnecting`.
- `drbdsetup del-peer` / `forget-peer` / `suspend-io` processes are stuck in
  `D` state (some may be days old).
- LVM operations (`lvcreate -s`, `lvs`) hang on the thin-pool lock.
- Postgres (or other) processes are in `D` state (blocked I/O), and pods can be
  stuck `Terminating` with `KillPodSandbox ... DeadlineExceeded`.
- The node may still answer ping and even expose kubelet (`:10250`) and
  node-exporter (`:9100`), while the **Talos API (`:50000`) is refused**.

Confirm whether the node actually rebooted:

```sh
# node-exporter may still be reachable even when apid is not
curl -s http://<node-ip>:9100/metrics | grep node_boot_time_seconds
talosctl --nodes <node-ip> read /proc/uptime   # fails while apid is down
kubectl get node <node> -o jsonpath='{.status.nodeInfo.bootID}{"\n"}'
talosctl --nodes <node-ip> service kubelet
```

If the boot time is old, the node did not reboot. It is hung in the kernel
restart path (`kernel_restart` -> `device_shutdown`), and a **physical power
cycle** is required.

### Pre-reboot checklist

1. **Move the LINSTOR control plane off the node** so it stays available:
   ```sh
   kubectl -n piraeus-datastore delete pod \
     -l app.kubernetes.io/component=linstor-controller \
     -l app.kubernetes.io/component=linstor-csi-controller \
     -l app.kubernetes.io/component=linstor-affinity-controller
   ```
   (or delete the specific pods). Cordon the target node first so the new pods
   schedule on the healthy node. The controller/csi-controller are Deployments
   with no PVC, so this is safe.
2. **Cordon** the target node.
3. **Protect volumes whose only UpToDate replica is on the node** (e.g. a
   single-replica PVC on that node). Take an LVM thin snapshot if LVM responds:
   ```sh
   lvcreate -s -n <lv>_prereboot vg1/<lv>
   ```
   If `lvcreate` hangs, skip it - the LV data persists across a reboot; ext4
   journal replay / fsck may be needed.
4. Do **not** run `drbdadm down all` - it will hang on the same resources.

### Reboot

```sh
talosctl --nodes <node-ip> reboot --mode force --wait=false
```

Talos `--mode force` skips `StopAllPods` and the pre-shutdown/unmount phases
(which is what hangs). Note it still calls the kernel restart, which can hang in
`device_shutdown` on the wedged DRBD/LVM devices. If the node stays pingable
with `:50000` refused and the boot time unchanged, **power-cycle it physically**.
After power-on, wait for `:50000`/kubelet and confirm a new `bootID`/`uptime`.

### Post-reboot

- LINSTOR re-creates resources on the returning node; watch the state counts
  until there is no `Unknown`/`DELETING`:
  ```sh
  LS resource list | ...   # expect only UpToDate / Diskless, maybe a temporary SyncTarget
  ```
  Volumes whose other replica was behind resync automatically (e.g. Garage's
  c-01 replica from c-02). Do not uncordon until resources are healthy.
- Uncordon the node, then verify workloads. App pods may crash-loop until their
  dependencies are up (e.g. Immich until its CNPG DB is ready).
- Check the thin pool and snapshots: `lvs -o lv_name,data_percent,metadata_percent vg1/thin`.
- Remove the `_prereboot` snapshot after validating the volume.

### Lessons / prevention

- **Never reconnect or reboot a node while another node is already offline.**
  Most resources use `DrbdOptions/Resource/quorum: majority`; two unavailable
  nodes drop quorum, force-demote the volume, and the affinity controller evicts
  pods (`VolumeWithoutQuorum`).
- **Large data-mover backups can wedge the node.** With
  `snapshotMoveData: true`, Velero/Kopia reads the whole PVC and uploads it. A
  100 Gi PVC (Immich library) turned a ~10 min backup into ~2 h, saturated the
  network, caused DRBD `PingAck did not arrive in time` / `NetworkFailure`, and
  left stuck `drbdsetup`/LVM operations and leaked data-mover temp PVs.
  Exclude large PVCs from Velero (`velero.io/exclude-from-backup: "true"` on the
  PVC) or back them up via a separate, throttled path.
- **Check for leaked data-mover temp volumes** after failed backups:
  ```sh
  kubectl get pv | awk '$5=="Released"'
  LS resource list | grep DELETING
  ```
- The Grafana "out-of-sync" panel uses `drbd_peerdevice_outofsync_bytes`; a
  constant non-zero value with `replication:Established` / `peer-disk:UpToDate`
  is a stale bitmap residual (see section 3).

### Case study - 2026-10-21 (Immich backup -> wedged c-02)

- 02:15-04:16 UTC remote daily backup uploaded the 100 Gi Immich library
  (`snapshotMoveData: true`). DRBD `NetworkFailure` appeared on c-01/c-02 at
  03:22.
- From then on the 4-hourly local CSI backups failed 33/72 volumes with
  `DeadlineExceeded`; 5 resources were stuck `DELETING` and 6 data-mover temp
  PVs (`Released`, including a 100 Gi one) leaked.
- `linstor node reconnect`/targeted `drbdadm` could not clear it: `drbdsetup`
  processes were stuck in `D` state since 03:22 and a `suspend-io 1018` from
  04:00 blocked I/O (postgres in `D` state).
- Controllers were moved to c-01, c-02 cordoned, a `_prereboot` LVM snapshot of
  Garage taken, then `reboot --mode force`. The kernel restart hung in
  `device_shutdown`; a **physical power cycle** was required.
- After boot: all satellites Online, resources reconciled to 94 `UpToDate` /
  46 `Diskless`, Garage's c-01 replica resynced from c-02, and the leaked
  `DELETING` resources/PVs were cleared by the reboot.
- Mitigation applied: `immich-library` PVC got
  `velero.io/exclude-from-backup: "true"` (see `docs/immich-rollout.md`).

## 7. Stale diskless tiebreaker UUID (one resource stuck `Connecting`)

After a reboot/resync, a diskless tiebreaker (usually `rpi-00`) can keep the old
DRBD UUID while the diskful pair has a new current UUID. LINSTOR shows the
resource as `UpToDate`/`Diskless`, but the connection column is
`Connecting(...)` on the tiebreaker, and the kernel log on that node says:

```text
Current UUID of peer does not match my exposed UUID.
...: Declined by peer rpi-00 (id: 2), see the kernel log there
```

Fix (safe - the diskless node has no data):

```sh
sat rpi-00 drbdadm disconnect <pvc-...>
sat rpi-00 drbdadm down <pvc-...>
sat rpi-00 drbdadm up <pvc-...>       # LINSTOR may not auto-recreate after a manual down
sat rpi-00 drbdadm status <pvc-...>   # expect both peers Connected / peer-disk UpToDate
```

`connect --discard-my-data` alone may not clear it: the stale UUID lives in the
in-memory diskless resource, and only `down`/`up` recreates it with the current
UUID. Only do this on `rpi-00` (or another diskless replica) - never on a
diskful replica without checking the data/peers.
