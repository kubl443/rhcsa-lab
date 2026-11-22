# RHCSA mock exam 1: solutions

One way to solve each task, the way it's usually taught. Other ways are fine, the grader only
checks the result.

## node1

**1. Repositories**
```bash
dnf config-manager --add-repo=http://utility.lab.example/repo/BaseOS
dnf config-manager --add-repo=http://utility.lab.example/repo/AppStream
dnf repolist
```
If `dnf` complains about a GPG key, add `gpgcheck=0` to the two new files in
`/etc/yum.repos.d/`. You can also write one file yourself, e.g. `/etc/yum.repos.d/lab.repo`:
```ini
[BaseOS]
name=BaseOS
baseurl=http://utility.lab.example/repo/BaseOS
gpgcheck=0

[AppStream]
name=AppStream
baseurl=http://utility.lab.example/repo/AppStream
gpgcheck=0
```

**2. Users and groups**
```bash
groupadd -g 3000 sysops
useradd -G sysops natasha
useradd -G sysops harry
useradd -s /sbin/nologin sarah
passwd natasha          # type kubl123 twice
passwd harry
passwd sarah
```
For a user that already exists: `usermod -aG sysops natasha`. Without the `-a`, the user is
removed from all other supplementary groups.

**3. sudo**
```bash
visudo -f /etc/sudoers.d/sysops
```
with the line:
```
%sysops ALL=(ALL) NOPASSWD: ALL
```
`visudo` checks the syntax and sets the right permissions on the file.

**4. Shared directory**
```bash
mkdir -p /common/sysops
chown :sysops /common/sysops
chmod 2770 /common/sysops       # 2 = setgid: new files get the group of the directory
```

**5. Password aging**
```bash
vim /etc/login.defs             # PASS_MAX_DAYS   90
chage -M 30 harry
chage -l harry
```

**6. Default permissions**
```bash
echo 'umask 027' >> /home/natasha/.bashrc
su - natasha -c umask           # 0027
```

**7. Cron**
```bash
crontab -e -u natasha
```
```
23 14 * * * logger "kubl daily check"
```

**8. Time**
```bash
vim /etc/chrony.conf            # replace the pool line with:  server utility.lab.example iburst
systemctl restart chronyd
chronyc sources
```

**9. autofs**
```bash
dnf install autofs nfs-utils
vim /etc/auto.master.d/rhome.autofs
```
```
/rhome  /etc/auto.rhome
```
```bash
vim /etc/auto.rhome
```
```
remoteuser1  -rw  utility.lab.example:/rhome/remoteuser1
```
```bash
systemctl enable --now autofs
su - remoteuser1                # you land in /rhome/remoteuser1
```
For all users at once: `*  -rw  utility.lab.example:/rhome/&`

**10. SELinux**
```bash
vim /etc/selinux/config         # SELINUX=enforcing
setenforce 1
getenforce
```

**11. Web server**
```bash
systemctl status httpd          # with SELinux enforcing it can't use port 82
semanage port -a -t http_port_t -p tcp 82
ls -Z /var/www/html             # index.html has the wrong label (admin_home_t)
restorecon -Rv /var/www/html
systemctl enable httpd
systemctl restart httpd
firewall-cmd --permanent --add-port=82/tcp
firewall-cmd --reload
curl http://node1.lab.example:82/
```

**12. Find files**
```bash
mkdir /root/found
find / -user jacques -type f -exec cp {} /root/found/ \;
```

**13. Search text**
```bash
grep ERROR /var/log/kubl/app.log > /root/errors.txt
```

**14. Archive**
```bash
tar -cjf /root/local.tar.bz2 /usr/local
```

**15. Shell script**
```bash
vim /usr/local/bin/bigfiles
```
```bash
#!/bin/bash
mkdir -p /root/bigfiles
find /etc -type f -size +100k -exec cp {} /root/bigfiles/ \;
```
```bash
chmod +x /usr/local/bin/bigfiles
bigfiles
ls /root/bigfiles
```

## node2

**16. Root password (console)**
Reboot, in the boot menu press `e`, add `init=/bin/bash` to the end of the `linux` line, `Ctrl+x`.
```bash
mount -o remount,rw /
passwd root                     # redhat
touch /.autorelabel             # without this, SELinux blocks the login after the reboot
exec /sbin/init                 # continue booting (the relabel reboots once more)
```
On RHEL 8 and 9 this was often done with `rd.break` and `chroot /sysroot`. On RHEL 10,
`init=/bin/bash` is the reliable way.

**17. Network (console)**
```bash
nmcli connection show           # name of the connection, e.g. eth0
nmcli connection modify eth0 ipv4.method manual ipv4.addresses 10.78.0.12/24 \
  ipv4.gateway 10.78.0.1 ipv4.dns 10.78.0.10
nmcli connection up eth0
hostnamectl set-hostname node2.lab.example
```
Or with `nmtui`: "Edit a connection", set IPv4 to Manual, fill in address, gateway and DNS,
OK. Then "Activate a connection" off and on again. "Set system hostname" is in there too.
From now on you can use `ssh root@10.78.0.12`.

**18. Repositories**
Same as task 1.

**19. Logical volume**
```bash
parted /dev/vdb mklabel gpt
parted /dev/vdb mkpart data 1MiB 100%
parted /dev/vdb set 1 lvm on
pvcreate /dev/vdb1
vgcreate -s 16M datavg /dev/vdb1
lvcreate -l 20 -n datalv datavg
mkfs.xfs /dev/datavg/datalv
mkdir /data
blkid /dev/datavg/datalv        # copy the UUID
vim /etc/fstab                  # UUID=<uuid>  /data  xfs  defaults  0 0
systemctl daemon-reload
mount -a
df -h /data
```
`fdisk` or `gdisk` work as well for the partition.

**20. Grow a logical volume**
```bash
lvextend -r -L 800M /dev/appvg/applv    # -r grows the ext4 filesystem too
df -h /app
```
Without `-r`: run `resize2fs /dev/appvg/applv` afterwards.

**21. Swap**
```bash
parted /dev/vdc print                   # vdc1 ends at 2049MiB
parted /dev/vdc mkpart swap linux-swap 2049MiB 2561MiB
mkswap /dev/vdc2                        # shows the UUID
vim /etc/fstab                          # UUID=<uuid>  none  swap  defaults  0 0
systemctl daemon-reload
swapon -a
swapon --show
```

**22. Tuning**
```bash
tuned-adm recommend
tuned-adm profile virtual-guest         # whatever recommend said
tuned-adm active
```

**23. Journal**
```bash
mkdir /var/log/journal
systemctl restart systemd-journald
```
Or set `Storage=persistent` in `/etc/systemd/journald.conf` and restart it.

**24. Process priority**
```bash
ps -o pid,ni,cmd -C report-builder      # NI is 0
systemctl edit report-builder
```
```
[Service]
Nice=10
```
```bash
systemctl restart report-builder
ps -o pid,ni,cmd -C report-builder      # NI is 10
```
`renice` only changes the running process, after a reboot it's back to 0.

**25. systemd timer**
`vim /etc/systemd/system/kubl-cleanup.service`
```ini
[Unit]
Description=Delete tmp files in /var/tmp

[Service]
Type=oneshot
ExecStart=/usr/bin/find /var/tmp -name *.tmp -delete
```
`vim /etc/systemd/system/kubl-cleanup.timer`
```ini
[Unit]
Description=Run kubl-cleanup every hour

[Timer]
OnCalendar=hourly

[Install]
WantedBy=timers.target
```
```bash
systemctl daemon-reload
systemctl enable --now kubl-cleanup.timer
systemctl list-timers
```

## node1 and node2

**26. SSH keys**
```bash
su - deploy                     # on node1
ssh-keygen                      # Enter, Enter, Enter
ssh-copy-id node2.lab.example   # password kubl123
ssh node2.lab.example           # no password asked anymore
```
