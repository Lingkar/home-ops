# TODO:
- [x] Piraeus - Linstor
- [x] Via VolumeSnapshot recreate PV in different storageclass
- [x] Set-up monitoring stack
- [x] Set-up resource requests and limits for all resources
    - [x] Analysis to what extent we can automate this, e.g. krr -> docker run --net host --rm -t --volume ~/.kube/config:/root/.kube/config robustadev/krr:v1.28.0 python krr.py simple --prometheus-url http://localhost:9090 --mem-min 32 --history-duration 240 --use-oomkill-data
      - Process, automation scope and findings: docs/krr-rightsizing.md
      - c-02 two-node shutdown/restore runbook: docs/c02-shutdown.md
- [x] Fix resources in kube-system
- [x] Remove sops-age from namespaces that don't need it
- [x] Velero back-up snapshots to Cloud
- [x] Velero set-up scheduled backup
- [x] Linstor doesn't delete S3 back-ups when VS is deleted. (multiple open issues found)
- [x] Velero perform full cluster restore -> https://linbit.com/blog/abstracting-persistent-storage-across-environments-with-linbit-sds/
- [x] Fix custom RPI PWM Fan implementation https://github.com/siderolabs/sbc-raspberrypi/issues/58
- [x] Create Velero logic such that specific PV's / PVC's are not included in the (remote) back-up. -> Label PVC: velero.io/exclude-from-backup=true
- [x] Set-up proper MySQL server back-ups
- [x] Set-up PSQL operator for Postgres databases
- [x] Set-up KeyCloak as OIDC issuer
    - [x] Set-up KeyCloak operator
    - [x] https://www.keycloak.org/operator/basic-deployment
        - [x] Set-up PSQL database
- [x] Set-up Harbor OCI registry, public access?
    - [x] first version running
    - [x] Connect to OIDC for authentication and authorization.
        - [x] Add some other groups next to admin
    - [x] Set-up dedicated PSQL database
- [x] Finish nfs-ganesha https://github.com/kubernetes-sigs/nfs-ganesha-server-and-external-provisioner
    - [x] from e.g. the satellite move data to new volume, mount the drbd volume with `mount -o ro /dev/drbd1009 /mnt/pvc`
    - [x] Instead of setting up new storageclass set-up separate nfs-ganesha servers and mount with https://kubernetes.io/docs/concepts/storage/volumes/#nfs
    - [x] Test-out per node shutdown
- [x] Migrate all ssd-lvm-thin-1 -> ssd-lvm-thin-2
- [x] Fix resource requests / limits -> no more OOM's on rpi
- [x] Set application priorities and evictions in case MS-S1 Max shuts down
    - [x] Set-up priority classes
    - [x] Test if it actually works
- [x] Fix Renovate config, separate patch roll-outs and autoupgrades
- [x] Set resources Velero, api-server, scheduler, controller manager
- [x] Sharing of GPU -> removal of amd gpu operator in favour of custom logic for "unsafe" gpu sharing
- [x] Set-up OTEL operator and a collector instance forwarding to loki log storage
    - [x] set-up OTEL operator
    - [x] set-up OTEL collector
        Configure it for collection of logs
- [x] Set-up S3 compatible object storage -> Garage
- [x] Set-up a notification channel https://ntfy.sh/ looks promising
    - [x] Set-up basic credentials
        Admin user has been set-up, default deny-all has been enabled, create an access token for usage from different machines.
        Create a alerting user account with access to specific topics.
        https://docs.ntfy.sh/config/#example-private-instance
- [x] Set-up intrusion detection with Falco
    - [x] Falco has been installed
    - [x] Configure alerting with Falco
- [x] Make sure all daemonsets have a priorityClass set, such that they can always be scheduled.
    The daemonsets which matter now have a priorityClass
- [x] Run a recurring verify on the Kopia back-ups https://kopia.io/docs/advanced/consistency/
        Added a daily shallow kopia verify check
        Added a monthly full kopia verify check
- [x] Run a recurring ZFS check and enable notification from smartctl for disk health (or via prometheus) -> scrutiny?
    https://www.linuxjournal.com/article/6983?page=0%2C1
    The Prometheus smartctl and zfs exporters lack proper release artifacts
    For now will run a recurring ZFS check with a ntfy alert when problems arise.
    For now will run a recurring smartctl check with a ntfy alert when problems arise.
- [x] Set-up alerts for Piraeus, e.g. when a drbdadm resource is out-of-sync
- [x] Set-up Immich
- [x] Set-up barmancloud cnpg backup/restore plugin (needs S3 object storage)
    - [x] Wire `keycloak-system` (`weekly` full + continuous WAL to Hetzner S3): docs/cnpg-backup-restore.md
    - [x] Wire remaining CNPG clusters (`immich`, `harbor-system`, `kagent`) via the shared component

- [/] Go through namespaces and add all missing netpol's, final goal is clusterwide netpol disallowing all traffic.
- [ ] https://github.com/owncloud/ocis -> opencloud ?

- [ ] Set-up own git https://code.forgejo.org/forgejo-helm/forgejo-helm
- [/] Set-up clean-up job for delete PV's with Retain
        Additionally the linstor resource definition might need to be removed including its snapshots.
        Manual runbook added for now: docs/linstor-snapshot-gc.md (also covers orphaned LINSTOR snapshots).
- [ ] FluxCD diffing -> fix pipelines -> flate or konflate: awaiting https://github.com/home-operations/flate/issues/848
- [?] Set-up valkey operator
- [ ] Enable hubble exporting of network traffic to be able visualized in monitoring tools
- [ ] Adding netpol for prometheus target scraping (flux-operator triggers alert atm for being down due to this)
- [ ] Switch from ghcr.io/wiremind/wiremind-helm-charts/gateway-api-crds to official gateway-api-crd (if possible)
- [ ] Fix ETCD grafana dashboard
- [/] Set-up netbird
    - [x] tmp set-up with direct deployment
    - [ ] fix the kubernetes-operator + netbird-operator-config charts
- [?] Wordpress updates
    - [ ] Run wordpress as non-root
    - [ ] Migrate from MySQL to MariaDB
- [ ] Set-up Windows on Kubernetes: https://github.com/dockur/windows
- [?] Add interactive Velero bootstrap step to restore from latest found S3 back-up
- [ ] Velero perform new full cluster restore, remote back-ups are now controlled by Velero data-mover and not by Linstor
- [ ] https://github.com/miniflux/v2/tree/main -> rss feed viewer
- [ ] Make the node shutdown with piraeus compatible with Talos by performing the missing `drbdadm down all` command
- [ ] Add more k8s resources to the otel collector: https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/receiver/k8sobjectsreceiver
    - [ ] Decide whether the otel stack clusterrole really needs permissions for (cluster-wide) getting / listing secrets.
- [ ] Schlink, link shortener
- [ ] Posties, social media posting
- [ ] it-tools
- [ ] scrypted NVR camera's

# Network policy approach:
Start in auditing mode:
- egress allow cluster DNS
- egress allow to world (not including 192.168.68.1/23)
- ingress allow from gateway
- egress deny cross-namespace
- ingress deny cross-namespace

## LLM: Qwen3.8-Flash-Next (UD-IQ3_XXS, SSD-streamed engram)
Switched `llm` from Qwen3-32B-Q4_K_M to Qwen3.8-Flash-Next on
`rocm-10.0-engramhalo`. This is a 125B/6B-active MoE plus a ~26.8 GiB engram
(n-gram) table; the EngramHalo build keeps that table SSD-backed via lazy mmap
(`-lm mmap --lazy-mode on`, ~1 GiB resident) so the ~76 GiB GGUF fits in
the ~75 GB budget. `--no-mmap` must never be used here: it disables the lazy path.

- [ ] Confirm resident RSS is ~50 GiB, not ~76 GiB (engram actually lazy)
- [ ] Confirm model loads and `/v1/models` returns alias `qwen3.8-flash-next`
- [ ] Quality sanity check (code, tool call, prose) — no ROCm wrong-logit mode
- [ ] Measure decode/prefill at depth; check DRBD/LINSTOR lazy-read latency impact
      (fork's numbers assume local NVMe; fallback is a node-local PV on c-02)
- [ ] Remove `pvc-model.yaml` / old `llm-models` PVC once stable
- [ ] Revisit quant if headroom: UD-IQ4_XS (better quality, ~61 GiB resident)

Images/args live in `kubernetes/apps/llm/_base/deployment.yaml`; per-model PVC in
`pvc-model-qwen38-flash-next-iq3-xxs.yaml`. Old Qwen3-32B PVC is retained for rollback.


# drbd volume check c-02
[2026-11-10T21:18:50Z] DRBD verify starting: node=c-02 peer=c-01 satellite=linstor-satellite.c-02-rzsqx
[2026-11-10T21:18:50Z] Resources to verify: 44
pvc-06af87a9-f49c-4699-bce1-ab4b97d7699c
pvc-0be0e149-8c24-41bb-9cd7-e2194217387f
pvc-13b662cd-f4a8-4e45-883f-790ae0bacc8b
pvc-13eb405b-ae52-49f2-974d-79f3c3d9e1a2
pvc-2177ae17-7492-4d5b-af7a-8bc929e1832f
pvc-2980fe5b-0512-401f-b475-fd3d3a77ffa9
pvc-2a0f9a6d-c101-405b-938e-f41015e8db15
pvc-3ccf9ad4-07b3-4472-b3db-cc4628b93300
pvc-3ec820ea-8b34-42d0-9e8a-344e90ed1b6c
pvc-4bb30f70-1d1f-4f3c-bf74-3ef233c9b10a
pvc-52ee0aee-2ad5-4a99-99fc-05686629cc82
pvc-5502b865-feae-434d-8a26-c0b9fc4e0556
pvc-5c5f4d81-cdfe-4e99-915b-d53c78d3a963
pvc-61e61c37-e760-412a-b6bf-8ce7f79ebd2b
pvc-65516952-90d0-4b43-bb52-b40d090499e7
pvc-66ca7fb9-1b01-47f5-bb27-d3bfea611cf3
pvc-6801d6f5-7d54-4cc4-b81e-656276a6cd09
pvc-6d2bdb60-0bd8-4177-85b4-ff5a28bf6539
pvc-73d4d761-0f70-43ae-adce-69801c8b32fa
pvc-73d61467-ea20-4676-87ba-de4a2e3f7922
pvc-766775f5-576a-4556-a209-0997d14b679c
pvc-84fecc17-75f5-42c9-aacc-67e2389e60b9
pvc-8585c129-7845-465c-9bcc-04b6187fe667
pvc-92194fd9-a826-4016-9ce5-93172c80f8b5
pvc-9716f790-7c42-4544-876a-61ed276abb6f
pvc-abd24bdf-4114-423e-b087-d02d4dee2d40
pvc-b0a075e6-2ab2-492c-b3bc-d5c2e6c8bda4
pvc-b1d56e2b-4c7e-41d3-bba9-52f010511316
pvc-bbbb39c6-f642-4915-88f3-e3c6638a9198
pvc-c22c27b4-bf8e-49c2-b1d5-c0a15f8e2e45
pvc-c98a5e7e-5259-4185-9931-7c4e206ed481
pvc-cd34c5f1-f813-48bc-aaeb-1bee2b785592
pvc-ce62374f-1cf5-42f1-b935-7778cd610a84
pvc-cee6c130-ebd2-46f8-bbee-ff8804f4baee
pvc-d292289c-0839-419b-bd66-92ae088eb42f
pvc-e7b7d2d6-67a5-4e71-8b5d-8bbea3b67e36
pvc-e8da8701-ca81-4216-a906-c2699034e4b2
pvc-ead28951-31cc-498c-8d63-769cc16e1c11
pvc-ec4ca458-e9c2-4a81-9c85-ceb6bc15e897
pvc-eed2bfce-fbd0-405a-9687-20f8db2b54cc
pvc-f653f466-d065-4891-9c97-97a0e4275dd7
pvc-f8466a74-1582-48ab-ba64-e9362c62202c
pvc-f8c0d241-96ed-477b-99bb-d9dd50daba35
pvc-ff3e2abd-6111-4cb8-9365-0cfc8f19a1a2
[2026-11-10T21:18:50Z] === verify pvc-06af87a9-f49c-4699-bce1-ab4b97d7699c ===
[2026-11-10T21:20:21Z] PASS: pvc-06af87a9-f49c-4699-bce1-ab4b97d7699c out-of-sync=0 percent-in-sync=100.00
[2026-11-10T21:20:51Z] === verify pvc-0be0e149-8c24-41bb-9cd7-e2194217387f ===
[2026-11-10T21:21:21Z] PASS: pvc-0be0e149-8c24-41bb-9cd7-e2194217387f out-of-sync=0 percent-in-sync=100.00
[2026-11-10T21:21:51Z] === verify pvc-13b662cd-f4a8-4e45-883f-790ae0bacc8b ===
[2026-11-10T21:22:22Z] PASS: pvc-13b662cd-f4a8-4e45-883f-790ae0bacc8b out-of-sync=0 percent-in-sync=100.00
[2026-11-10T21:22:52Z] === verify pvc-13eb405b-ae52-49f2-974d-79f3c3d9e1a2 ===
[2026-11-10T21:24:52Z] PASS: pvc-13eb405b-ae52-49f2-974d-79f3c3d9e1a2 out-of-sync=0 percent-in-sync=100.00
[2026-11-10T21:25:22Z] === verify pvc-2177ae17-7492-4d5b-af7a-8bc929e1832f ===
[2026-11-10T21:25:53Z] PASS: pvc-2177ae17-7492-4d5b-af7a-8bc929e1832f out-of-sync=0 percent-in-sync=100.00
[2026-11-10T21:26:23Z] === verify pvc-2980fe5b-0512-401f-b475-fd3d3a77ffa9 ===
[2026-11-10T21:26:53Z] PASS: pvc-2980fe5b-0512-401f-b475-fd3d3a77ffa9 out-of-sync=0 percent-in-sync=100.00
[2026-11-10T21:27:23Z] === verify pvc-2a0f9a6d-c101-405b-938e-f41015e8db15 ===
[2026-11-10T21:27:53Z] PASS: pvc-2a0f9a6d-c101-405b-938e-f41015e8db15 out-of-sync=0 percent-in-sync=100.00
[2026-11-10T21:28:23Z] === verify pvc-3ccf9ad4-07b3-4472-b3db-cc4628b93300 ===
[2026-11-10T21:29:24Z] PASS: pvc-3ccf9ad4-07b3-4472-b3db-cc4628b93300 out-of-sync=0 percent-in-sync=100.00
[2026-11-10T21:29:54Z] === verify pvc-3ec820ea-8b34-42d0-9e8a-344e90ed1b6c ===
[2026-11-10T21:30:24Z] PASS: pvc-3ec820ea-8b34-42d0-9e8a-344e90ed1b6c out-of-sync=0 percent-in-sync=100.00
[2026-11-10T21:30:54Z] === verify pvc-4bb30f70-1d1f-4f3c-bf74-3ef233c9b10a ===
[2026-11-10T21:31:25Z] PASS: pvc-4bb30f70-1d1f-4f3c-bf74-3ef233c9b10a out-of-sync=0 percent-in-sync=100.00
[2026-11-10T21:31:55Z] === verify pvc-52ee0aee-2ad5-4a99-99fc-05686629cc82 ===
[2026-11-10T21:32:25Z] PASS: pvc-52ee0aee-2ad5-4a99-99fc-05686629cc82 out-of-sync=0 percent-in-sync=100.00
[2026-11-10T21:32:55Z] === verify pvc-5502b865-feae-434d-8a26-c0b9fc4e0556 ===
[2026-11-10T21:33:26Z] PASS: pvc-5502b865-feae-434d-8a26-c0b9fc4e0556 out-of-sync=0 percent-in-sync=100.00
[2026-11-10T21:33:56Z] === verify pvc-5c5f4d81-cdfe-4e99-915b-d53c78d3a963 ===
[2026-11-10T21:34:26Z] PASS: pvc-5c5f4d81-cdfe-4e99-915b-d53c78d3a963 out-of-sync=0 percent-in-sync=100.00
[2026-11-10T21:34:56Z] === verify pvc-61e61c37-e760-412a-b6bf-8ce7f79ebd2b ===
[2026-11-10T21:35:27Z] PASS: pvc-61e61c37-e760-412a-b6bf-8ce7f79ebd2b out-of-sync=0 percent-in-sync=100.00
[2026-11-10T21:35:57Z] === verify pvc-65516952-90d0-4b43-bb52-b40d090499e7 ===
[2026-11-10T21:36:27Z] PASS: pvc-65516952-90d0-4b43-bb52-b40d090499e7 out-of-sync=0 percent-in-sync=100.00
[2026-11-10T21:36:57Z] === verify pvc-66ca7fb9-1b01-47f5-bb27-d3bfea611cf3 ===
[2026-11-10T21:37:27Z] PASS: pvc-66ca7fb9-1b01-47f5-bb27-d3bfea611cf3 out-of-sync=0 percent-in-sync=100.00
[2026-11-10T21:37:57Z] === verify pvc-6801d6f5-7d54-4cc4-b81e-656276a6cd09 ===
[2026-11-10T21:38:28Z] PASS: pvc-6801d6f5-7d54-4cc4-b81e-656276a6cd09 out-of-sync=0 percent-in-sync=100.00

# linstor-satellite.rpi-00 restart loop (fixed 2026-11-21)

`linstor-satellite.rpi-00` accumulated 95 container restarts between 2026-10-13 and
2026-11-07 02:57Z (stable since; exit code 143 = kubelet SIGTERM). Prometheus could not
show it (`retention: 14d`, the loop ended right at the retention edge); Loki's event stream
(`k8s_resource_type="events"`) did:

```
Unhealthy | Startup probe failed: dial tcp <pod-ip>:3366: connect: connection refused  (x268)
Killing   | Container linstor-satellite failed liveness probe, will be restarted
```

Cause: operator default probes (tcp :3366, `periodSeconds: 10`, `failureThreshold: 3`,
`timeoutSeconds: 1`) allow ~20s, but Java 25 needs ~25s to log
`NetComService started on port ...:3366` on this Pi (~81% CPU avg, load1 ~1.9). Kubelet
SIGTERM'd the container, backoff made the next start colder, loop sustained itself.

Fix: probe overrides in the rpi-00 `LinstorSatelliteConfiguration`
(`kubernetes/infra/piraeus-datastore/piraeus-datastore/_base/values.yaml`) - startup
5min (30x10s, 5s timeout), liveness 6x30s with 5s timeout. Memory limit untouched
(~260Mi of 512Mi in use).

- [ ] Decide whether to widen the same probes for c-01/c-02 via `talos-loader-override`
      (safe, but it rolls the storage satellites one at a time and severs DRBD connections -
      check `drbdsetup status` in a satellite pod afterwards)
- [ ] Verify after Flux reconciles: the pod must show the new probes and no new
      `Startup probe failed` events; restart counter must stay 0

Related noise, not the cause: rpi-00 logs `Could not determine block device information for
storage pool 'ssd-lvm-thin': Failed to create lvm volume` every ~3min. It is FullSync
applying c-01/c-02's pool definitions (c-01 logs the same for c-02's pools; LINSTOR only
knows `DfltDisklessStorPool` on rpi-00). Noise, but it keeps the Pi doing LVM work.
