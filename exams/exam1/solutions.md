# RHCSA mock exam 1: solutions

One way to solve each task. Other ways are fine, the grader only checks the result.

**1. Root password (node2 console)**
Reboot, in the boot menu press `e`, add `init=/bin/bash` to the end of the `linux` line, `Ctrl+x`.
```bash
mount -o remount,rw /
passwd root                     # redhat
touch /.autorelabel             # without this, SELinux blocks the login after the reboot
exec /sbin/init                 # continue booting (the relabel reboots once more)
```
On RHEL 8 and 9 this was often done with `rd.break` and `chroot /sysroot`. On RHEL 10,
`init=/bin/bash` is the reliable way.

**2. Network (node2 console)**
```bash
nmcli connection show                       # the connection is named like the interface
nmcli connection modify eth0 ipv4.method manual ipv4.addresses 10.78.0.12/24 \
  ipv4.gateway 10.78.0.1 ipv4.dns 10.78.0.10
nmcli connection up eth0
hostnamectl set-hostname node2.lab.example
```
(`eth0` = the name from `nmcli connection show`.) From now on you can use `ssh root@10.78.0.12`.

**3. Repositories (both nodes)**
```bash
cat >/etc/yum.repos.d/lab.repo <<'EOF'
[BaseOS]
name=BaseOS
baseurl=http://utility.lab.example/repo/BaseOS
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-AlmaLinux-10

[AppStream]
name=AppStream
baseurl=http://utility.lab.example/repo/AppStream
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-AlmaLinux-10
EOF
dnf repolist
```
On a real RHEL exam the key is `/etc/pki/rpm-gpg/RPM-GPG-KEY-redhat-release`. If the exam
doesn't mention a key, `gpgcheck=0` is fine too.

**4. Users and groups**
```bash
groupadd -g 3000 sysops
useradd -G sysops natasha
useradd -G sysops harry
useradd -s /sbin/nologin sarah
for u in natasha harry sarah; do echo "$u:kubl123" | chpasswd; done
```

**5. sudo**
```bash
echo '%sysops ALL=(ALL) NOPASSWD: ALL' >/etc/sudoers.d/sysops
chmod 440 /etc/sudoers.d/sysops          # with 644, visudo -c reports "bad permissions"
visudo -c
```

**6. Shared directory**
```bash
mkdir -p /common/sysops
chgrp sysops /common/sysops
chmod 2770 /common/sysops
```

**7. Password aging**
```bash
vim /etc/login.defs              # PASS_MAX_DAYS 90
chage -M 30 harry
```

**8. Default permissions**
```bash
echo 'umask 027' >>/home/natasha/.bashrc
su - natasha -c umask            # 0027
```

**9. Cron**
```bash
crontab -e -u natasha
# 23 14 * * * logger "kubl daily check"
```

**10. Time**
```bash
vim /etc/chrony.conf             # comment out the pool line, add: server utility.lab.example iburst
systemctl restart chronyd
chronyc sources
```

**11. autofs**
```bash
dnf -y install autofs nfs-utils
echo '/rhome /etc/auto.rhome' >/etc/auto.master.d/rhome.autofs
echo 'remoteuser1 -rw utility.lab.example:/rhome/remoteuser1' >/etc/auto.rhome
systemctl enable --now autofs
su - remoteuser1 -c pwd          # /rhome/remoteuser1
```

**12. SELinux**
```bash
vim /etc/selinux/config          # SELINUX=enforcing
setenforce 1
```

**13. Web server**
```bash
systemctl status httpd           # with SELinux enforcing: can't bind to port 82
semanage port -a -t http_port_t -p tcp 82
ls -Z /var/www/html/index.html   # admin_home_t, wrong
restorecon -v /var/www/html/index.html
systemctl enable --now httpd; systemctl restart httpd
firewall-cmd --permanent --add-port=82/tcp; firewall-cmd --reload
```

**14. Find files**
```bash
mkdir /root/found
find / -user jacques -type f -exec cp {} /root/found/ \; 2>/dev/null
```

**15. Search text**
```bash
grep ERROR /var/log/kubl/app.log >/root/errors.txt
```

**16. Archive**
```bash
tar -cjf /root/local.tar.bz2 /usr/local
```

**17. Shell script**
```bash
#!/bin/bash
if [ $# -eq 0 ]; then
  echo "Usage: userinfo USER..."
  exit 1
fi
for user in "$@"; do
  if id "$user" &>/dev/null; then
    echo "$user: $(id -u "$user") $(getent passwd "$user" | cut -d: -f6)"
  else
    echo "$user: not found"
  fi
done
```
`chmod +x /usr/local/bin/userinfo`

**18. Logical volume**
```bash
parted -s /dev/vdb mklabel gpt mkpart data 1MiB 100% set 1 lvm on
pvcreate /dev/vdb1
vgcreate -s 16M datavg /dev/vdb1
lvcreate -l 20 -n datalv datavg
mkfs.xfs /dev/datavg/datalv
mkdir /data
blkid /dev/datavg/datalv         # UUID
echo 'UUID=<the uuid> /data xfs defaults 0 0' >>/etc/fstab
systemctl daemon-reload; mount -a; df -h /data
```

**19. Grow a logical volume**
```bash
lvextend -r -L 800M /dev/appvg/applv     # -r grows the ext4 filesystem too
```

**20. Swap**
```bash
parted -s /dev/vdc print                 # vdc1 ends at 2049MiB
parted -s /dev/vdc mkpart swap linux-swap 2049MiB 2561MiB
mkswap /dev/vdc2                         # prints the UUID
echo 'UUID=<the uuid> none swap defaults 0 0' >>/etc/fstab
systemctl daemon-reload; swapon -a; swapon --show
```

**21. Tuning**
```bash
tuned-adm recommend
tuned-adm profile virtual-guest          # whatever recommend said
```

**22. Journal**
```bash
mkdir /var/log/journal                   # or Storage=persistent in /etc/systemd/journald.conf
systemctl restart systemd-journald
```

**23. Process priority**
```bash
ps -o pid,ni,cmd -C report-builder       # NI 0
systemctl edit report-builder            # add:  [Service]
                                         #       Nice=10
systemctl restart report-builder
ps -o pid,ni,cmd -C report-builder       # NI 10
```
`renice -n 10 -p <PID>` changes it only until the next restart, so it fails after the reboot.

**24. systemd timer**
```bash
cat >/etc/systemd/system/kubl-cleanup.service <<'EOF'
[Unit]
Description=Delete old tmp files

[Service]
Type=oneshot
ExecStart=/usr/bin/find /var/tmp -name *.tmp -delete
EOF
cat >/etc/systemd/system/kubl-cleanup.timer <<'EOF'
[Unit]
Description=Hourly tmp cleanup

[Timer]
OnCalendar=hourly

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now kubl-cleanup.timer
```
(In `ExecStart=` systemd doesn't expand `*`, so `*.tmp` reaches `find` as it should.)

**25. SSH keys**
```bash
# on node1
su - deploy
ssh-keygen                               # Enter, Enter, Enter
ssh-copy-id deploy@node2.lab.example     # password kubl123
ssh node2.lab.example hostname           # no password asked
```
