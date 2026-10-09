# Immich — implementation plan

Status: **approved with change (LAN-only `internal` gateway) — implementation committed**,
pending secret encryption/fill by the user before push. Tracks `logs.md` TODO "Set-up Immich".

Goal: run Immich (photo/video backup, https://immich.app) on the cluster using the
official community chart `oci://ghcr.io/immich-app/immich-charts/immich`, wired into the
existing Flux/Flux-instance GitOps layout exactly like the existing apps
(ntfy, zigbee2mqtt, phela patterns).

## 1. Current state (what the plan builds on)

| Capability            | Status in cluster                                                                                       |
| --------------------- | ------------------------------------------------------------------------------------------------------- |
| Postgres operator     | CloudNativePG installed (`infra/cnpg-system`, chart `cloudnative-pg` 0.29.0 ≈ operator ≥ 1.29) |
| Ingress/Gateway       | Cilium Gateway API: Gateways `internal` (192.168.69.7) / `external` (192.168.69.8) in ns `network`, wildcard `*.${SECRET_DOMAIN}` listener accepting routes from all namespaces, wildcard LE cert `${SECRET_DOMAIN/./-}-production-tls` |
| External access       | Cloudflare tunnel + `cloudflare-dns` already route `*.${SECRET_DOMAIN}` → external gateway (192.168.69.8) — mobile apps work out of the box |
| Storage               | LINSTOR SCs: `ssd-lvm-thin-1/-2` (SSD), `hdd-raidz-thin-1` (capacity pool, Retain)                      |
| Metrics               | kube-prometheus-stack with `serviceMonitorSelectorNilUsesHelmValues: false` → any ServiceMonitor is scraped |
| Backup                | Velero snapshots to cloud; CNPG barman-cloud plugin still an open TODO (`logs.md`)                       |
| netpol                | rollout in progress; app netpols are written but **commented out** in `_base/kustomization.yaml` (see zigbee2mqtt) |

## 2. Chart facts (verified 2026-10-09 against immich-app/immich-charts@main)

- HTTP helm repo is gone; chart is **OCI-only**: `oci://ghcr.io/immich-app/immich-charts/immich`
  → use an `OCIRepository` + `HelmRelease.spec.chartRef` (pattern already used for cnpg / piraeus).
- Latest chart: **0.13.4** (appVersion `v3.2.0`, bjw-s common-library 5.2.1).
- Chart **does not manage the library PVC**: a PVC must exist and be wired via
  `immich.persistence.library.existingClaim` (hard `fail` in template `checks.yaml`).
- Redis: bundled **valkey** subchart (`valkey.enabled: true`); default env
  `REDIS_HOSTNAME=<release>-valkey` already points at it.
- Postgres: deploy yourself with the **vectorchord (vchord)** extension (depends on
  pgvector); upstream recommends CNPG. Upstream examples: `local/cloudnative-pg.yaml`
  + `local/cloudnative-pg-database.yaml` (PG 18 + vchord injected via image reference,
  `shared_preload_libraries: [vchord.so]`, `Database` CR with declarative
  `extensions: [vector, vchord, earthdistance, cube]`).
- `image.tag` must be set explicitly (chart doesn't auto-track Immich releases).
- Chart is cosign-signed keyless (`--certificate-identity-regexp
  '^https://github\.com/immich-app/immich-charts/\.github/workflows/release\.yaml@refs/tags/immich-'`).
  Flux `OCIRepository.spec.verify` only supports static cosign public keys, not keyless OIDC
  → verify chart signatures out-of-band at review time; optional: add a Fulcio-pinned
  `verify` block later.

## 3. Architecture decisions

| Topic              | Decision                                                                 | Rationale / alternatives |
| -------------------- | ------------------------------------------------------------------------ | ------------------------ |
| App home             | `kubernetes/apps/immich/_base/` + `kubernetes/clusters/home/apps/immich.yaml`, namespace `immich` | standard repo pattern |
| Chart source         | `OCIRepository` (tag `0.13.4`) + `chartRef` HelmRelease                    | only option; mirrors `infra/cnpg-system/_base/source.yaml` |
| Postgres             | CNPG `Cluster` `cnpg-immich` (1 inst) **in the app namespace**, image `ghcr.io/cloudnative-pg/postgresql:18.6-standard-trixie`, vchord injected via `spec.extensions` + `Database` CR declaratively installing `vector, vchord, earthdistance, cube` | mirrors harbor/keycloak DB pattern (operator already live); upstream-provided manifests. Alternative: dedicated DB namespace — not used by any current app, skip |
| DB credentials       | CNPG-managed app secret `cnpg-immich-app` (`password` key) + literal host/port/dbname | same as keycloak/harbor; no sops needed for DB |
| JWT secret           | `secrets.sops.yaml` → Secret `immich-secrets`, key `JWT_SECRET` (openssl rand -hex 32) | repo convention for literal secrets (ntfy `auth.sops.yaml`) |
| Redis                | bundled valkey (`valkey.enabled: true`), chart-default emptyDir persistence | self-contained, service `immich-valkey` matches default env. A valkey operator is a separate open TODO (`logs.md`); revisit later |
| Machine learning     | keep `machine-learning.enabled: true` (default), CPU inference, cache = chart-default emptyDir | arm64/amd64 both supported; GPU ML later as an experiment alongside the existing GPU-sharing setup |
| Library storage      | `pvc-library.yaml`: PVC `immich-library` on **`hdd-raidz-thin-1`**, RWO, start **100Gi** | capacity pool for photo/video data; expansion allowed (`allowVolumeExpansion: true`). RWO is fine at 1 server replica. Tunable — see open questions |
| DB storage           | 8Gi on `ssd-lvm-thin-2`                                                  | immich docs: DB typically 1–3 GB, wants SSD |
| Exposed hostname     | `immich.${SECRET_DOMAIN}` via HTTPRoute on **`internal`** Gateway (192.168.69.7, port 2283) | review decision: LAN-only. Wildcard listener on the internal Gateway accepts routes from all namespaces. WAN/mobile access is NOT via the Cloudflare tunnel (it targets the external gateway); defer to netbird/VPN later |
| Chart ingress        | leave `server.ingress.enabled=false`; HTTPRoute owned by this repo       | repo owns routing via Cilium Gateway everywhere |
| Priority             | controllers: `platform-high`; DB cluster: `platform-low`                  | apps use `platform-high`; infra DBs (harbor/keycloak) use `platform-low` |
| Metrics              | `immich.metrics.enabled: true`                                           | chart ships ServiceMonitors; prometheus already selects all |
| netpol               | ship `netpol.yaml` but keep the resource line **commented out** in `_base/kustomization.yaml` | matches current netpol rollout phase (zigbee2mqtt) |

## 4. Files to add/change

```text
kubernetes/apps/immich/_base/
├── kustomization.yaml        # resources + configMapGenerator(values-immich) + utils/helm config
├── source.yaml               # OCIRepository immich (tag 0.13.4)
├── helmrelease.yaml          # chartRef + valuesFrom values-immich
├── values.yaml               # values carried in the values-immich ConfigMap
├── database.yaml             # CNPG Cluster cnpg-immich + Database CR (extensions)
├── pvc-library.yaml          # PVC immich-library (hdd-raidz-thin-1, 100Gi)
├── secrets.sops.yaml         # immich-secrets: JWT_SECRET
├── httproute.yaml            # immich.${SECRET_DOMAIN} -> immich-server:2283
└── netpol.yaml               # intended policy, commented out in kustomization for now

kubernetes/clusters/home/apps/immich.yaml               # Flux Kustomization (dependsOn: cnpg-system)
kubernetes/clusters/home/apps/kustomization.yaml        # add: - immich.yaml
logs.md                                                   # flip TODO pointer to this plan
```

### 4.0 `kubernetes/apps/immich/_base/kustomization.yaml`

```yaml
# yaml-language-server: $schema=https://json.schemastore.org/kustomization
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - database.yaml
  - helmrelease.yaml
  - httproute.yaml
  - pvc-library.yaml
  - secrets.sops.yaml
  # - netpol.yaml # enable alongside cluster-wide netpol rollout (see zigbee2mqtt)
configMapGenerator:
  - name: values-immich
    behavior: create
    files:
      - values.yaml=values.yaml
    literals:
      - env-values.yaml=''
configurations:
  - ../../utils/helm/kustomizeconfig.yaml
```

### 4.1 `kubernetes/apps/immich/_base/source.yaml`

```yaml
# yaml-language-server: $schema=https://raw.githubusercontent.com/fluxcd-community/flux2-schemas/main/ocirepository-source-v1.json
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: immich
spec:
  interval: 1h
  layerSelector:
    mediaType: application/vnd.cncf.helm.chart.content.v1.tar+gzip
    operation: copy
  ref:
    tag: 0.13.4
  url: oci://ghcr.io/immich-app/immich-charts/immich
```

No `renovate:` annotation needed: Renovate's `flux` manager tracks `OCIRepository` tags via
the helm-oci datasource (same as the existing cnpg/piraeus sources).

### 4.2 `kubernetes/apps/immich/_base/helmrelease.yaml`

```yaml
# yaml-language-server: $schema=https://raw.githubusercontent.com/fluxcd-community/flux2-schemas/main/helmrelease-helm-v2.json
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: immich
spec:
  interval: 1h
  chartRef:
    kind: OCIRepository
    name: immich
  install:
    remediation:
      retries: -1
  upgrade:
    cleanupOnFail: true
    remediation:
      strategy: rollback
      retries: 3
  valuesFrom:
    - kind: ConfigMap
      name: values-immich
    - kind: ConfigMap
      name: values-immich
      valuesKey: env-values.yaml
```

### 4.3 `kubernetes/apps/immich/_base/values.yaml`

```yaml
# Shared overrides (common-library applies `controllers` to every component).
controllers:
  main:
    containers:
      main:
        image:
          # renovate: datasource=docker depName=immich-app/immich-server
          tag: v3.2.0
        env:
          TZ: Europe/Amsterdam
          DB_HOSTNAME: cnpg-immich-rw
          DB_PORT: "5432"
          DB_USERNAME: app
          DB_DATABASE_NAME: app
          DB_PASSWORD:
            valueFrom:
              secretKeyRef:
                name: cnpg-immich-app
                key: password
          JWT_SECRET:
            valueFrom:
              secretKeyRef:
                name: immich-secrets
                key: JWT_SECRET
    pod:
      priorityClassName: platform-high

immich:
  metrics:
    enabled: true
  persistence:
    library:
      existingClaim: immich-library
  configuration: {}

server:
  controllers:
    main:
      containers:
        main:
          resources:
            requests:
              cpu: 10m
              memory: 512Mi
            limits:
              memory: 1Gi

machine-learning:
  controllers:
    main:
      containers:
        main:
          resources:
            requests:
              cpu: 100m
              memory: 2Gi
            limits:
              memory: 2Gi
  # Optional later: keep ML model cache across restarts (chart default: emptyDir,
  # i.e. models re-download on every pod restart)
  # persistence:
  #   cache:
  #     type: persistentVolumeClaim
  #     size: 10Gi
  #     accessMode: ReadWriteOnce
  #     storageClass: ssd-lvm-thin-2

valkey:
  enabled: true
  controllers:
    main:
      containers:
        main:
          resources:
            requests:
              cpu: 10m
              memory: 64Mi
            limits:
              memory: 64Mi
```

### 4.3b `database.yaml`, `pvc-library.yaml`, `httproute.yaml`, `secrets.sops.yaml`, `netpol.yaml`

```yaml
# database.yaml — Cluster adapted from the upstream immich-charts CNPG examples.
# NOTE: Database.spec.cluster.name must match this Cluster (the harbor/keycloak CRs in
# infra point at harbor/keycloak names that don't exist — don't copy that quirk).
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: cnpg-immich
spec:
  instances: 1
  priorityClassName: platform-low
  imageName: ghcr.io/cloudnative-pg/postgresql:18.6-standard-trixie # upstream-pinned; not auto-renovated
  storage:
    size: 8Gi
    storageClass: ssd-lvm-thin-2
  postgresql:
    shared_preload_libraries: ["vchord.so"]
    # vchord is NOT shipped in the standard CNPG postgres image; inject it from the
    # tensorchord image (per upstream example). Verify exact field names/casing against
    # the live operator first: kubectl explain cluster.spec.extensions
    # (the upstream example's snake_case keys may be silently pruned; CNPG API uses
    # camelCase dynamicLibraryPath/extensionControlPath).
    extensions:
      - name: vchord
        image:
          reference: ghcr.io/tensorchord/vchord-scratch:pg18-v1.1.1
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      memory: 1Gi
---
apiVersion: postgresql.cnpg.io/v1
kind: Database
metadata:
  name: cnpg-immich
spec:
  name: app
  owner: app
  cluster:
    name: cnpg-immich
  extensions:
    - name: vector
      ensure: present
    - name: vchord
      ensure: present
    - name: earthdistance
      ensure: present
    - name: cube
      ensure: present
```

```yaml
# pvc-library.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: immich-library
spec:
  storageClassName: hdd-raidz-thin-1
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 100Gi
```

```yaml
# httproute.yaml — LAN-only per review; internal gateway.
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: immich
spec:
  hostnames: ["immich.${SECRET_DOMAIN}"]
  parentRefs:
    - name: internal
      namespace: network
  rules:
    - backendRefs:
        - name: immich-server
          port: 2283
```

`secrets.sops.yaml` — Secret `immich-secrets` with `stringData.JWT_SECRET` generated via
`openssl rand -hex 32`, encrypted with `sops` (path rule `kubernetes/*.sops.yaml` already
covers `stringData`). DB passwords are never stored in the repo (CNPG-managed secret).

`netpol.yaml` (kept commented out in kustomization until the netpol rollout phase):
egress = DNS (kube-system) + self-namespace (server↔`cnpg-immich-rw`:5432,
server↔`immich-valkey`:6379, server↔`immich-machine-learning`:3003) + huggingface.co
egress for ML model download; ingress = from `network` ns gateway pods only. Verify pod
label selectors against live Cilium gateway pods (`kubectl -n network get pods
--show-labels`) when enabling.

### 4.4 `kubernetes/clusters/home/apps/immich.yaml`

Copy of `ntfy.yaml` with: `name: immich`, `path: ./immich/_base`,
`sourceRef: ExternalArtifact/apps`, `targetNamespace: immich`, plus:

```yaml
  dependsOn:
    - name: cnpg-system
      namespace: flux-system
```

and registration `- immich.yaml` in `kubernetes/clusters/home/apps/kustomization.yaml`
(alphabetical: between `home-ops-private.yaml` and `llm.yaml`).

## 5. Rollout sequence (after plan approval, one PR)

1. Secrets are committed with obviously-fake placeholders (`secrets.sops.yaml`); before
   pushing, fill `JWT_SECRET` with a real value and encrypt the file in place:
   `sops kubernetes/apps/immich/_base/secrets.sops.yaml` (needs
   `../home-ops-secrets/age.key`). Do not push unencrypted.
2. All files below are implemented on the `immich` branch.
3. Offline checks:
   - `pre-commit run --all-files`
   - `kubeconform -strict` on plain yaml; `kubectl kustomize ./kubernetes/apps/immich/_base` renders.
   - `helm pull oci://ghcr.io/immich-app/immich-charts/immich --version 0.13.4` +
     `cosign verify` with the issuer/identity flags from §2 (signature proof for review;
     cosign is not pinned in `.mise.toml` — run it e.g. via `docker run --rm
     ghcr.io/sigstore/cosign/v2 cosign verify ...`).
   - `helm template oci://ghcr.io/immich-app/immich-charts/immich:0.13.4 -f values.yaml`
     sanity check (service names `immich-server`/`immich-valkey`/`immich-machine-learning`,
     port 2283, library claim wiring).
4. Commit on `immich` branch; user reviews + pushes; Flux reconciles (`task reconcile`).
5. In-cluster verification (in order):
   - `kubectl -n immich get cnpg,db,secret,pvc` — CNPG cluster `cnpg-immich-1` Running;
     secret `cnpg-immich-app` exists.
    - `kubectl exec cnpg-immich-1 -c postgresql -- psql -U app -d app -c '\dx'` —
     `vchord`/`vector` present (catches the `spec.extensions` API-name drift between CNPG
     versions; adjust to the deployed operator's schema via
     `kubectl explain cluster.spec.extensions`).
   - `kubectl -n immich get pods` — server/microservices/valkey/ML Ready (server may
     crash-loop briefly until the DB is ready — expected; the HelmRelease converges).
   - `kubectl -n immich get servicemonitor` → scraped (up targets in Prometheus).
   - Browse `https://immich.${SECRET_DOMAIN}` from the LAN; create the admin account
     immediately (first sign-up claims the instance — do this the same day).
   - Upload a photo + a large video from a phone on the LAN/WLAN (catches gateway
     body/timeout limits — see risks); check `immich-server` logs for DB/redis connectivity.
6. Then a follow-up commit: enable netpol once validated, mark `logs.md` TODO done.

## 6. Update strategy (Renovate)

- Chart: Renovate's `flux` manager tracks the `OCIRepository` tag (cnpg precedent);
  patch/minor auto-merge per existing policy, majors as PRs.
- App image: shared tag lives in `values.yaml` with the `# renovate: datasource=docker
  depName=immich-app/immich-server` annotation (same annotation convention as
  `infra/flux-system/flux-instance/_base/values.yaml`). The `helm-values` manager alone
  can't infer depName here (tag has no sibling `repository`), so the annotation is required.
- Postgres `imageName` (18.6-standard-trixie) and `vchord-scratch:pg18-v1.1.1` are
  **not** auto-detected (keys `imageName:`/`reference:`); manual bumps, or add a custom
  regex rule later if churn appears.

## 7. Risks & mitigations

- **LAN-only exposure**: with the HTTPRoute on the `internal` gateway, phone backup only
  works on the home network; phones outside the LAN will fail to connect until netbird/VPN
  lands. Acceptable per review decision.
- **Large uploads**: Cilium/Envoy may cap request duration (~60s default) — test large
  video upload; if capped, add `spec.rules[].timeouts.request.clientTimeout` on the
  HTTPRoute (Gateway API core `timeouts`) and verify Cilium support
  (`kubectl explain httproute.spec.rules.timeouts`).
- **CNPG extensions API drift**: upstream examples target a newer operator than chart
  0.29.0's — verify field casing/shape against the live operator CRD before applying
  (structural-schema pruning silently drops wrong keys). Fallback: bump cnpg chart or use
  `tensorchord/cloudnative-vectorchord` image instead of injected vchord.
- **DB crash-loop at first boot**: HelmRelease applies app + DB together; server restarts
  until DB is up (no HelmRelease-level DB-readiness gate). Acceptable; tighten with
  `spec.dependsOn`/healthChecks later if annoying.
- **HDD library + DRBD**: sequential photo IO on `hdd-raidz-thin-1` is the same class the
  repo already uses; DB stays on SSD. Watch `logs.md` style speed tests if uploads feel slow.
- **RPO**: DB backup is currently only Velero PV snapshots (barman-cloud CNPG plugin is a
  separate TODO). Library PV gets Velero'd too → cloud storage growth; see open questions.
- **Secrets hygiene**: no plaintext secrets; `nosemgrep` marker may be needed next to
  secretKeyRef lines if the pre-commit semgrep scan flags the reference lines (precedent in
  harbor values.yaml).

## 8. Rollback

Revert the commit and push; Flux prunes the `immich` app. Storage: LINSTOR classes use
`reclaimPolicy: Retain`, so library + (after CNPG cluster removal) DB volumes survive as
orphaned LINSTOR resources — see `docs/linstor-snapshot-gc.md` for GC if needed. Before
removing a CNPG `Cluster` CR for real, take a final `pg_dump` if data must survive.

## 9. Open questions (for review)

1. **Library PVC size / pool**: 100Gi on `hdd-raidz-thin-1` as a starting point — OK, or
   go straight to a larger reservation? (thin-provisioned, expansion allowed)
2. **Valkey persistence**: keep chart-default emptyDir (queues lost on restart) or add a
   small PVC? Plan defaults to emptyDir.
3. ~~**External exposure**~~ — **resolved in review**: `internal` gateway (LAN-only);
   remote/mobile access deferred to netbird/VPN (separate open TODO in `logs.md`).
4. **Velero scope**: include the 100Gi library PVC in remote backups (cost) or label
   `velero.io/exclude-from-backup` and handle library backups separately?
5. Anything to add to `immich.configuration` (trash days, storage filename template)?
   Plan starts empty (`configuration: {}`).
