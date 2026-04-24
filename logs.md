# TODO:
- [x] Piraeus - Linstor
- [x] Via VolumeSnapshot recreate PV in different storageclass
- [x] Set-up monitoring stack
- [x] Set-up resource requests and limits for all resources
    - [x] Analysis to what extent we can automate this, e.g. krr -> docker run --net host --rm -t --volume ./kubeconfig:/root/.kube/config us-central1-docker.pkg.dev/genuine-flight-317411/devel/krr:v1.8.3 python krr.py simple --prometheus-url http://localhost:9090 --mem-min 20
    - [x] Fix resources in kube-system
- [x] Remove sops-age from namespaces that don't need it
- [x] Velero back-up snapshots to Cloud
- [x] Velero set-up scheduled backups
- [x] Linstor doesn't delete S3 back-ups when VS is deleted. (multiple open issues found)
- [x] Velero perform full cluster restore -> https://linbit.com/blog/abstracting-persistent-storage-across-environments-with-linbit-sds/
- [x] Fix custom RPI PWM Fan implementation https://github.com/siderolabs/sbc-raspberrypi/issues/58
- [x] Create Velero logic such that specific PV's / PVC's are not included in the (remote) back-up. -> Label PVC: velero.io/exclude-from-backup=true
- [x] Set-up proper MySQL server back-ups
- [x] Set-up PSQL operator for Postgres databases
- [ ] Set-up KeyCloak as OIDC issuer
    - [x] Set-up KeyCloak operator
    - [x] https://www.keycloak.org/operator/basic-deployment
        - [x] Set-up PSQL database
- [/] Set-up Harbor OCI registry, public access?
    - [x] first version running
    - [x] Connect to OIDC for authentication and authorization.
        - [x] Add some other groups next to admin
    - [ ] Set-up dedicated PSQL database
- [?] Set-up valkey operator
- [?] Set-up S3 compatible object storage
- [/] Set-up netbird
    - [x] tmp set-up with direct deployment
    - [ ] fix the kubernetes-operator + netbird-operator-config charts

- [ ] Set-up Alloy log collection + Loki log storage
- [ ] Set-up intrusion detection with Falco
- [ ] Enable hubble exporting of network traffic to be able visualized in monitoring tools
- [ ] Adding netpol for prometheus target scraping (flux-operator triggers alert atm for being down due to this)
- [ ] Set resources Velero, api-server, scheduler, controller manager
- [ ] Switch from ghcr.io/wiremind/wiremind-helm-charts/gateway-api-crds to official gateway-api-crd (if possible)
- [ ] Fix ETCD grafana dashboard
- [ ] Run a recurring verify on the Kopia back-ups https://kopia.io/docs/advanced/consistency/
- [ ] Run a recurring ZFS check and enable notification from smartctl for disk health (or via prometheus) -> scrutiny?
- [ ] FluxCD diffing -> fix pipelines
- [/] Set-up a notification channel https://ntfy.sh/ looks promising
    - [ ] Set-up basic credentials
- [ ] Wordpress updates
    - [ ] Run wordpress as non-root
    - [ ] Migrate from MySQL to MariaDB
- [ ] Set-up Windows on Kubernetes: https://github.com/dockur/windows
- [ ] Add interactive Velero bootstrap step to restore from latest found S3 back-up
- [ ] Velero perform new full cluster restore, remote back-ups are now controlled by Velero data-mover and not by Linstor
- [ ] Set-up barmancloud cnpg backup/restore pluging (needs S3 object storage)
- [ ] Set application priorities and evictions in case MS-S1 Max shuts down
    - [/] Set-up priority classes
    - [ ] Test if it actually works
- [ ] https://github.com/miniflux/v2/tree/main -> rss feed viewer
- [ ] Schlink, link shortener
- [ ] Posties, social media posting
- [ ] it-tools
- [ ] scrypted NVR camera's

# ZFS storage pool
https://oneuptime.com/blog/post/2026-03-03-add-zfs-support-to-talos-linux/view
```
apt-get update && apt-get install -y zfsutils-linux
zpool list
zpool status {{pool}}
```

# Network policy approach:
Start in auditing mode:
- egress allow cluster DNS
- egress allow to world (not including 192.168.68.1/23)
- ingress allow from gateway
- egress deny cross-namespace
- ingress deny cross-namespace

# Read write speed-test
## rpi-00
### On PV:
/data # time dd if=/dev/zero bs=1024k of=./testfile count=1024
1024+0 records in
1024+0 records out
1073741824 bytes (1.0GB) copied, 112.313516 seconds, 9.1MB/s
real    1m 52.31s
user    0m 0.01s
sys     0m 7.38s

/data # time dd if=./testfile bs=1024k of=/dev/null count=1024
1024+0 records in
1024+0 records out
1073741824 bytes (1.0GB) copied, 30.542254 seconds, 33.5MB/s
real    0m 30.56s
user    0m 0.01s
sys     0m 3.03s

### On local storage:
/home # time dd if=/dev/zero bs=1024k of=./testfile count=1024
1024+0 records in
1024+0 records out
1073741824 bytes (1.0GB) copied, 91.162886 seconds, 11.2MB/s
real    1m 31.25s
user    0m 0.01s
sys     0m 3.03s

/home # time dd if=./testfile bs=1024k of=/dev/null count=1024
1024+0 records in
1024+0 records out
1073741824 bytes (1.0GB) copied, 31.084916 seconds, 32.9MB/s
real    0m 31.09s
user    0m 0.02s
sys     0m 2.96s

## c-01 (old proxmox, not current c-01)
### On PV:
/data # time dd if=/dev/zero bs=1024k of=./testfile count=1024
1024+0 records in
1024+0 records out
1073741824 bytes (1.0GB) copied, 22.736091 seconds, 45.0MB/s
real    0m 22.76s
user    0m 0.00s
sys     0m 1.08s

/data # time dd if=./testfile bs=1024k of=/dev/null count=1024
1024+0 records in
1024+0 records out
1073741824 bytes (1.0GB) copied, 8.094685 seconds, 126.5MB/s
real    0m 8.09s
user    0m 0.00s
sys     0m 0.81s

### On local storage:
/home # time dd if=/dev/zero bs=1024k of=./testfile count=1024
1024+0 records in
1024+0 records out
1073741824 bytes (1.0GB) copied, 7.288977 seconds, 140.5MB/s
real    0m 7.37s
user    0m 0.00s
sys     0m 0.42s

/home # time dd if=./testfile bs=1024k of=/dev/null count=1024
1024+0 records in
1024+0 records out
1073741824 bytes (1.0GB) copied, 3.529276 seconds, 290.1MB/s
real    0m 3.53s
user    0m 0.01s
sys     0m 0.34s

## On homelab HDD
time dd if=/dev/zero bs=1024k of=./testfile count=1024
1024+0 records in
1024+0 records out
1073741824 bytes (1.1 GB, 1.0 GiB) copied, 10.8816 s, 98.7 MB/s

real    0m10.886s
user    0m0.012s
sys     0m1.514s

time dd if=./testfile bs=1024k of=/dev/null count=1024
1024+0 records in
1024+0 records out
1073741824 bytes (1.1 GB, 1.0 GiB) copied, 6.27457 s, 171 MB/s

real    0m6.279s
user    0m0.003s
sys     0m0.605s

## On homelab SSD
time dd if=/dev/zero bs=1024k of=./testfile count=1024
1024+0 records in
1024+0 records out
1073741824 bytes (1.1 GB, 1.0 GiB) copied, 2.4214 s, 443 MB/s

real    0m2.424s
user    0m0.008s
sys     0m1.407s

time dd if=./testfile bs=1024k of=/dev/null count=1024
1024+0 records in
1024+0 records out
1073741824 bytes (1.1 GB, 1.0 GiB) copied, 0.442469 s, 2.4 GB/s

real    0m0.445s
user    0m0.001s
sys     0m0.310s
