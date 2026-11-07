# Managing kagent / Agent Substrate

kagent 1.0 runs agents on Agent Substrate (ATE). Reads as one system, installed as two.

## Versions and install surface

| Component | Namespace | Version | Managed by |
| --- | --- | --- | --- |
| `substrate-crds` | ate-system | 1.0.0 | Flux (`kubernetes/infra/ate-system/substrate-crds`) |
| `substrate-podcert` | podcertificate-controller-system | 1.0.0 | Flux (`kubernetes/infra/ate-system/substrate-podcert`) |
| `substrate-atelet` | ate-system | 1.0.0 | Flux (`kubernetes/infra/ate-system/substrate-atelet`) |
| `substrate` | ate-system | 1.0.0 | Flux (`kubernetes/infra/ate-system/substrate`) |
| `kagent-crds` | kagent | 1.0.0-rc3 | Flux (`kubernetes/infra/kagent/operator`) |
| `kagent` | kagent | 1.0.0-rc3 | Flux (`kubernetes/infra/kagent/operator`) |

kagent `1.0.0-rc3` pins Substrate `v1.0.0`. The 0.3.0-alpha3 → 1.0.0 path is a
reinstall, not an in-place upgrade: Substrate does not support pre-1.0 minor
upgrades, and its Postgres migrations were squashed at 0.7.0-alpha2.

Flux ordering:

```
substrate-bootstrap
  -> substrate-crds
     -> substrate-podcert
        -> substrate-atelet
           -> substrate
kagent-database
  -> kagent (kagent-crds, then kagent)
     -> kagent-resources (Agent/AgentTemplate/Harness)
```

All HelmReleases explicitly set `install.atomic: false` and `upgrade.atomic: false`;
Flux must not pass `--atomic` for these charts.

## One-time bootstrap (not managed by Git)

These steps generate secrets that cannot be committed:

```sh
# New client for Substrate 1.0.0
curl -fsSL -o kubectl-ate \
  "https://github.com/kagent-dev/substrate/releases/download/v1.0.0/kubectl-ate-linux-$(uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/')"
chmod +x kubectl-ate && sudo mv kubectl-ate /usr/local/bin/

# CA/JWT pools, from a v1.0.0 checkout
git clone --depth 1 --branch v1.0.0 https://github.com/kagent-dev/substrate /tmp/substrate-v1.0.0
cd /tmp/substrate-v1.0.0
go run ./cmd/ate-setup create podcertificate-controller-cas
go run ./cmd/ate-setup create actor-id-ca-pool
go run ./cmd/ate-setup create actor-id-ca-certs
go run ./cmd/ate-setup create egress-mitm-ca-pool
go run ./cmd/ate-setup create jwt-authority-pool
```

`ate-setup create` preserves existing pools. If `ate-system` survived a partial
teardown, the actor/JWT/egress pools are reused; only
`podcertificate-controller-cas` needs to recreate the deleted
`podcertificate-controller-system` pools.

`ate-api-authentication` is still a manual ConfigMap. The issuer must equal the
cluster's advertised issuer:

```sh
kubectl get --raw /.well-known/openid-configuration | jq -r .issuer
# -> https://192.168.69.5:6443
```

Create it after the API server exists, or run
`go run ./cmd/ate-setup create api-authentication-config` from the same checkout.

### Database

Flux creates the CNPG cluster `cnpg-kagent` in the `kagent` namespace. It does not
create the application roles or the connection Secrets. Run the upstream setup
scripts as the CNPG superuser (`cnpg-kagent-superuser`):

- kagent: `go/core/pkg/postgressetup/setup.sql` at `v1.0.0-rc3`
  (`kagent_schema=kagent`, roles `kagent_owner`/`kagent_readwrite`)
- substrate: `pkg/postgressetup/setup.sql` at `v1.0.0`
  (`substrate_schema=substrate`, roles `substrate_owner`/`substrate_readwrite`)

Then create the connection Secrets (SOPS-encrypt them before committing):

```sh
# kagent namespace
kagent-postgres-owner       key: ownerConnectionString
kagent-postgres-readwrite   key: readWriteConnectionString
# ate-system namespace
substrate-postgres-owner    key: ownerConnectionString
substrate-postgres-readwrite key: readWriteConnectionString
```

The RustFS credentials are not used: Substrate is configured for the existing
Garage S3 service, so `rustfs.enabled: false`. The Garage endpoint is
`http://garage-headless.garage.svc.cluster.local:3900`, region `garage`,
path-style `true`.

Create a dedicated bucket and key once:

```sh
kubectl exec -n garage garage-0 -- ./garage bucket create ate-snapshots
kubectl exec -n garage garage-0 -- ./garage key create substrate
kubectl exec -n garage garage-0 -- ./garage bucket allow \
  --read --write --owner ate-snapshots --key substrate
kubectl exec -n garage garage-0 -- ./garage key show substrate
```

Store the key ID/secret in a dedicated, namespaced SOPS Secret (not
`cluster-secrets`):

```sh
cp kubernetes/infra/ate-system/bootstrap/_base/secret.sops.yaml.example \
   kubernetes/infra/ate-system/bootstrap/_base/secret.sops.yaml
# fill AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY from `garage key show substrate`
sops -e -i kubernetes/infra/ate-system/bootstrap/_base/secret.sops.yaml
```

Then uncomment `secret.sops.yaml` in
`kubernetes/infra/ate-system/bootstrap/_base/kustomization.yaml`. The
`substrate` object-store sidecars and the `substrate-atelet` node plugin both
reference this Secret by name. Garage's data PVC is 20 GiB and shared with
Loki/Velero; monitor it and expand `data-garage-0` when needed.

The connection strings point at
`cnpg-kagent-rw.kagent.svc.cluster.local:5432/kagent`; leave the role out of the
DSN because both charts run `SET ROLE` after connecting.

### Required values

Substrate's `values.yaml` carries the 1.0.0 gates and identities:

```yaml
preview:
  - PerTemplateSnapshotLocation
  - GoldenEgressPolicy
atelet:
  enabled: false
ateApi:
  actorJWTIssuer: https://idp.ate-system.svc
  authorization:
    bootstrapOwners:
      - spiffe://cluster.local/ns/kagent/sa/kagent-controller
      - system:serviceaccount:ate-system:ate-client
atenetRouter:
  ingressAllowedSPIFFEIDs:
    - spiffe://cluster.local/ns/kagent/sa/kagent-controller
```

The `kagent` namespace is labeled `ate.dev/api-access=true`; without it the
controller cannot reach `ate-api-server`.

## Model provider

The `default-model-config` ModelConfig is generated from the `providers` block in
`kubernetes/infra/kagent/operator/_base/values.yaml`. `providers.<default>.config`
is passed straight through to the provider's block in the ModelConfig.

`llm.buijnsters.com` is a llama.cpp (`llama-server`) with `LLAMA_API_KEY` set, so it
speaks the OpenAI API on `/v1`, not Ollama's `/api/chat`. Point kagent at it as an
OpenAI-compatible endpoint so the egress gateway injects the bearer key (a
self-hosted `Ollama` provider is treated as keyless and gets no credential):

```yaml
providers:
  default: openAI
  openAI:
    provider: OpenAI
    model: qwen3.8-flash-next   # must match the llama.cpp --alias
    apiKeySecretRef: kagent-ollama
    apiKeySecretKey: API_KEY
    config:
      baseUrl: https://llm.buijnsters.com/v1
```

`kagent-ollama/API_KEY` must hold the same value as the `llm` namespace's
`llm-api-key/API_KEY`. The agent never holds the key; the substrate egress gateway
fetches it and sets `authorization: Bearer <key>`.

After changing values, Flux reconciles `kagent`; create a **new** Session
(existing sessions pin the old compiled revision).

## Snapshots and workers

The kagent chart creates the WorkerPool `kagent-default` with
`ateworker-gvisor:v1.0.0` and `sandboxClass: gvisor`. The Harness uses
`gs://ate-snapshots/kagent/`; Substrate 1.0.0 uses `gs://` URIs for the S3/Garage
snapshot backend.

The node-local image cache lives at `/var/lib/ate/image-cache` and uses layout
version 3. Before the new atelet starts, clear the old node state (no actors must
be running):

```sh
for n in rpi-00 c-01 c-02; do
  kubectl debug node/$n -it --image=busybox -- rm -rf /host/var/lib/ate
done
```

`c-01` is a control-plane node; if the debug pod does not schedule, use a
temporary privileged DaemonSet with `tolerations: [{operator: Exists}]`.

## Troubleshooting

Model calls fail with `401 Invalid API Key`:

1. Confirm the ModelConfig resolves a real secret:
   `kubectl -n kagent get modelconfig default-model-config -o jsonpath='{.spec}{"\n"}{.status.secretHash}'`.
   An empty-string SHA-256 (`e3b0c442...`) means no credential was compiled.
2. Confirm the egress rule carries the credential:
   `kubectl ate get egress-policy <actor> --atespace kagent` should show a
   `replaceHeaders` effect with `credentialUri: ate-secret://k8s.io/default/kagent/kagent-ollama/API_KEY`.
3. Watch what the agent actually reached:
   `kubectl -n ate-system logs deploy/atenet-egress -c agentgateway | grep "upstream request"`.
   A healthy call is `POST ... http.path=/v1/chat/completions http.status=200`.

`kubectl ate` returns `token issuer ... not trusted`: fix the `ate-api-authentication`
ConfigMap issuer above.

Substrate pods stuck `ContainerCreating` with `credential bundle is not issued yet`:
the CA pools are missing or the podcertificate-controller cannot mount them; see
the bootstrap section.
