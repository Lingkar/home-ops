# Resource right-sizing with Robusta KRR

KRR recommends CPU/memory requests and limits from Prometheus history. Use it
as decision support; apply changes through Git/Flux, not automatically.

## Prerequisites

- Prometheus with at least 10 days of history (retention is 14d here) and
  kube-state-metrics for the OOM-data flag.
- `KUBECONFIG` pointing at the cluster. In this repo the real kubeconfig is
  `../home-ops-secrets/kubeconfig` (set by `.mise.toml`/Taskfile), **not**
  `~/.kube/config`.
- Docker, or an in-cluster Job with the read-only RBAC below.
- `robustadev/krr:v1.28.0` is multi-arch; it runs on c-01, c-02, rpi-00 or
  the workstation. The MySQL image's amd64-only constraint is unrelated.

## Local run (recommended)

Forward the Prometheus service:

```sh
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
```

In another terminal:

```sh
mkdir -p tmp/krr

docker run --rm --net host \
  -v "${KUBECONFIG:-$HOME/.kube/config}:/kubeconfig:ro" \
  -v "$PWD/tmp/krr:/reports" \
  robustadev/krr:v1.28.0 \
  python krr.py simple \
    --kubeconfig /kubeconfig \
    --prometheus-url http://127.0.0.1:9090 \
    --mem-min 32 \
    --cpu-min 10 \
    --history-duration 240 \
    --use-oomkill-data \
    --max-workers 5 \
    -f json --fileoutput /reports/krr-$(date +%F).json
```

Notes:

- The logged command in `logs.md` uses `~/.kube/config` and no report volume.
  Use `$KUBECONFIG` and mount `tmp/krr`; otherwise `--fileoutput` disappears
  with `--rm`.
- `-t` is for an interactive terminal; omit it in scripts.
- `--net host` is Linux-only. On macOS use `-p 9090:9090` and
  `--prometheus-url http://host.docker.internal:9090`.
- `--history-duration` and `--history_duration` both work. `--mem-min` is in
  MB, not MiB.
- Use a namespace allowlist for a focused report, for example:
  `-n phela -n home-assistant -n harbor-system`.
  Do not start with `kube-system`, `piraeus-datastore`, `flux-system`,
  `cert-manager`, `cnpg-system`, or `mysql`; those are reviewed manually.

## No-Docker fallback

KRR's metrics are plain Prometheus queries. The KRR-equivalent analysis used:

```sh
kubectl get --raw \
  "/api/v1/namespaces/monitoring/services/http:kube-prometheus-stack-prometheus:9090/proxy/api/v1/query?query=$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$PROMQL")"
```

Apply the `simple` strategy math:

- CPU: 95th percentile over the history window; CPU limit unset.
- Memory: max working set over the window × 1.15, or the memory limit at
  OOM time × 1.25 with `--use-oomkill-data`; at least 32 MB.
- Defaults: 336h history, 1.25m step, 100 points required.
- OOM data comes from kube-state-metrics
  `kube_pod_container_status_last_terminated_reason{reason="OOMKilled"}`.

The actual KRR CLI was also run on 2026-10-25 with the command above; the
report is kept in `.private/krr/` (gitignored, private workspace). The CLI excludes
`kube-system` by default, so the CoreDNS/Cilium/kube-apiserver rows below come
from the equivalent queries. The remaining recommendations matched.

## Scheduled in-cluster report (optional)

A small CronJob in `monitoring` can run KRR weekly with a read-only
`ClusterRole` (get/list/watch pods, nodes, namespaces, deployments,
statefulsets, daemonsets, replicasets, jobs, cronjobs, HPAs; no `scale`
writes). Use:

- `--prometheus-url http://kube-prometheus-stack-prometheus.monitoring.svc:9090`
- `priorityClassName: platform-low` so it never preempts real workloads
- `requests: 100m/256Mi`, `limits.memory: 1Gi`
- a 1Gi `krr-reports` PVC on `ssd-lvm-thin-2`, excluded from Velero
- `concurrencyPolicy: Forbid`, `ttlSecondsAfterFinished`
- `# renovate: datasource=docker depName=robustadev/krr` for the image

On the current two-node maintenance window the CronJob will not schedule
without headroom; use the local Docker/port-forward run instead.

## Automation scope

| Level | What | Recommendation |
|---|---|---|
| Local run | Port-forward + Docker + JSON/Markdown report | Start here; no cluster resources |
| Scheduled report | CronJob writes to PVC / sends a summary | Good once c-02 is back |
| PR automation | Parse JSON and update Helm values | Not worth the mapping/risk across multiple repositories |
| Auto-apply | KRR Enforcer mutating webhook | **No** — needs Robusta SaaS/UI + certificate, mutates pods at admission, bypasses GitOps |

KRR cannot see priority classes, PDBs, LINSTOR/DRBD, arch constraints,
node allocatable, or sub-scrape spikes. `simple` sets memory request = limit;
if you want burstable memory, set the limit separately. Rolling updates on a
full node can deadlock, so apply one workload at a time when there is
headroom.

## Findings (2026-10-25, 240h, OOM data)

The point-in-time `kubectl top` snapshot was misleading for the largest
consumers. KRR shows these are **not** over-requested:

| Workload/container | Current | 10d max | KRR | Action |
|---|---:|---:|---:|---|
| MySQL/mysql | 1,100Mi | 1,099Mi | 1,375Mi | **increase**; OOM |
| linstor-controller | 2,048Mi | 1,774Mi | 2,040Mi | leave alone |
| kube-apiserver | 4,096Mi | 3,888Mi | 4,470Mi | leave alone |
| cilium-agent | 440Mi | 414Mi | 550Mi | **increase**; OOM |
| monitoring/otel-collector | 200Mi | 194Mi | 223Mi | stop if monitoring is down; not a reduction |

Safe reductions applied in this repository:

| Workload/container | Before | After | Reason |
|---|---:|---:|---|
| coredns (each) | 512Mi | 128Mi | max 56Mi |
| cilium-operator | 512Mi | 256Mi | max 206Mi |
| Flux helm/kustomize/source | 512/300/200Mi | 256/224/160Mi | max 173/161/114Mi |
| Flux flux-operator | 420Mi | 352Mi | max 285Mi |
| Flux image-automation/reflector | 256Mi | 128Mi | max 74/78Mi |
| cert-manager / cainjector | 200/300Mi | 128/192Mi | max 94/148Mi |
| netbird | 256Mi | 192Mi | max 133Mi |
| mysql-operator | 400Mi | 256Mi | max 222Mi |
| zigbee2mqtt | 256Mi | 192Mi | max 146Mi |
| home-assistant | 800Mi | 768Mi | max 620Mi |
| harbor registry/trivy | 256/256Mi | 64/160Mi | max 33/115Mi |
| harbor jobservice | 70Mi | 48Mi | KRR 32Mi |
| keycloak operator | 450Mi | 384Mi | KRR 379Mi |
| kube-state-metrics | 210Mi | 192Mi | KRR 170Mi |
| keycloak kc-infra | 1,256Mi | 704Mi | max 554Mi |
| immich-machine-learning | 2,048Mi | 1,536Mi | max 1,253Mi |
| loki | 4Gi | 768Mi | max 509Mi |
| loki-results-cache | 1,229Mi | 64Mi | max 18Mi |
| loki-chunks-cache | 9,830Mi | 8,704Mi | max 7,451Mi |
| phela | 1,024Mi | 832Mi | max 719Mi; CPU 300m → 64m (KRR 29m) |
| crossplane/provider | 512/256Mi | 320/224Mi | max 258/171Mi |

Deferred because the user chose MySQL/Cilium-only increases:

- `immich-server` 6,144Mi → ~7,680Mi (OOM)
- `prometheus` 2,048Mi → ~2,432Mi
- `velero` 500Mi → ~640Mi (OOM)
- `snapshot-controller` 32Mi → ~40Mi (OOM)
- `llm/llamacpp` 57,344Mi → ~35,753Mi (model/engram sizing risk)
- `kube-apiserver` 4,096Mi → ~4,470Mi (c-01 is tight)
- `linstor-satellite` c-02 512Mi → ~568Mi and rpi-00 256Mi → ~316Mi
  (storage data path; left unchanged)
- Flux kustomize-controller CPU 55m → ~112m (CPU is not the constraint)
- `piraeus-operator` 256Mi → ~214Mi (storage control plane; left unchanged)

## OOM-killed containers (last 10 days)

| Workload/container | Limit at OOM | KRR recommendation |
|---|---:|---:|
| mysql/mysql-0/mysql | 1,100Mi | 1,375Mi |
| immich/immich-server/main | 6,144Mi | 7,680Mi |
| kube-system/cilium/cilium-agent | 440Mi | 550Mi |
| velero/velero | 500Mi | 625Mi |
| falco-system manager | 128Mi | 160Mi |
| kube-system/snapshot-controller | 32Mi | 40Mi |

Do not apply reductions to these.

Out-of-repo workloads are intentionally omitted from this public runbook.
Run KRR against them separately and keep that report private; use the
`--extra-config` mechanism in the shutdown runbook to add their namespaces.

## Safe application checklist

1. Review the KRR report; ignore `?` / "Not enough data".
2. Exclude `kube-system`, `piraeus-datastore`, `flux-system`, `cert-manager`,
   `cnpg-system`, `mysql`, and storage/network components unless you are
   explicitly tuning them.
3. Check whether the workload is bursty (media transcoding, downloads, ML,
   MySQL) and whether the request equals the limit.
4. Keep memory headroom above the 10d max; KRR's 15% buffer is a floor.
5. Apply one workload at a time through Git; run `task reconcile`; watch
   rollouts, OOMs, and Pending pods.
6. Do not auto-apply. Do not use the Enforcer in this GitOps homelab.

See `docs/c02-shutdown.md` for how the right-sizing changes interact with the
two-node maintenance window.
