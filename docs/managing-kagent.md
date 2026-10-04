# Managing kagent / Agent Substrate

kagent 1.0 runs agents on Agent Substrate (ATE). Reads as one system, installed as two.

## Versions and install surface

| Component | Namespace | Version | Managed by |
| --- | --- | --- | --- |
| `substrate-crds` | ate-system | 0.3.0-alpha3 | GitOps (`kubernetes/infra/ate-system/substrate-crds`) |
| `substrate` | ate-system | 0.3.0-alpha3 | manual `helm` |
| `kagent-crds` | kagent | 1.0.0-alpha7 | manual `helm` |
| `kagent` | kagent | 1.0.0-alpha7 | manual `helm` (`-f kubernetes/infra/kagent/_base/values.yaml`) |

The kagent and substrate versions are coupled: a kagent release pins one substrate
version, and substrate must not be upgraded on its own (schema/DB changes). To bump,
move both substrate charts and both kagent charts together and recreate the CRs under
the new API group (1.0 moved the kagent group from `kagent.dev` to `api.kagent.dev`).

`kubectl-ate` (the substrate CLI plugin) is versioned with substrate:

```
curl -fsSL -o kubectl-ate \
  "https://github.com/kagent-dev/substrate/releases/download/v0.3.0-alpha3/kubectl-ate-linux-$(uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/')"
chmod +x kubectl-ate && sudo mv kubectl-ate /usr/local/bin/
```

## Identity bootstrap (required, no chart does it)

Agent Substrate authenticates its components with mTLS and kagent with JWT. The CA and
JWT pools must be generated out-of-band with `kubectl-ate`. A reinstall that wipes these
secrets leaves every substrate pod stuck on `credential bundle is not issued yet`.

The `ate-system` pools (`actor-id-*`, `egress-mitm-ca-pool`) persist from the original
install. The `podcertificate-controller-system` pools are new in substrate 0.3.0 and are
the usual thing missing:

```
kubectl ate admin make-ca-pool --ca-id=1 --name=service-dns-ca-pool \
  --secret-namespace=podcertificate-controller-system
kubectl ate admin make-ca-pool --ca-id=1 --name=pod-identity-ca-pool \
  --secret-namespace=podcertificate-controller-system
```

Full bootstrap from scratch (order matters):

```
kubectl ate admin make-ca-pool --ca-id=1 --name=actor-id-ca-pool  --secret-namespace=ate-system
kubectl ate admin make-jwt-pool --key-id=1 --name=actor-id-jwt-pool --secret-namespace=ate-system
kubectl ate admin make-ca-pool --ca-id=1 --name=egress-mitm-ca-pool --secret-namespace=ate-system \
  --key-type=ECDSAP256

# ate-api-server reads the actor CA root from this secret
actor_id_ca_root="$(kubectl get secret actor-id-ca-pool -n ate-system \
  -o jsonpath='{.data.pool}' | base64 --decode \
  | jq -r '.CAs[0].RootCertificateDER' | base64 --decode \
  | openssl x509 -inform der -outform pem)"
kubectl create secret generic actor-id-ca-certs -n ate-system \
  --from-literal=ca.crt="${actor_id_ca_root}"
```

Then re-roll substrate so pods mount the material:

```
helm upgrade substrate oci://ghcr.io/kagent-dev/substrate/helm/substrate \
  --version 0.3.0-alpha3 -n ate-system --reuse-values --wait --timeout 10m
```

## ate-api authentication (issuer)

`ate-api-authentication` in `ate-system` tells ate-api-server which JWT issuers to trust.
The `issuer` must equal the cluster's advertised issuer, otherwise every `kubectl ate`
call fails with `token issuer "..." not trusted`:

```
kubectl get --raw /.well-known/openid-configuration | jq -r .issuer
# -> https://192.168.69.5:6443
```

ConfigMap content (the issuer is the Talos VIP endpoint; update it if that changes):

```
kubectl -n ate-system create configmap ate-api-authentication \
  --from-literal=authentication.yaml="actorIdentityJWTProvider: kubernetes
jwtProviders:
- name: kubernetes
  issuer: https://192.168.69.5:6443
  audiences: [api.ate-system.svc]
  certificateAuthorityFile: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
  discoveryTokenFile: /var/run/secrets/kubernetes.io/serviceaccount/token
" --dry-run=client -o yaml | kubectl apply -f -

kubectl -n ate-system rollout restart deploy/ate-api-server
```

This ConfigMap is not managed by Helm or GitOps.

## Model provider

The `default-model-config` ModelConfig is generated from the `providers` block in
`kubernetes/infra/kagent/_base/values.yaml`. `providers.<default>.config` is passed
straight through to the provider's block in the ModelConfig.

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

Apply changes with `helm upgrade kagent ... -f kubernetes/infra/kagent/_base/values.yaml`,
then create a **new** Session (existing sessions pin the old compiled revision).

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

`kubectl ate` returns `token issuer ... not trusted`: fix the ConfigMap issuer above.

Substrate pods stuck `ContainerCreating` with `credential bundle is not issued yet`:
the CA pools are missing or the podcertificate-controller cannot mount them; see
identity bootstrap above.
