# TODO:
- [x] Piraeus - Linstor
- [x] Via VolumeSnapshot recreate PV in different storageclass
- [/] Set-up monitoring stack
- [ ] Set-up resource requests and limits for all resources
- [ ] Velero back-up snapshots to Cloud
- [ ] FluxCD diffing -> fix pipelines


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

## c-01
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
