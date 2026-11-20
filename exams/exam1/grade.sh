# shellcheck shell=bash disable=SC2034
# RHCSA mock exam 1: grading. node1 and node2 were rebooted before (unless --no-reboot),
# so only what survives a reboot counts. Checks the result, not the commands you used.
PASS_PERCENT=70

task "1. node2: root password"
check 10 node2 "the root password is redhat" 'pw_ok root redhat'
check 5 node2 "/etc/shadow has its SELinux label (shadow_t)" '[[ "$(stat -c %C /etc/shadow)" == *:shadow_t:* ]]'

task "2. node2: network"
check 10 node2 "static address $NET.12/24, the wrong one is gone" <<'EOF'
dev="$(ip -o -4 addr show | awk -v a="$LAB_NET.12/24" '$4 == a {print $2; exit}')"
[[ -n "$dev" ]]
[[ "$(nmcli -g ipv4.method connection show "$(nmcli -g GENERAL.CONNECTION device show "$dev")")" == manual ]]
if ip -o -4 addr show | grep -q " $LAB_NET.112/"; then exit 1; fi
EOF
check 5 node2 "hostname node2.lab.example" '[[ "$(hostnamectl hostname)" == node2.lab.example ]]'
check 5 node2 "gateway $NET.1 and DNS server $NET.10" <<'EOF'
ip -4 route show default | grep -q "via $LAB_NET.1 "
dev="$(ip -o -4 addr show | awk -v a="$LAB_NET.12/24" '$4 == a {print $2; exit}')"
nmcli -g ipv4.dns connection show "$(nmcli -g GENERAL.CONNECTION device show "$dev")" | grep -q "$LAB_NET.10"
getent hosts utility.lab.example >/dev/null
EOF

task "3. Repositories"
for n in node1 node2; do
  check 10 "$n" "$n: BaseOS and AppStream from utility work" <<'EOF'
grep -rhs '^ *baseurl' /etc/yum.repos.d/ | grep -q '/repo/BaseOS'
grep -rhs '^ *baseurl' /etc/yum.repos.d/ | grep -q '/repo/AppStream'
dnf -q --setopt=skip_if_unavailable=False makecache >/dev/null
EOF
done

task "4. node1: users and groups"
check 3 node1 "group sysops has GID 3000" '[[ "$(getent group sysops | cut -d: -f3)" == 3000 ]]'
check 4 node1 "natasha and harry are in sysops" <<'EOF'
id -nG natasha | grep -qw sysops
id -nG harry | grep -qw sysops
EOF
check 4 node1 "sarah: no login shell, not in sysops" <<'EOF'
[[ "$(getent passwd sarah | cut -d: -f7)" == */nologin ]]
if id -nG sarah | grep -qw sysops; then exit 1; fi
EOF
check 4 node1 "the three passwords are kubl123" <<'EOF'
pw_ok natasha kubl123
pw_ok harry kubl123
pw_ok sarah kubl123
EOF

task "5. node1: sudo"
check 10 node1 "sysops members may run everything without password, sarah not" <<'EOF'
visudo -cq
sudo -l -U natasha | grep -Eq 'NOPASSWD: *ALL'
sudo -l -U harry | grep -Eq 'NOPASSWD: *ALL'
if sudo -l -U sarah | grep -q 'may run the following'; then exit 1; fi
EOF

task "6. node1: shared directory"
check 10 node1 "/common/sysops: group sysops, rwx for the group, nothing for others, setgid" \
  '[[ "$(stat -c "%G %a" /common/sysops)" == "sysops 2770" ]]'

task "7. node1: password aging"
check 5 node1 "new users: passwords expire after 90 days" 'grep -Eq "^PASS_MAX_DAYS[[:space:]]+90[[:space:]]*$" /etc/login.defs'
check 5 node1 "harry: password expires after 30 days" '[[ "$(getent shadow harry | cut -d: -f5)" == 30 ]]'

task "8. node1: default permissions"
check 10 node1 "natasha's umask is 027" '[[ "$(su - natasha -c umask 2>/dev/null | tail -n 1)" == 0027 ]]'

task "9. node1: cron job"
check 10 node1 "natasha runs logger every day at 14:23" \
  'crontab -l -u natasha | grep -Eq "^[[:space:]]*23[[:space:]]+14[[:space:]]+\*[[:space:]]+\*[[:space:]]+\*[[:space:]]+.*logger"'

task "10. node1: time"
check 5 node1 "chrony uses utility.lab.example" \
  'cat /etc/chrony.conf /etc/chrony.d/*.conf 2>/dev/null | grep -Eq "^(server|pool)[[:space:]]+(utility(\.lab\.example)?|$LAB_NET\.10)([[:space:]]|$)"'
check 5 node1 "chronyd runs, starts at boot and knows utility" <<'EOF'
systemctl is-enabled --quiet chronyd
systemctl is-active --quiet chronyd
chronyc -n sources | grep -q "$LAB_NET.10"
EOF

task "11. node1: autofs"
check 5 node1 "autofs runs and starts at boot" 'systemctl is-enabled --quiet autofs && systemctl is-active --quiet autofs'
check 10 node1 "remoteuser1's home is mounted from utility and writable" <<'EOF'
runuser -u remoteuser1 -- touch /rhome/remoteuser1/.kubl-grade
findmnt -n -o FSTYPE,SOURCE /rhome/remoteuser1 | grep -Eq '^nfs4?[[:space:]].*:/rhome/remoteuser1$'
EOF

task "12. node1: SELinux"
check 10 node1 "SELinux is enforcing, also after a reboot" <<'EOF'
[[ "$(getenforce)" == Enforcing ]]
grep -Eq '^SELINUX=enforcing' /etc/selinux/config
EOF

task "13. node1: web server"
check 10 utility "http://node1.lab.example:82/ shows the page (tested from utility)" \
  'curl -s --max-time 5 http://node1.lab.example:82/ | grep -q "kubl-labs node1"'
check 5 node1 "httpd starts at boot and serves the page with SELinux enforcing" <<'EOF'
[[ "$(getenforce)" == Enforcing ]]
systemctl is-enabled --quiet httpd
curl -s --max-time 5 http://localhost:82/ | grep -q "kubl-labs node1"
EOF

task "14. node1: find files"
check 10 node1 "/root/found has exactly the 5 files of jacques" <<'EOF'
[[ "$(ls -A /root/found | LC_ALL=C sort | tr '\n' ' ')" == "backup.log inventory.csv jacques-report.txt jacques.conf notes.md " ]]
for f in backup.log inventory.csv jacques-report.txt jacques.conf notes.md; do grep -q "written by jacques" "/root/found/$f"; done
EOF

task "15. node1: search text"
check 5 node1 "/root/errors.txt has the ERROR lines, in order" 'grep ERROR /var/log/kubl/app.log | cmp -s - /root/errors.txt'

task "16. node1: archive"
check 5 node1 "/root/local.tar.bz2 is a bzip2 tar of /usr/local" \
  'tar -tjf /root/local.tar.bz2 | grep -q "usr/local/share/kubl/marker.txt$"'

task "17. node1: shell script"
check 5 node1 "userinfo without arguments: usage message, exit code 1" <<'EOF'
test -x /usr/local/bin/userinfo
set +e; out="$(/usr/local/bin/userinfo 2>&1)"; rc=$?; set -e
[[ $rc -eq 1 && "$out" == *"Usage: userinfo"* ]]
EOF
check 10 node1 "userinfo root nosuchuser: the right output" <<'EOF'
out="$(/usr/local/bin/userinfo root nosuchuser 2>&1)"
[[ "$out" == "root: 0 /root"$'\n'"nosuchuser: not found" ]]
EOF

task "18. node2: new logical volume"
check 5 node2 "VG datavg on a partition of /dev/vdb, extent size 16 MiB" <<'EOF'
pvs --noheadings -o pv_name -S vg_name=datavg | grep -Eq '/dev/vdb[0-9]+'
[[ "$(vgs --noheadings --units m --nosuffix -o vg_extent_size datavg | tr -d ' ')" == 16.00 ]]
EOF
check 5 node2 "LV datalv has 20 extents (320 MiB)" \
  '[[ "$(lvs --noheadings --units m --nosuffix -o lv_size datavg/datalv | tr -d " ")" == 320.00 ]]'
check 5 node2 "datalv is XFS and mounted at /data" <<'EOF'
[[ "$(findmnt -n -o FSTYPE /data)" == xfs ]]
findmnt -n -o SOURCE /data | grep -q 'datavg-datalv'
EOF
check 5 node2 "/data is mounted at boot by UUID or LABEL" \
  'grep -Eq "^(UUID|LABEL)=[^[:space:]]+[[:space:]]+/data[[:space:]]+xfs" /etc/fstab'

task "19. node2: grow a logical volume"
check 5 node2 "applv is 760-840 MiB" <<'EOF'
size="$(lvs --noheadings --units m --nosuffix -o lv_size appvg/applv | tr -d ' ')"
(( ${size%.*} >= 760 && ${size%.*} <= 840 ))
EOF
check 5 node2 "the filesystem on /app uses the new size" \
  'size="$(df -m --output=size /app | tail -n 1 | tr -d " ")"; (( size >= 700 ))'
check 5 node2 "/app is mounted and important.txt is still there" 'grep -q "important data" /app/important.txt'

task "20. node2: swap"
check 10 node2 "a 512 MiB swap partition on /dev/vdc is active" <<'EOF'
swapon --show=NAME,SIZE --bytes --noheadings |
  awk '$1 ~ /^\/dev\/vdc[0-9]+$/ && $2 >= 480*1048576 && $2 <= 560*1048576 {f=1} END {exit !f}'
EOF
check 5 node2 "appvg on /dev/vdc1 is untouched" 'pvs --noheadings -o pv_name -S vg_name=appvg | grep -q "/dev/vdc1"'

task "21. node2: tuning"
check 5 node2 "the recommended tuned profile is active" \
  '[[ "$(tuned-adm active | sed "s/^.*: //")" == "$(tuned-adm recommend)" ]]'

task "22. node2: journal"
check 10 node2 "the journal is kept on disk" 'ls /var/log/journal/*/system.journal >/dev/null'

task "23. node2: process priority"
check 10 node2 "report-builder runs with nice 10, starts at boot, script unchanged" <<'EOF'
systemctl is-enabled --quiet report-builder
systemctl is-active --quiet report-builder
pid="$(systemctl show -p MainPID --value report-builder)"
[[ "$(ps -o ni= -p "$pid" | tr -d ' ')" == 10 ]]
grep -q 'while true; do sleep 60; done' /usr/local/bin/report-builder
EOF

task "24. node2: systemd timer"
check 5 node2 "kubl-cleanup.timer: hourly, active, starts at boot" <<'EOF'
systemctl is-enabled --quiet kubl-cleanup.timer
systemctl is-active --quiet kubl-cleanup.timer
systemctl cat kubl-cleanup.timer | grep -Eq '^(OnCalendar=[[:space:]]*(hourly|\*:0?0(:00)?|\*-\*-\* \*:00(:00)?)|OnUnitActiveSec=[[:space:]]*(1h|60min|3600s?))[[:space:]]*$'
EOF
check 5 node2 "kubl-cleanup.service deletes /var/tmp/*.tmp, nothing else" <<'EOF'
touch /var/tmp/kubl-grade.tmp /var/tmp/kubl-grade.keep
systemctl start kubl-cleanup.service
sleep 2
test ! -e /var/tmp/kubl-grade.tmp
test -e /var/tmp/kubl-grade.keep
rm -f /var/tmp/kubl-grade.keep
EOF

task "25. SSH keys"
check 10 node1 "deploy on node1 logs in to node2 as deploy without a password" \
  'runuser -u deploy -- ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 deploy@node2.lab.example true'
