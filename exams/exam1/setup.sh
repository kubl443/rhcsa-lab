# shellcheck shell=bash
# RHCSA mock exam 1: brings node1 and node2 into the starting state.
# Spoilers: don't read this before you did the exam.

run node1 <<'EOF'
# task 12/13: web server on port 82, page with the wrong SELinux label, SELinux permissive
setenforce 0
sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config
dnf -y -q install httpd
sed -i 's/^Listen 80$/Listen 82/' /etc/httpd/conf/httpd.conf
echo '<h1>kubl-labs node1</h1>' >/root/index.html
mv /root/index.html /var/www/html/index.html
systemctl enable --now httpd

# task 14: files of jacques all over the system
useradd -M -u 2050 -s /sbin/nologin jacques
rm -f /var/spool/mail/jacques   # useradd creates a mail spool, the task expects only the 5 files below
for f in /var/tmp/jacques-report.txt /opt/inventory.csv /usr/local/share/notes.md /etc/jacques.conf /srv/backup.log; do
  echo "written by jacques: $f" >"$f"
  chown jacques "$f"
done

# task 15: a log file
mkdir -p /var/log/kubl
for i in $(seq 1 59); do
  case $((i % 7)) in
    0) printf '2026-11-20 10:%02d ERROR disk check failed on job %d\n' "$i" "$i" ;;
    3) printf '2026-11-20 10:%02d WARN slow response (%d ms), no error\n' "$i" "$((i * 40))" ;;
    *) printf '2026-11-20 10:%02d INFO job %d done\n' "$i" "$i" ;;
  esac
done >/var/log/kubl/app.log

# task 16: something to archive
mkdir -p /usr/local/share/kubl
echo "kubl-labs archive marker" >/usr/local/share/kubl/marker.txt

# task 11: the user whose home is on utility (UID like there)
useradd -M -u 1501 -d /rhome/remoteuser1 remoteuser1
echo remoteuser1:kubl123 | chpasswd

# task 25: user for the SSH keys
useradd deploy
echo deploy:kubl123 | chpasswd

# task 3: no repositories
rm -f /etc/yum.repos.d/*.repo
dnf clean all >/dev/null
EOF

run node2 <<'EOF'
# task 19/20: appvg on /dev/vdc1 (2 GiB) with applv (400 MiB, ext4) at /app, rest of vdc free
parted -s /dev/vdc mklabel gpt mkpart appvg 1MiB 2049MiB set 1 lvm on
udevadm settle
pvcreate -q /dev/vdc1
vgcreate -q appvg /dev/vdc1
lvcreate -q -y -n applv -L 400M appvg
mkfs.ext4 -q /dev/appvg/applv
mkdir -p /app
echo "UUID=$(blkid -s UUID -o value /dev/appvg/applv) /app ext4 defaults 0 0" >>/etc/fstab
systemctl daemon-reload
mount /app
echo "important data, don't lose it" >/app/important.txt

# task 23: a quiet service (sleeps, no CPU load) that runs with the normal priority
cat >/usr/local/bin/report-builder <<'SCRIPT'
#!/bin/bash
# pretends to build reports, just sleeps
while true; do sleep 60; done
SCRIPT
chmod 755 /usr/local/bin/report-builder
cat >/etc/systemd/system/report-builder.service <<'UNIT'
[Unit]
Description=Nightly report builder

[Service]
ExecStart=/usr/local/bin/report-builder

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now report-builder

# task 21: not the recommended tuned profile
tuned-adm profile powersave

# task 22: journal only in memory (Storage=auto without /var/log/journal, the RHEL default)
sed -i 's/^Storage=/#Storage=/' /etc/systemd/journald.conf /etc/systemd/journald.conf.d/*.conf 2>/dev/null || true
rm -rf /var/log/journal
systemctl restart systemd-journald

# task 25: user for the SSH keys
useradd deploy
echo deploy:kubl123 | chpasswd

# task 3: no repositories
rm -f /etc/yum.repos.d/*.repo
dnf clean all >/dev/null

# task 1: nobody knows the root password
echo "root:$(head -c 18 /dev/urandom | base64)" | chpasswd

# task 2: wrong address, no gateway, no DNS, no hostname. Applied 3 s after this script ends.
sed -i '/lab\.example/d' /etc/hosts
hostnamectl set-hostname localhost.localdomain
dev="$(ip -o -4 route show default | awk 'NR == 1 {print $5}')"
nmcli connection modify "$dev" ipv4.method manual ipv4.addresses "$LAB_NET.112/24" \
  ipv4.gateway "" ipv4.dns "" ipv4.dns-search ""
systemd-run -q --on-active=3 nmcli connection up "$dev"
EOF
