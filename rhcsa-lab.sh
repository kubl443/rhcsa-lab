#!/usr/bin/env bash
# kubl-labs: RHCSA practice lab on Proxmox VE (run as root on the Proxmox host)
#
#   bash rhcsa-lab.sh create    utility + node1 + node2 (AlmaLinux 10 = RHEL 10 compatible), snapshot "clean"
#   bash rhcsa-lab.sh exam 1    reset and start mock exam 1, then: bash rhcsa-lab.sh grade
#   bash rhcsa-lab.sh reset     back to the snapshot "clean"
#   bash rhcsa-lab.sh destroy   delete the lab
#
# Login on all VMs: root / redhat   (ssh root@10.78.0.11, or the console in the Proxmox web UI)
set -euo pipefail

# ---- settings: change here or set as environment variables -------------------
LAB="rhcsa"
NET="${NET:-10.78.0}"                 # lab network ${NET}.0/24, gateway ${NET}.1
VNET="${VNET:-kublrh}"                # Proxmox SDN VNet (max. 8 characters)
VMID_START="${VMID_START:-5000}"      # the VMs get the first free VMIDs from here on
UTIL_MEM="${UTIL_MEM:-1536}"
NODE_MEM="${NODE_MEM:-2048}"
ROOT_PASSWORD="redhat"
CLOUD_USER="student"                  # only used during "create", deleted afterwards
CLOUD_PASSWORD="student"
DOMAIN="lab.example"
# AlmaLinux 10 needs a CPU with x86-64-v3 (most CPUs since 2015). For older CPUs use the
# x86_64_v2 image and repos: replace x86_64 with x86_64_v2 in both URLs.
IMG_URL="${IMG_URL:-https://repo.almalinux.org/almalinux/10/cloud/x86_64/images/AlmaLinux-10-GenericCloud-latest.x86_64.qcow2}"
REPO_URL="${REPO_URL:-https://repo.almalinux.org/almalinux/10}"   # utility serves it as http://utility.lab.example/repo/
REPO_ARCH="${REPO_ARCH:-x86_64}"
BUS="virtio"                          # disks are /dev/vda, /dev/vdb, /dev/vdc like in the exam
VM_OPTS=()                            # normal VGA console: you need it to interrupt the boot
GRADE_REBOOT="node1 node2"
LAB_HELP="
  bash $(basename "$0") grade --no-reboot   grade without rebooting node1 and node2 first"

#        name           ip  memory     disks (first = system disk)
NODES=("rhcsa-utility   10  $UTIL_MEM  20G"
       "rhcsa-node1     11  $NODE_MEM  20G,5G,5G"
       "rhcsa-node2     12  $NODE_MEM  20G,5G,5G")
# -------------------------------------------------------------------------------

LIB="$(dirname "$0")/lib/lab.sh"
[[ -f "$LIB" ]] || { echo "lib/lab.sh not found: clone the whole repository, not only this script" >&2; exit 1; }
# shellcheck source=lib/lab.sh
source "$LIB"

# ==== inside the VMs (run as root) =============================================

# All three VMs: a plain RHEL-like server with root login, firewalld, tuned, chrony.
guest_base() {
  local vm="$1" ip="$2" rootpw="$3" hosts="$4" domain="$5" cloud_user="$6" a dev con
  cloud-init status --wait >/dev/null 2>&1 || true

  hostnamectl set-hostname "${vm#rhcsa-}.$domain"
  printf '%s\n' "$hosts" >>/etc/hosts

  # root logs in with a password, like in the exam; the cloud-init user goes away
  echo "root:$rootpw" | chpasswd
  printf 'PermitRootLogin yes\nPasswordAuthentication yes\n' >/etc/ssh/sshd_config.d/00-lab.conf
  systemctl restart sshd
  userdel -rf "$cloud_user" 2>/dev/null || true
  rm -f /etc/sudoers.d/90-cloud-init-users

  # what a normal server install has (autofs, nfs-utils, httpd ... you install yourself)
  dnf -y -q install vim-enhanced bash-completion man-pages man-db tar bzip2 lvm2 parted \
    firewalld tuned chrony cronie policycoreutils-python-utils python3
  systemctl enable --now firewalld tuned chronyd crond

  # boot menu for 5 seconds and boot messages on the normal console (Proxmox web UI),
  # so you can interrupt the boot to reset a root password
  for a in $(grubby --info=DEFAULT | sed -n 's/^args="\(.*\)"$/\1/p'); do
    [[ "$a" == console=ttyS* ]] && grubby --update-kernel=ALL --remove-args="$a"
  done
  sed -i -e 's/console=ttyS[^ "]*//g' -e 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=5/' /etc/default/grub
  grep -q '^GRUB_TIMEOUT_STYLE=' /etc/default/grub && sed -i 's/^GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=menu/' /etc/default/grub
  grub2-editenv - unset menu_auto_hide || true
  grub2-mkconfig -o /boot/grub2/grub.cfg >/dev/null 2>&1

  # name the network connection like its interface (nicer than "cloud-init eth0")
  dev="$(ip -o -4 route show default | awk 'NR == 1 {print $5}')"
  con="$(nmcli -g GENERAL.CONNECTION device show "$dev")"
  [[ "$con" == "$dev" ]] || nmcli connection modify "$con" connection.id "$dev"

  # from now on cloud-init must not touch the VM anymore
  touch /etc/cloud/cloud-init.disabled
}

# The utility server: package repos, NFS, DNS and NTP for the lab.
guest_utility() {
  local vm="$1" ip="$2" net="$3" domain="$4" upstream="$5" repo="$6" arch="$7" u
  dnf -y -q install httpd mod_ssl nfs-utils dnsmasq

  # repos: http://utility.lab.example/repo/BaseOS and /repo/AppStream, passed through from the mirror
  cat >/etc/httpd/conf.d/lab-repo.conf <<EOF
SSLProxyEngine on
ProxyPass        /repo/BaseOS/    $repo/BaseOS/$arch/os/
ProxyPassReverse /repo/BaseOS/    $repo/BaseOS/$arch/os/
ProxyPass        /repo/AppStream/ $repo/AppStream/$arch/os/
ProxyPassReverse /repo/AppStream/ $repo/AppStream/$arch/os/
EOF
  echo "kubl-labs utility server" >/var/www/html/index.html
  setsebool -P httpd_can_network_connect on
  systemctl enable --now httpd

  # NFS: home directories for autofs (/rhome) and a read-only share (/shared)
  mkdir -p /rhome /shared
  for u in 1 2; do
    useradd -u "150$u" -d "/rhome/remoteuser$u" -m "remoteuser$u"
    echo "remoteuser$u:kubl123" | chpasswd
  done
  echo "Hello from utility.$domain" >/shared/README.txt
  printf '/rhome   %s.0/24(rw,sync)\n/shared  %s.0/24(ro,sync)\n' "$net" "$net" >/etc/exports
  systemctl enable --now nfs-server

  # DNS for lab.example (names from /etc/hosts), everything else goes to the host's DNS
  cat >/etc/dnsmasq.conf <<EOF
user=dnsmasq
group=dnsmasq
listen-address=127.0.0.1,$ip
bind-dynamic
no-resolv
server=$upstream
domain=$domain
local=/$domain/
expand-hosts
EOF
  systemctl enable --now dnsmasq

  # NTP server for the lab
  printf 'allow %s.0/24\nlocal stratum 8\n' "$net" >>/etc/chrony.conf
  systemctl restart chronyd

  firewall-cmd -q --permanent --add-service={http,nfs,mountd,rpc-bind,dns,ntp}
  firewall-cmd -q --reload

  curl -fsS -o /dev/null "http://localhost/repo/BaseOS/repodata/repomd.xml" || { echo "the repo proxy doesn't work"; exit 1; }
}

# node1 and node2 use the utility server for DNS.
guest_node() {
  local vm="$1" ip="$2" dns="$3" domain="$4" dev i
  dev="$(ip -o -4 route show default | awk 'NR == 1 {print $5}')"
  nmcli connection modify "$dev" ipv4.dns "$dns" ipv4.dns-search "$domain" ipv4.ignore-auto-dns yes
  nmcli device reapply "$dev" || nmcli connection up "$dev"
  for ((i = 0; i < 10; i++)); do getent ahosts almalinux.org >/dev/null && return 0; sleep 3; done
  echo "DNS through the utility server doesn't work"; exit 1
}

# ==== hooks for lib/lab.sh =====================================================

lab_options() { [[ $# -eq 0 ]] || die "unknown option $1"; }

lab_build() {
  local n ip hosts="" upstream
  for n in "${NODES[@]}"; do
    read -r n ip _ <<<"$n"; n="${n#rhcsa-}"
    hosts+="$NET.$ip $n.$DOMAIN $n"$'\n'
  done
  upstream="$(awk '/^nameserver/ && $2 !~ /^127\./ {print $2; exit}' /etc/resolv.conf)"

  say "Setting up the servers (packages, root login, boot menu)"
  on_all guest_base "$ROOT_PASSWORD" "${hosts%$'\n'}" "$DOMAIN" "$CLOUD_USER"
  say "Setting up the utility server (repos, NFS, DNS, NTP)"
  on_nodes utility guest_utility "$NET" "$DOMAIN" "${upstream:-1.1.1.1}" "$REPO_URL" "$REPO_ARCH"
  say "Pointing node1 and node2 to the utility server"
  on_nodes "node1 node2" guest_node "$NET.10" "$DOMAIN"
}

lab_wait() { :; }

lab_summary() {
  cat <<EOF

  Lab is ready.

    utility.$DOMAIN   $NET.10   repos, NFS, DNS, NTP (you don't work on this one)
    node1.$DOMAIN     $NET.11   exam node
    node2.$DOMAIN     $NET.12   exam node, extra disks /dev/vdb and /dev/vdc

    Login:    root / redhat        e.g.  ssh root@$NET.11   (from this Proxmox host)
              or the console of the VM in the Proxmox web UI
    Practice: bash $SCRIPT exam
    Reset:    bash $SCRIPT reset
    Delete:   bash $SCRIPT destroy

EOF
}

lab_main "$@"
