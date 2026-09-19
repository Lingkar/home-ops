# Plan: migrate `talos/` from talhelper to TOPF (Phase 1 — tooling only)

Status: **executed on branch `talos/topf-migration` — STOPPED at Gate G4 for human review (no node applied)**
Repo: `home-ops` (`main` is live, Flux manages only `kubernetes/**`; `talos/**` is applied manually)
Target: `postfinance/topf` **v0.6.0**
Starting point behavior to preserve: **zero cluster change** — this is a pure tooling swap.

## Scope

**In scope (do it):**
- Replace `talhelper` with `topf` v0.6.0 in `.mise.toml`.
- Convert `talos/{talconfig.yaml,talenv.yaml,talsecret.sops.yaml,patches/}` into the TOPF layout:
  `talos/{topf.yaml,secrets.sops.yaml,all/,control-plane/,worker/,node/<host>/}`.
- Rename the secrets bundle `talsecret.sops.yaml` → `secrets.sops.yaml` (byte-identical, keeps cluster identity).
- Rewrite `task` files, `scripts/bootstrap-apps.sh`, `renovate.json`, `AGENTS.md` to match.
- Prove render-equivalence against the last talhelper output, then stop for human review.
  **Do NOT apply to any live node without an explicit approval step (see Gate G4).**

**Out of scope (do NOT do / explicitly deferred):**
- Talos upgrade to v1.14.0 and Kubernetes upgrade to v1.37.0 — deferred to a separate future PR.
  Keep `talos/topf.yaml` at `talosVersion: v1.13.8`, `kubernetesVersion: v1.36.2`.
- The substrate `certificates.k8s.io/v1beta1` `runtime-config` change to the apiServer
  (`talos/patches/controller/cluster.yaml`) — deferred. Do not reintroduce it in this phase.

### Current state (verified before planning)

- Working tree clean, on `main`, 1 commit ahead of origin (`a931405 chore(agents): add AGENTS.md`).
- `talos/talenv.yaml`: `talosVersion: v1.13.8`, `kubernetesVersion: v1.36.2` (running versions).
- `talos/patches/controller/cluster.yaml`: no `runtime-config` line (deferred change absent).
- Cluster: 3 nodes, endpoint `https://192.168.69.5:6443`, VIP `192.168.69.5`.

## Inventory (source of truth)

### Cluster facts (from `talos/talconfig.yaml`)

| host | ip | role | arch | secureboot | install disk | notes |
|---|---|---|---|---|---|---|
| rpi-00 | 192.168.68.252 | worker | arm64 | false | /dev/sda | schematic **overlay** (configTxt, image `siderolabs/sbc-raspberrypi`, name `rpi_generic`); kernelModules `vc4`,`v3d` |
| c-01 | 192.168.68.253 | control-plane | amd64 | true | /dev/sda | nodeLabels `piraeus.io/storage=true`; VIP 192.168.69.5 |
| c-02 | 192.168.68.254 | worker | amd64 | true | /dev/nvme0n1 | nodeLabels `piraeus.io/storage=true` |

Cluster top-level fields:
- `additionalApiServerCertSans` = `[127.0.0.1, 192.168.69.5]`
- `additionalMachineCertSans` = `[127.0.0.1, 192.168.69.5]`
- `clusterPodNets` = `["10.42.0.0/16"]`, `clusterSvcNets` = `["10.43.0.0/16"]`
- `cniConfig.name` = `none` (Cilium)

Per-node network (deviceSelector by MAC, static addr + default route):
- rpi-00: `dc:a6:32:eb:ff:81` → `192.168.68.252/22`, gw `192.168.68.1`
- c-01: `e8:ff:1e:d2:90:ed` → `192.168.68.253/22`, gw `192.168.68.1`, vip `192.168.69.5`
- c-02: `38:05:25:34:67:7e` → `192.168.68.254/22`, gw `192.168.68.1`

Per-node schematics (3 distinct also) come from the `schematic:` block of each node (see
`talos/talconfig.yaml`). They must be reproduced per-node via `schematicId: "@node/<host>/schematic.yaml"`.

### Existing patch files (`talos/patches/`)

- `global/` (all nodes): `machine-files`, `machine-kernel-modules`, `machine-kubelet`,
  `machine-network`, `machine-sysctls`, `machine-time`, `machine-watchdog`
- `controller/` (control-plane only): `admission-controller-patch`, `cluster`
- `{c-01,c-02,rpi-00}/` (per node): `api-server-resources` (c-01 4Gi, c-02 4Gi, rpi-00 1536Mi),
  plus `c-01/{system-disk-ssd,raw-volume-hdd}`, `c-02/{system-disk-ssd-1,raw-volume-ssd-0}`

## STEP 0 — Safety baseline (run first, talhelper still installed)

Capture the live golden set so "no undesired change" is provable:

```bash
# per node
for ip in 192.168.68.252 192.168.68.253 192.168.68.254; do
  talosctl -n $ip version
  talosctl -n $ip get extensions
  talosctl -n $ip get cmdline
  talosctl -n $ip get links
  talosctl -n $ip get addresses
  talosctl -n $ip get routes
done
kubectl get nodes -o wide
kubectl get clustertrustbundles        # ensure still served / unchanged (substrate check)
```

Freeze the talhelper baseline render (oracle for Gate G1). **Do this before removing talhelper.**

```bash
mkdir -p /tmp/tlh-baseline
mise exec -- talhelper genconfig \
  -c talos/talconfig.yaml -e talos/talenv.yaml -s talos/talsecret.sops.yaml \
  -o /tmp/tlh-baseline
```

Record the decrypted secrets bundle hash (Gate G0):

```bash
sha256sum <(sops -d talos/talsecret.sops.yaml)
```

## STEP 1 — Tooling

Edit `.mise.toml`:
- Remove: `"aqua:budimanjojo/talhelper" = "3.1.17"`
- Add: `"github:postfinance/topf" = "0.6.0"`
- Keep: `talosctl` (line `"aqua:siderolabs/talos"`), `sops`, `yq`, all others.
- Add env `TOPFCONFIG = "{{config_root}}/talos/topf.yaml"`.
- Update `TALOSCONFIG` from `.../talos/clusterconfig/talosconfig` to `.../talos/talosconfig`
  (topf writes the talosconfig here; see STEP 7).

```bash
mise install
mise exec -- topf --version   # expect v0.6.0
```

## STEP 2 — Create `talos/topf.yaml`

```yaml
# TOPF cluster configuration (replaces talconfig.yaml + talenv.yaml)
clusterName: kubernetes
clusterEndpoint: https://192.168.69.5:6443
# renovate: datasource=docker depName=ghcr.io/siderolabs/kubelet
kubernetesVersion: v1.36.2
# renovate: datasource=docker depName=ghcr.io/siderolabs/installer
talosVersion: v1.13.8
secretsPath: secrets.sops.yaml
nodes:
  - host: rpi-00
    ip: 192.168.68.252
    role: worker
    secureboot: false
    schematicId: "@node/rpi-00/schematic.yaml"
  - host: c-01
    ip: 192.168.68.253
    role: control-plane
    secureboot: true
    schematicId: "@node/c-01/schematic.yaml"
  - host: c-02
    ip: 192.168.68.254
    role: worker
    secureboot: true
    schematicId: "@node/c-02/schematic.yaml"
```

Note the `# renovate:` annotations (same docker datasource pattern talenv used) — `custom.regex`
in `renovate.json` still matches `*.yaml`, so version bumps keep flowing.

## STEP 3 — Build the patch tree

New layout under `talos/`, replacing `patches/`:

```text
talos/
├── topf.yaml
├── secrets.sops.yaml               # git mv from talsecret.sops.yaml
├── rendered/                       # topf render output — gitignored (contains secrets)
├── all/
│   ├── 00-cluster.yaml             # pod/svc subnets, cni.name none, certSANs
│   ├── 05-hostname.yaml.tpl        # NEW — see below
│   ├── 10-machine-network.yaml     # ← global/machine-network.yaml
│   ├── 11-machine-kubelet.yaml     # ← global/machine-kubelet.yaml
│   ├── 12-machine-sysctls.yaml     # ← global/machine-sysctls.yaml
│   ├── 13-machine-time.yaml        # ← global/machine-time.yaml
│   ├── 14-machine-kernel-modules.yaml  # ← global/machine-kernel-modules.yaml
│   ├── 15-machine-files.yaml       # ← global/machine-files.yaml
│   └── 16-machine-watchdog.yaml    # ← global/machine-watchdog.yaml
├── control-plane/
│   ├── 01-admission-control.yaml   # ← controller/admission-controller-patch.yaml
│   ├── 02-cluster.yaml             # ← controller/cluster.yaml
│   └── 03-api-server-resources.yaml  # 4Gi (c-01's value — matches baseline render)
├── worker/
└── node/
    ├── rpi-00/
    │   ├── 01-install.yaml          # install.disk /dev/sda
    │   ├── 02-network.yaml          # MAC/addr/route
    │   ├── 03-kernel-modules.yaml   # vc4, v3d
    │   ├── 04-api-server-resources.yaml  # 1536Mi (reproduce exactly for baseline)
    │   └── schematic.yaml           # overlay + extensions from talconfig
    ├── c-01/
    │   ├── 01-install.yaml          # install.disk /dev/sda
    │   ├── 02-network.yaml          # MAC/addr/route + vip 192.168.69.5
    │   ├── 03-node-labels.yaml      # piraeus.io/storage=true
    │   ├── 04-system-disk-ssd.yaml  # ← c-01/system-disk-ssd.yaml
    │   ├── 05-raw-volume-hdd.yaml   # ← c-01/raw-volume-hdd.yaml
    │   └── schematic.yaml
    └── c-02/
        ├── 01-install.yaml          # install.disk /dev/nvme0n1
        ├── 02-network.yaml          # MAC/addr/route
        ├── 03-node-labels.yaml      # piraeus.io/storage=true
        ├── 04-system-disk-ssd-1.yaml  # ← c-02/system-disk-ssd-1.yaml
        ├── 05-raw-volume-ssd-0.yaml   # ← c-02/raw-volume-ssd-0.yaml
        └── schematic.yaml
```

Guidelines:
- Patch content copies the existing files verbatim (they are already strategic-merge patches).
- New synthesized files must match what talhelper rendered, **not** an idealized version.
  Zero-diff is the goal; refactor later.
- `all/00-cluster.yaml`:
  ```yaml
  cluster:
    network:
      dnsDomain: cluster.local
      podSubnets: ["10.42.0.0/16"]
      serviceSubnets: ["10.43.0.0/16"]
      cni:
        name: none
    apiServer:
      certSANs:
        - 127.0.0.1
        - 192.168.69.5
  machine:
    certSANs:
      - 127.0.0.1
      - 192.168.69.5
  ```
- `all/05-hostname.yaml.tpl` (must match talhelper's emitted form at 1.13.x; verify against the
  baseline before deciding between the two):
  ```yaml
  machine:
    network:
      hostname: {{ .Node.Host }}
  ```
  If the baseline contains a `HostnameConfig` document instead, use:
  ```yaml
  apiVersion: v1alpha1
  kind: HostnameConfig
  auto: "off"
  hostname: {{ .Node.Host }}
  ```
- Per-node `schematic.yaml` files mirror the `customization:` block from `talconfig.yaml`
  (`extraKernelArgs` / `systemExtensions`, plus `overlay:` for rpi-00).

## STEP 4 — Secrets

```bash
git mv talos/talsecret.sops.yaml talos/secrets.sops.yaml
rm talos/talenv.yaml
rm -rf talos/clusterconfig            # untracked leftover
```

`topf.yaml` already sets `secretsPath: secrets.sops.yaml`. `.sops.yaml` rule
`talos/.*\.sops\.ya?ml` still matches (fully-encrypted), so `sops`/pre-commit keep working.

## STEP 5 — Task files

`.taskfiles/talos/Taskfile.yaml` — replace talhelper commands:

| old task | new command |
|---|---|
| `generate-config` | `topf render -o {{.TALOS_DIR}}/rendered` |
| `apply-node IP=` | `apply-node HOST=` → `topf apply --nodes-filter '^{{.HOST}}$'` |
| `upgrade-node IP=` | `upgrade-node HOST=` → `topf upgrade --nodes-filter '^{{.HOST}}$'` |
| `upgrade-k8s` | keep `talosctl upgrade-k8s` (topf does not do K8s upgrades) |
| `reset` | `topf reset` |

Add: `talos:talosconfig` → `mkdir -p {{.TALOS_DIR}} && topf talosconfig > {{.TALOS_DIR}}/talosconfig`.

Root `Taskfile.yaml` vars: drop `TALOSCONFIGYAML/TALOSCONFIGENV/TALOSCONFIGSECRET/TALOS_DIR_OUT`;
add `TOPFCONFIG: "{{.ROOT_DIR}}/talos/topf.yaml"`; point `TALOSCONFIG` at
`{{.SECRETS_DIR}}/talos/talosconfig`. Update `env:` block with `TOPFCONFIG`.

`.taskfiles/bootstrap/Taskfile.yaml` `bootstrap:talos`:
- `[ -f secrets.sops.yaml ] || (talosctl gen secrets -o /tmp/secrets.tmp.yaml && sops --filename-override talos/secrets.sops.yaml --encrypt /tmp/secrets.tmp.yaml > secrets.sops.yaml && rm -f /tmp/secrets.tmp.yaml)` (verify `talosctl gen secrets` output semantics before finalizing)
- `topf apply --auto-bootstrap`
- `until topf kubeconfig > {{.ROOT_DIR}}/kubeconfig; do sleep 10; done`
- precondition `which topf talosctl sops` (drop `talhelper`).

## STEP 6 — Ancillary references

- `scripts/bootstrap-apps.sh` (line ~325): replace `talhelper` in the `check_cli ...` list with
  `topf`.
- `renovate.json` (rule "Disable digest pinning for talenv", ~line 56): change
  `matchFileNames: ["talos/talenv.yaml"]` → `["talos/topf.yaml"]`.
- `AGENTS.md`: update the tool list (line ~7), the talos layout/upgrade descriptions (lines ~33,
  39–41) to the TOPF layout and `task talos:render` / `apply-node HOST=…` flow.
- `.gitignore`: add `talos/rendered/`.
- Delete `talos/patches/README.md` (superseded) and the `talos/patches/` tree (moved in STEP 3);
  optionally add a short `talos/README.md` describing the topf layout.
- `.mise.toml` `[env]` TALOSCONFIG + TOPFCONFIG (see STEP 1).

## STEP 7 — talosconfig

```bash
mise exec -- topf --topfconfig talos/topf.yaml talosconfig > ../home-ops-secrets/talos/talosconfig
export TALOSCONFIG=$(pwd)/../home-ops-secrets/talos/talosconfig
talosctl version   # sanity
```

## GATES — must all pass (executing agent stops here for human review)

**G0 — secret identity.** Decrypted hash before vs after rename must match:
```bash
sha256sum <(sops -d talos/talsecret.sops.yaml)   # pre-recorded in STEP 0
sha256sum <(sops -d talos/secrets.sops.yaml)     # now
# identical required — a mismatch means CA rotation; STOP.
```

**G1 — offline render equivalence.** talhelper baseline vs topf render, per node:
```bash
mise exec -- topf render --online -o /tmp/topf-out
for h in rpi-00 c-01 c-02; do
  diff -u <(yq -P '.' /tmp/tlh-baseline/kubernetes-$h.yaml) \
          <(yq -P '.' /tmp/topf-out/$h.yaml)
done
```
Acceptable differences ONLY: multi-document ordering, trailing comments/quoting. Any other hunk
fails the gate — fix the patch tree, do not proceed.

**G2 — schematic IDs.**
```bash
mise exec -- topf schematic-ids
```
must equal `machine.install.image` schematic hashes from the baseline (esp. rpi-00 overlay).

**G3 — schema validation.**
```bash
for f in /tmp/topf-out/*.yaml; do talosctl validate --config "$f" --mode metal; done
```

**G4 — stop.** Do NOT run `topf apply` or `topf upgrade`. Present the G1 diff to the human with
an explanation of every hunk. Application is a separate, human-gated roll-out (later: dry-run per
node, then rpi-00 → c-02 → c-01, then post-apply checks). Record this decision point in the plan
when returning control.

## Rollback

Config-only change: re-apply the baseline at any time with
`talosctl apply-config -n <ip> -f /tmp/tlh-baseline/<node>.yaml`. Secrets bundle unchanged means
the cluster CA never moves. Keep talhelper files on the branch until G4 review is complete.

## Definition of done

1. `.mise.toml` uses topf v0.6.0; talhelper absent.
2. `talos/topf.yaml` + patch tree present; `rendered/` gitignored.
3. `talos/secrets.sops.yaml` (renamed) + `talos/{talconfig,talenv,talsecret,clusterconfig}` gone.
4. Tasks, bootstrap, tools-check, renovate, AGENTS.md, gitignore updated consistently.
5. Gates G0–G3 pass (with G1 hunks all explained).
6. G4 handed back to the human: no node applied, Talos 1.14 and the substrate `runtime-config`
   change still deferred per plan.

## Phase 1 execution record (2026-09-19, branch `talos/topf-migration`)

All in-scope steps completed. No node was applied. Deviations from the original plan, all made
to preserve the zero-diff goal or to match actual TOPF v0.6.0 behaviour:

1. **Schematics moved to `talos/schematics/<host>.yaml`** (referenced as
   `schematicId: "@schematics/<host>.yaml"`) instead of `talos/node/<host>/schematic.yaml`.
   TOPF scans every file under the patch dirs and tried to parse `node/<host>/schematic.yaml`
   as a patch (`missing kind`). `schematics/` is outside the scanned tree.
2. **Network config expressed as Talos split documents** (`LinkAliasConfig`, `LinkConfig`,
   `Layer2VIPConfig`) copied verbatim from the talhelper render. TOPF does not convert
   `machine.network.interfaces` into the split documents, which would otherwise show up as a
   real G1 hunk. This also reproduces the live/persisted config exactly.
3. **`cluster.apiServer.certSANs` moved from `all/00-cluster.yaml` to `control-plane/02-cluster.yaml`**
   to match the baseline (worker configs have no `cluster.apiServer` section).
4. **Added `control-plane/04-remove-external-lb-exclusion.yaml`** using
   `$patch: delete` on `node.kubernetes.io/exclude-from-external-load-balancers`. The
   `talosctl`-generated base config adds this control-plane label, talhelper stripped it, and
   live `c-01` does not have it — so it must be deleted to avoid a cluster change.
5. **rpi-00 kernel-module ordering** kept via host-guarded
   `all/09-kernel-modules-rpi-00.yaml.tpl` (TOPF appends `node/` patches after `all/`; the
   `$patch: replace` directive is not accepted by the Talos decoder). Result matches the
   baseline `vc4, v3d, drbd, ...` order.
6. **Both worker `api-server-resources` patches dropped** (orphan `rpi-00/`, no-op `c-02/`),
   as agreed — baseline is unchanged.
7. **`TALOS_DIR` is now the repo `talos/` dir** (was the secrets dir). `bootstrap:talos` writes
   the kubeconfig to `{{.KUBECONFIG}}` (secrets dir) because the repo-root `kubeconfig/` is a
   directory. `upgrade-k8s` now runs `talosctl upgrade-k8s --to <version>` reading `topf.yaml`.

Gate results:

- **G0 — PASS**: decrypted `secrets.sops.yaml` SHA256 identical
  (`e752e6cf…f65670`), so the cluster CA/identity is unchanged.
- **G1 — PASS**: the only differences are the reordering of the `WatchdogTimerConfig`
  document (TOPF emits it near the front; talhelper near the end). 6 added / 6 removed lines
  per node, nothing else. Full diffs: `/tmp/opencode/g1/<host>.diff`.
- **G2 — PASS**: `topf schematic-ids` returns the exact IDs from the baseline
  (`439640583…` rpi-00, `36c61f40e…` c-01, `766a5dc73…` c-02).
- **G3 — PASS**: `talosctl validate --mode metal` reports valid for all three; only the
  pre-existing `.machine.files is deprecated` warning.
- **G4 — PENDING HUMAN APPROVAL**: `topf apply` / `topf upgrade` were **not** run.

### G4 handback

Apply is a separate, human-gated roll-out. Suggested order once approved:
`topf apply --dry-run` per node (expect only the `WatchdogTimerConfig` document reordering),
then `rpi-00` → `c-02` → `c-01`, then the post-apply checks from STEP 0.
Rollback remains `talosctl apply-config -n <ip> -f /tmp/tlh-baseline/<node>.yaml`, or the
old `talhelper` config on `main`.
