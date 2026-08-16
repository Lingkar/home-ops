# ZFS storage pool
https://oneuptime.com/blog/post/2026-03-03-add-zfs-support-to-talos-linux/view
```
apt-get update && apt-get install -y zfsutils-linux sysstat
zpool list
zpool status {{pool}}
iostat -x 1 /dev/sdb1 /dev/sdc1
```
