# CloudNativePG backup & restore

CNPG native backups use the upstream **Barman Cloud CNPG-I plugin**, installed
once in `cnpg-system`. Backups (weekly full + continuous WAL) go to the
existing Hetzner Object Storage bucket used by Velero.

- Plugin install: `kubernetes/infra/cnpg-system/_base/plugin-*.yaml`
- Reusable backup component: `kubernetes/components/cnpg-backup/`
- First wired database: `keycloak-system` (`cnpg-keycloak`)

## Architecture

| Piece | Location | Notes |
| --- | --- | --- |
| `plugin-barman-cloud` | `cnpg-system` | Must run in the operator namespace; injects a sidecar into DB pods. |
| `ObjectStore` `hetzner` | one per DB namespace | `s3://buijnsters-home-backup/cnpg/`, `fsn1`, retention `30d`, SSE-C encrypted. |
| Secret `cnpg-backup-s3` | one per DB namespace | `ACCESS_KEY_ID` / `ACCESS_SECRET_KEY` (SOPS); reuses the Velero Hetzner key. |
| Secret `cnpg-backup-sse-c` | one per DB namespace | base64-encoded 256-bit SSE-C key (SOPS); **must be backed up outside the repo/cluster**. |
| `ScheduledBackup` `weekly` | one per DB namespace | `0 30 2 * * 0` (Sunday 02:30), `immediate: true`. |
| Cluster `spec.plugins` | each CNPG `Cluster` | `barman-cloud.cloudnative-pg.io`, `isWALArchiver: true`. |

All three (`ObjectStore`, secret, `ScheduledBackup`) plus the `Cluster` plugin
stanza come from the **shared component**, so wiring another database is a
one-line change (add the component to that namespace's Flux `Kustomization`):

```yaml
components:
  - ../../../components/cnpg-backup   # path depth depends on Kustomization.spec.path
```

Per-cluster separation is automatic: Barman writes to
`cnpg/<serverName>/` where `serverName` defaults to the `Cluster` name.

## Scope

Wired today:

- `keycloak-system` → `cnpg-keycloak`

Still to wire (same component):

- `immich` (`cnpg-immich`)
- `harbor-system` (`cnpg-harbor`)
- `kagent` (`cnpg-kagent`)

## Verify

```sh
# plugin + CRDs
kubectl -n cnpg-system get pods | grep barman
kubectl get crd objectstores.barmancloud.cnpg.io

# configured backup resources
kubectl -n keycloak-system get objectstore,scheduledbackup

# first backup (ScheduledBackup has immediate: true)
kubectl -n keycloak-system get backups.postgresql.cnpg.io -w

# cluster conditions / WAL archiving
kubectl -n keycloak-system get cluster cnpg-keycloak -o yaml | \
  grep -iE 'ContinuousArchiving|isWALArchiver|barmanObjectName'
```

An on-demand backup (no `cnpg` kubectl plugin required):

```sh
cat <<'EOF' | kubectl apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: cnpg-keycloak-manual
  namespace: keycloak-system
spec:
  cluster:
    name: cnpg-keycloak
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
EOF
kubectl -n keycloak-system get backup cnpg-keycloak-manual -w
```

## Restore

Restore into a **new** `Cluster` (never over the live one). The source
`ObjectStore` must exist in the same namespace as the restore `Cluster`.

Example (keycloak), kept in a gitignored `tmp/` manifest and deleted after the
test:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: cnpg-keycloak-restore
  namespace: keycloak-system
spec:
  instances: 1
  storage:
    size: 1Gi
    storageClass: ssd-lvm-thin-2
  bootstrap:
    recovery:
      source: origin
  externalClusters:
    - name: origin
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: hetzner
          serverName: cnpg-keycloak
```

```sh
kubectl -n keycloak-system wait --for=condition=Ready cluster/cnpg-keycloak-restore --timeout=15m
kubectl -n keycloak-system exec cnpg-keycloak-restore-1 -c postgres -- \
  psql -U postgres -d app -c '\dt' -c 'select count(*) from realm;'
kubectl -n keycloak-system delete cluster cnpg-keycloak-restore   # cleanup test
```

Notes:

- Do **not** add `spec.plugins` to the restore cluster (it would try to archive
  WAL to the same path).
- For point-in-time recovery, set `bootstrap.recovery.recoveryTarget.targetTime`
  (or a named `targetName`) referencing a backup/WAL timestamp within the
  30-day window.

## Rollback / disable

Remove the `cnpg-backup` component from the namespace's Flux `Kustomization`
and push. Flux prunes the `ObjectStore`/`ScheduledBackup` and stops WAL
archiving; **existing backups remain in Hetzner Object Storage**.

## Gotchas

- `ObjectStore` and its credential Secret are namespaced; the component
  instantiates a copy per database namespace from one source of truth.
- The Hetzner S3 access key is shared with Velero (`kubernetes/infra/velero/_base/s3-credentials.sops.yaml`).
- SSE-C is enabled via `s3Credentials.sseCustomerKey` (Hetzner does not support
  bucket-managed SSE). The key lives in `cnpg-backup-sse-c`; keep a copy outside
  the repo/cluster. Losing it makes the backups unrecoverable. Changing it in
  place breaks existing objects - use a new `destinationPath`/`serverName`.
  SSE-C cannot be combined with `data.encryption`/`wal.encryption`, and restore
  automatically uses the same key.
- When SSE-C was enabled, the previous unencrypted `cnpg/` objects had to be
  deleted first (Barman sends SSE-C headers on read, which Hetzner rejects for
  non-SSE-C objects).
- S3-compatible backends occasionally need
  `AWS_REQUEST_CHECKSUM_CALCULATION=when_required` /
  `AWS_RESPONSE_CHECKSUM_VALIDATION=when_required`; add them under
  `ObjectStore.spec.instanceSidecarConfiguration.env` if uploads fail.
- Adding `spec.plugins` injects the sidecar and triggers one rolling restart of
  the database instance.
