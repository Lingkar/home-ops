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
