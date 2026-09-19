# Talos (TOPF)

Cluster machine configuration is managed with [TOPF](https://postfinance.github.io/topf/).
`topf.yaml` and `secrets.sops.yaml` are not applied by Flux; they are used manually via
the `task talos:*` tasks.

## Layout

- `topf.yaml` — cluster name/endpoint, versions (renovate-managed), node list, and
  per-node `schematicId: "@schematics/<host>.yaml"` references.
- `secrets.sops.yaml` — SOPS-encrypted Talos secrets bundle (cluster identity; never rotate
  by hand). Renamed from talhelper's `talsecret.sops.yaml`.
- `all/` — patches applied to every node.
- `control-plane/` — patches applied only to control-plane nodes.
- `worker/` — patches applied only to worker nodes.
- `node/<host>/` — per-node patches (`install.disk`, network, labels, volumes, ...).
- `schematics/` — Talos image-factory schematic definitions referenced by `schematicId`.
- `rendered/` — `topf render` output (gitignored; contains plaintext secrets).

Patch files are strategic-merge patches applied in `all/` → `<role>/` → `node/<host>/`
order, lexicographically within each directory. `.yaml.tpl` files are Go templates with
access to `.Node.Host`, `.Node.Role`, `.Node.IP`, `.Data`, and sprig functions.
Schematic files must **not** live under the patch directories, or TOPF will try to load
them as patches.

## Commands

- `task talos:render` — render all nodes to `talos/rendered/` (inspect before applying).
- `task talos:apply-node HOST=<host>` — generate + apply to one node (`MODE=` optional).
- `task talos:upgrade-node HOST=<host>` — upgrade Talos on one node.
- `task talos:upgrade-k8s` — upgrade Kubernetes (still `talosctl`).
- `task talos:talosconfig` — write the client config to `../home-ops-secrets/talos/talosconfig`.
- `task talos:reset` — reset nodes to maintenance mode.

## Upgrades

Bump `talosVersion` / `kubernetesVersion` in `topf.yaml` (Renovate does this), then
`task talos:render`, then apply per node and `task talos:upgrade-k8s`.
