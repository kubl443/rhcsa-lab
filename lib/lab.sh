# shellcheck shell=bash
# Shared lab code: Proxmox network, VMs, snapshots, mock exams and grading (sourced by rhcsa-lab.sh).
#
# The lab script sets LAB NET VNET DOMAIN NODES IMG_URL CLOUD_USER CLOUD_PASSWORD BUS VM_OPTS
# and defines these hooks:
#   lab_options [args]  parse the options of "create"
#   lab_build           install the lab (runs once the VMs are up and root can log in by key)
#   lab_wait            wait until the lab is usable after a boot
#   lab_summary         print how to log in
# Optional: REMOTE_ENV (shell lines run before every exam step and check), GRADE_REBOOT.

BASE="/root/kubl-labs"                       # images, and one folder per lab
DIR="$BASE/$LAB"                             # SSH key, logs, results, state of this lab
LOG="$DIR/logs"
ZONE="${ZONE:-kubl}"                         # Proxmox SDN zone (shared by the labs)
STORAGE="${STORAGE:-}"
CORES="${CORES:-2}"
SCRIPT="$(basename "${BASH_SOURCE[1]}")"
EXAMS="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)/exams"
REMOTE_ENV="LAB_NET=$NET; ${REMOTE_ENV:-}"
FMT=""

SSH=(ssh -i "$DIR/id_ed25519" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
     -o LogLevel=ERROR -o ConnectTimeout=5 -o ServerAliveInterval=10 -o ServerAliveCountMax=6)

say()  { printf '\e[1m==>\e[0m %s\n' "$*"; }
ok()   { printf '    \e[32m✓\e[0m %s\n' "$*"; }
die()  { printf '\e[31mError:\e[0m %s\n' "$*" >&2; FAILED=1; exit 1; }
on_exit() {
  local rc=$?
  [[ $rc -ne 0 && -z "${FAILED:-}" ]] && echo "Error: stopped unexpectedly. Logs: $LOG" >&2
  [[ $rc -ne 0 && -n "${STARTED:-}" ]] && echo "To start over: bash $SCRIPT destroy, then create again." >&2
  return 0
}
trap on_exit EXIT

usage() {
  cat <<EOF
kubl-labs $LAB lab on Proxmox VE (run as root on the Proxmox host)

  bash $SCRIPT create       build the lab, then take the snapshot "clean"
  bash $SCRIPT exam         list the mock exams
  bash $SCRIPT exam 1       reset the lab and start mock exam 1
  bash $SCRIPT grade        grade the running exam
  bash $SCRIPT reset        back to the snapshot "clean"
  bash $SCRIPT destroy      delete the lab
${LAB_HELP:-}
EOF
}

# ==== nodes ====================================================================
# NODES entries: "vmname  ip  memory  disks", e.g. "cka-cp1 11 4096 20G" or "rhcsa-node1 11 2048 20G,5G,5G"
# Nodes can be named with or without the lab prefix: "cka-cp1" or "cp1".

node_spec() {
  local n
  for n in "${NODES[@]}"; do
    [[ "${n%% *}" == "$1" || "${n%% *}" == "$LAB-$1" ]] && { echo "$n"; return 0; }
  done
  echo "unknown node: $1" >&2; return 1
}
node_ip()   { local s n ip; s="$(node_spec "$1")" || return 1; read -r n ip _ <<<"$s"; echo "$NET.$ip"; }
node_vm()   { local s; s="$(node_spec "$1")" || return 1; echo "${s%% *}"; }
all_nodes() { local n; for n in "${NODES[@]}"; do echo "${n%% *}"; done; }

# "VMID name" of the lab VMs: right name AND the tag kubl-labs
vm_list() {
  local id name n
  while read -r id name; do
    for n in "${NODES[@]}"; do
      [[ "$name" == "${n%% *}" ]] && grep -q '^tags:.*kubl-labs' <<<"$(qm config "$id" </dev/null)" && echo "$id $name"
    done
  done < <(qm list | awk 'NR>1 {print $1, $2}')
  return 0
}
vm_id() { vm_list | awk -v n="$1" '$2 == n {print $1}'; }

# ==== running things inside the VMs ============================================
# The script goes as an argument, so stdin stays free (no command can swallow the script).

remote_script() {  # remote_script IP 'script'   (as root)
  "${SSH[@]}" "root@$1" "bash -c $(printf '%q' "$2")" </dev/null
}

remote_fn() {  # remote_fn IP guest_fn [args]   runs one of the lab's guest_* functions
  local ip="$1"; shift
  # shellcheck disable=SC2046
  remote_script "$ip" "$(declare -f $(compgen -A function guest_))
set -euo pipefail
$(printf '%q ' "$@")"
}

on_nodes() {  # on_nodes "NODE..." guest_fn [args]  ->  guest_fn VMNAME IP [args], in parallel
  local nodes="$1" fn="$2" n vm pids=() vms=() fail=0 i; shift 2
  for n in $nodes; do
    vm="$(node_vm "$n")" || die "unknown node $n"
    remote_fn "$(node_ip "$n")" "$fn" "$vm" "$(node_ip "$n")" "$@" >>"$LOG/$vm.log" 2>&1 &
    pids+=($!); vms+=("$vm")
  done
  for i in "${!pids[@]}"; do
    if wait "${pids[$i]}"; then ok "${vms[$i]}"
    else fail=1; echo "    ${vms[$i]} failed, last lines of $LOG/${vms[$i]}.log:" >&2; tail -n 15 "$LOG/${vms[$i]}.log" >&2; fi
  done
  ((fail == 0)) || die "step $fn failed (logs: $LOG)"
}
on_all() { on_nodes "$(all_nodes)" "$@"; }

ssh_up() {  # ssh_up IP USER SECONDS
  local end=$((SECONDS + $3))
  while ((SECONDS < end)); do
    "${SSH[@]}" "$2@$1" true </dev/null 2>/dev/null && return 0
    sleep 5
  done
  return 1
}

wait_ssh() {  # wait_ssh [USER]
  local n
  for n in $(all_nodes); do
    ssh_up "$(node_ip "$n")" "${1:-root}" 450 || die "$n ($(node_ip "$n")) is not reachable via SSH"
  done
}

# Copy our key to root, from then on everything runs as root.
root_ssh() {
  local n
  for n in $(all_nodes); do
    "${SSH[@]}" "$CLOUD_USER@$(node_ip "$n")" \
      'sudo install -d -m 700 /root/.ssh && sudo install -m 600 ~/.ssh/authorized_keys /root/.ssh/authorized_keys' \
      </dev/null >>"$LOG/$n.log" 2>&1 || die "could not set up root login on $n (log: $LOG/$n.log)"
  done
}

# ==== the Proxmox host =========================================================

need_root() {
  [[ $EUID -eq 0 ]] && command -v qm >/dev/null || die "run this as root on a Proxmox VE host"
}

check_host() {
  need_root
  pvesh get /cluster/sdn >/dev/null 2>&1 || die "Proxmox VE 8.1 or newer is needed (SDN)"
  grep -q '^source /etc/network/interfaces.d/\*' /etc/network/interfaces ||
    die "add the line 'source /etc/network/interfaces.d/*' to /etc/network/interfaces (needed for Proxmox SDN)"
  if ip -4 -o addr | grep -v " $VNET " | grep " ${NET//./\\.}\." >/dev/null; then
    die "the network $NET.0/24 is already used on this host, choose another one: NET=10.99.0 bash $SCRIPT create"
  fi
}

# Own network: SDN zone $ZONE (simple, NAT) with the VNet $VNET. Only touches what this script
# created: it stops if a VNet with the same name already exists.
network_up() {
  check_sdn_pending
  if pvesh get "/cluster/sdn/vnets/$VNET" >/dev/null 2>&1; then
    [[ -f "$DIR/vnet" ]] ||
      die "a Proxmox SDN VNet '$VNET' already exists and was not created by kubl-labs. Use another name: VNET=name bash $SCRIPT create"
  else
    if pvesh get "/cluster/sdn/zones/$ZONE" >/dev/null 2>&1; then
      grep -q '"type":"simple"' <<<"$(pvesh get "/cluster/sdn/zones/$ZONE" --output-format json)" ||
        die "the SDN zone '$ZONE' exists but is not a simple zone. Use another name: ZONE=name bash $SCRIPT create"
    else
      pvesh create /cluster/sdn/zones --zone "$ZONE" --type simple --ipam pve --nodes "$(hostname -s)" >/dev/null
      touch "$BASE/zone-$ZONE"
    fi
    pvesh create /cluster/sdn/vnets --vnet "$VNET" --zone "$ZONE" >/dev/null
    touch "$DIR/vnet"
  fi
  pvesh get "/cluster/sdn/vnets/$VNET/subnets/$ZONE-$NET.0-24" >/dev/null 2>&1 ||
    pvesh create "/cluster/sdn/vnets/$VNET/subnets" --subnet "$NET.0/24" --type subnet --gateway "$NET.1" --snat 1 >/dev/null
  pvesh set /cluster/sdn >/dev/null
  sysctl -qw net.ipv4.ip_forward=1
  echo "net.ipv4.ip_forward=1" >/etc/sysctl.d/99-kubl-labs.conf
  local i
  for ((i = 0; i < 30; i++)); do grep -q "$NET.1/" <<<"$(ip -4 addr show dev "$VNET" 2>/dev/null)" && return; sleep 2; done
  die "the lab network $VNET did not come up (see Datacenter > SDN in the web UI)"
}

network_down() {
  [[ -f "$DIR/vnet" ]] || return 0
  check_sdn_pending
  pvesh delete "/cluster/sdn/vnets/$VNET/subnets/$ZONE-$NET.0-24" >/dev/null 2>&1 || true
  pvesh delete "/cluster/sdn/vnets/$VNET" >/dev/null 2>&1 || true
  # the marker goes only when the VNet is really gone, so a failed delete can be retried
  pvesh get "/cluster/sdn/vnets/$VNET" >/dev/null 2>&1 &&
    die "could not delete the SDN VNet $VNET, run destroy again (or delete it in Datacenter > SDN)"
  rm -f "$DIR/vnet"
  # the zone goes only if we created it and no other lab uses it anymore
  if [[ -f "$BASE/zone-$ZONE" ]] && pvesh delete "/cluster/sdn/zones/$ZONE" >/dev/null 2>&1; then
    rm -f "$BASE/zone-$ZONE" /etc/sysctl.d/99-kubl-labs.conf
  fi
  pvesh set /cluster/sdn >/dev/null 2>&1 || true
  ok "lab network removed"
}

# The VMs need the internet (packages). Test it once, right after boot, instead of failing
# 10 minutes later with a confusing DNS error.
check_internet() {
  local host="${IMG_URL#*://}"; host="${host%%/*}"
  remote_script "$(node_ip "${NODES[0]%% *}")" "curl -sS -o /dev/null --max-time 15 https://$host/" >>"$LOG/proxmox.log" 2>&1 ||
    die "the VMs can't reach the internet ($host). Often a firewall on this host drops forwarded traffic, see Troubleshooting in the README."
  ok "the VMs can reach the internet"
}

# Applying the SDN configuration applies ALL pending changes, so stop if something else is pending.
check_sdn_pending() {
  local kind
  for kind in zones vnets; do
    grep -q '"state"' <<<"$(pvesh get "/cluster/sdn/$kind" --pending 1 --output-format json 2>/dev/null)" &&
      die "there are pending SDN changes on this host (Datacenter > SDN). Apply or revert them first, the lab would apply them too."
  done
  return 0
}

# Storage for the disks. It must support snapshots, the whole reset idea depends on it.
pick_storage() {
  local all type
  all="$(pvesm status --content images | awk 'NR>1 && $3=="active" {print $1}')"
  if [[ -z "$STORAGE" ]]; then
    for STORAGE in local-lvm local-zfs $all ""; do [[ -n "$STORAGE" ]] && grep -qx "$STORAGE" <<<"$all" && break; done
    [[ -n "$STORAGE" ]] || die "no storage for VM disks found, set one: STORAGE=name bash $SCRIPT create"
  fi
  type="$(pvesm status --storage "$STORAGE" 2>/dev/null | awk 'NR==2 {print $2}')"
  case "$type" in
    "") die "storage $STORAGE not found" ;;
    lvm) die "storage $STORAGE (plain LVM) can't take snapshots, use another one: STORAGE=name bash $SCRIPT create" ;;
    dir | nfs | cifs | glusterfs | cephfs) FMT=",format=qcow2" ;;   # snapshots need qcow2 there
  esac
  ok "storage $STORAGE ($type)"
}

# Memory: hard stop. Disk: only a warning (thin storage needs much less than the full size).
check_resources() {
  local n mem need_mb=0 free_mb need_gb=0 free_gb disks d
  for n in "${NODES[@]}"; do
    read -r _ _ mem disks <<<"$n"
    need_mb=$((need_mb + mem))
    for d in ${disks//,/ }; do need_gb=$((need_gb + ${d%G})); done
  done
  free_mb=$(awk '/^MemAvailable:/ {print int($2 / 1024)}' /proc/meminfo)
  ((free_mb >= need_mb)) || die "the VMs need ${need_mb} MB RAM, only ${free_mb} MB are free (see the memory settings in the README)"
  free_gb=$(pvesm status --storage "$STORAGE" | awk 'NR==2 {print int($6 / 1024 / 1024)}')
  ((free_gb >= need_gb)) || echo "    ! only ${free_gb} GB free on $STORAGE, the disks can grow to ${need_gb} GB"
  ok "${free_mb} MB RAM free, the VMs use ${need_mb} MB"
}

create_vms() {  # create_vms IMAGE
  local img="$1" spec n ip mem disks d id i dns
  dns="$(awk '/^nameserver/ && $2 !~ /^127\./ {print $2; exit}' /etc/resolv.conf)"
  for spec in "${NODES[@]}"; do
    read -r n ip mem disks <<<"$spec"
    IFS=, read -r -a d <<<"$disks"
    id="$(pvesh get /cluster/nextid)"
    qm create "$id" --name "$n" --tags "kubl-labs;$LAB" --ostype l26 --cpu host --cores "$CORES" --memory "$mem" \
      --net0 "virtio,bridge=$VNET" --scsihw virtio-scsi-single \
      "--${BUS}0" "$STORAGE:0,import-from=$img$FMT" --boot "order=${BUS}0" --ide2 "$STORAGE:cloudinit" \
      --ciuser "$CLOUD_USER" --cipassword "$CLOUD_PASSWORD" --sshkeys "$DIR/id_ed25519.pub" \
      --ipconfig0 "ip=$NET.$ip/24,gw=$NET.1" --nameserver "${dns:-1.1.1.1}" --searchdomain "$DOMAIN" \
      "${VM_OPTS[@]}" >>"$LOG/proxmox.log" 2>&1 || { tail -n 5 "$LOG/proxmox.log" >&2; die "could not create VM $n"; }
    qm disk resize "$id" "${BUS}0" "${d[0]}" >>"$LOG/proxmox.log" 2>&1 || die "could not resize the disk of $n"
    for ((i = 1; i < ${#d[@]}; i++)); do   # extra empty disks
      qm set "$id" "--$BUS$i" "$STORAGE:${d[$i]%G}$FMT" >>"$LOG/proxmox.log" 2>&1 || die "could not add disk $i to $n"
    done
    qm start "$id" >>"$LOG/proxmox.log" 2>&1 || die "could not start $n"
    ok "$n  $NET.$ip  (VMID $id)"
  done
}

start_all() {
  local id name
  while read -r id name; do
    qm start "$id" >>"$LOG/proxmox.log" 2>&1 || die "could not start $name"
  done < <(vm_list)
  wait_ssh root
  lab_wait
}

snapshot_and_restart() {
  local id name
  while read -r id name; do
    qm shutdown "$id" --timeout 180 --forceStop 1 >>"$LOG/proxmox.log" 2>&1 &
  done < <(vm_list)
  wait
  while read -r id name; do
    qm snapshot "$id" clean --description "kubl-labs: clean lab" >>"$LOG/proxmox.log" 2>&1 ||
      die "could not take the snapshot of $name. Without it reset doesn't work (log: $LOG/proxmox.log)"
  done < <(vm_list)
  start_all
}

reboot_nodes() {  # reboot_nodes NODE...  (through Proxmox, so it works even if the network is broken)
  local n id
  for n in "$@"; do
    id="$(vm_id "$(node_vm "$n")")"
    [[ -n "$id" ]] || continue
    { qm reboot "$id" --timeout 120 || { qm stop "$id" || true; qm start "$id"; }; } >>"$LOG/proxmox.log" 2>&1 &
  done
  wait
}

# ==== commands =================================================================

cmd_create() {
  check_host
  lab_options "$@"
  [[ -z "$(vm_list)" ]] || die "the lab already exists: bash $SCRIPT reset   or   bash $SCRIPT destroy"
  mkdir -p "$LOG" "$BASE/images"; rm -f "$LOG"/*.log "$DIR/exam"
  [[ -f "$DIR/id_ed25519" ]] || ssh-keygen -q -t ed25519 -N "" -C "kubl-labs-$LAB" -f "$DIR/id_ed25519"
  pick_storage
  check_resources

  say "Creating the lab network $NET.0/24"
  network_up; ok "VNet $VNET"

  say "Downloading the cloud image"
  local img="$BASE/images/${IMG_URL##*/}"
  [[ -s "$img" ]] || { curl -fL --progress-bar -o "$img.part" "$IMG_URL" && mv "$img.part" "$img"; } ||
    die "could not download $IMG_URL"
  ok "$img"

  say "Creating the VMs"
  STARTED=1
  create_vms "$img"

  say "Waiting for the VMs to boot"
  wait_ssh "$CLOUD_USER"; root_ssh; ok "all VMs are up"
  check_internet

  lab_build

  say "Taking the snapshot \"clean\""
  snapshot_and_restart; ok "done, lab is running"
  lab_summary
}

cmd_reset() {
  need_root; mkdir -p "$LOG"
  local id name
  [[ -n "$(vm_list)" ]] || die "there is no lab, create it with: bash $SCRIPT create"
  # first make sure every VM has the snapshot, before touching any of them
  while read -r id name; do
    grep -qw clean <<<"$(qm listsnapshot "$id" 2>/dev/null)" || die "$name has no snapshot \"clean\" (bash $SCRIPT destroy, then create)"
  done < <(vm_list)
  say "Resetting to the snapshot \"clean\""
  while read -r id name; do
    qm stop "$id" >>"$LOG/proxmox.log" 2>&1 || true
    qm rollback "$id" clean >>"$LOG/proxmox.log" 2>&1 || die "$name has no snapshot \"clean\" (bash $SCRIPT destroy, then create)"
  done < <(vm_list)
  rm -f "$DIR/exam"
  start_all
  ok "lab is clean again"
}

cmd_destroy() {
  need_root
  local id name
  say "Deleting the $LAB lab"
  while read -r id name; do
    qm stop "$id" >/dev/null 2>&1 || true
    qm destroy "$id" --purge 1 --destroy-unreferenced-disks 1 >/dev/null || die "could not delete $name (VMID $id)"
    ok "$name (VMID $id) deleted"
  done < <(vm_list)
  network_down
  rm -f "$DIR/exam" "$DIR/prep"
}

# ---- mock exams ---------------------------------------------------------------
# exams/<name>/tasks.md   the tasks (first line is the title)
# exams/<name>/setup.sh   brings the lab into the starting state, uses: run NODE <<'EOF' ... EOF
# exams/<name>/grade.sh   checks the result, uses: task "title" and check POINTS NODE "what" 'code'
# exams/<name>/solutions.md

cmd_exam() {
  need_root
  local ex name
  if [[ -z "${1:-}" ]]; then
    echo "Mock exams (start one with: bash $SCRIPT exam 1)"
    for ex in "$EXAMS"/*/; do
      ex="${ex%/}"
      [[ -f "$ex/tasks.md" ]] && printf '  %-8s %s\n' "${ex##*/}" "$(head -n 1 "$ex/tasks.md" | sed 's/^# *//')"
    done
    return 0
  fi
  name="$1"; [[ "$name" =~ ^[0-9]+$ ]] && name="exam$name"
  ex="$EXAMS/$name"
  [[ -f "$ex/setup.sh" && -f "$ex/grade.sh" && -f "$ex/tasks.md" ]] || die "there is no exam '$1' (list them: bash $SCRIPT exam)"
  cmd_reset
  say "Preparing $name (it changes and breaks things on purpose)"
  # the setup runs in a subshell: run() exits it on the first failed step
  ( source "$ex/setup.sh" ) >"$LOG/exam.log" 2>&1 ||
    { tail -n 20 "$LOG/exam.log" >&2; die "the exam setup failed (log: $LOG/exam.log). Try again, or: bash $SCRIPT reset"; }
  echo "$name $(date +%s)" >"$DIR/exam"
  ok "$name is ready"
  echo
  cat "$ex/tasks.md"
  echo
  say "Good luck. Tasks: $ex/tasks.md"
  echo "    When you're done:  bash $SCRIPT grade      Start over:  bash $SCRIPT exam ${name#exam}"
}

run() {  # in setup.sh:  run NODE <<'EOF' ... EOF   (runs the script as root on NODE, stops the setup if it fails)
  local ip script
  ip="$(node_ip "$1")" || exit 1
  script="$(cat)"
  echo "--- $1"
  remote_script "$ip" "$REMOTE_ENV
set -euo pipefail
$script" || { echo "setup step on $1 failed" >&2; exit 1; }
}

cmd_grade() {
  need_root
  local reboot=1 name start out
  [[ "${1:-}" == "--no-reboot" ]] && reboot=0
  [[ -f "$DIR/exam" ]] || die "no exam is running, start one with: bash $SCRIPT exam 1"
  read -r name start <"$DIR/exam"
  [[ -f "$EXAMS/$name/grade.sh" ]] || die "grade.sh of $name not found"
  mkdir -p "$DIR/results"
  out="$DIR/results/$name-$(date +%Y%m%d-%H%M).txt"
  grade_run "$EXAMS/$name" "$start" "$reboot" 2>&1 | tee "$out"
  echo "    Result saved: $out"
  echo "    Solutions: $EXAMS/$name/solutions.md      Back to clean: bash $SCRIPT reset"
}

grade_run() {
  local ex="$1" start="$2" reboot="$3" n need wait
  say "Grading ${ex##*/}, $(( ($(date +%s) - start) / 60 )) minutes after the start"
  if ((reboot)) && [[ -n "${GRADE_REBOOT:-}" ]]; then
    say "Rebooting $GRADE_REBOOT first (everything has to survive a reboot, like in the exam)"
    # shellcheck disable=SC2086
    reboot_nodes $GRADE_REBOOT
  fi
  DOWN=""
  for n in $(all_nodes); do
    # a node that was just rebooted gets 3 minutes to come back, the others 15 seconds
    wait=15
    ((reboot)) && [[ " ${GRADE_REBOOT:-} " == *" ${n#"$LAB"-} "* ]] && wait=180
    ssh_up "$(node_ip "$n")" root "$wait" && continue
    DOWN+=" $n"
    echo "    ! $n is not reachable at $(node_ip "$n"), all its checks fail (look at its console)"
  done
  TOTAL=0; SCORE=0; PASS_PERCENT=70
  # shellcheck disable=SC1091
  source "$ex/grade.sh"
  need=$(( (TOTAL * PASS_PERCENT + 99) / 100 ))
  echo
  printf '  Score: %d of %d points (%d%%), passing needs %d%%  ->  %s\n\n' \
    "$SCORE" "$TOTAL" $((SCORE * 100 / (TOTAL > 0 ? TOTAL : 1))) "$PASS_PERCENT" "$( ((SCORE >= need)) && echo PASSED || echo NOT PASSED)"
}

# ---- used in grade.sh ---------------------------------------------------------

task() { printf '\n  %s\n' "$*"; }

# check POINTS NODE "what is checked" 'code'      or      check POINTS NODE "what" <<'EOF' ... EOF
# The code runs as root on NODE with "set -e": every line has to succeed for the points.
# (Careful: "! cmd" never fails under set -e, write "if cmd; then exit 1; fi" instead.)
check() {
  local pts="$1" node="$2" what="$3" code="${4:-$(cat)}" script
  TOTAL=$((TOTAL + pts))
  script="$REMOTE_ENV
$(declare -f pw_ok)
set -e
$code"
  if [[ " $DOWN " != *" $(node_vm "$node") "* ]] &&
     timeout 120 "${SSH[@]}" "root@$(node_ip "$node")" "bash -c $(printf '%q' "$script")" </dev/null >/dev/null 2>&1; then
    SCORE=$((SCORE + pts))
    printf '    ✓ %2d/%-2d  %s\n' "$pts" "$pts" "$what"
  else
    printf '    ✗  0/%-2d  %s\n' "$pts" "$what"
  fi
}

# helper for checks: pw_ok USER PASSWORD  ->  true if that is the user's password
# (calls the system's crypt() directly, so SHA-512 and yescrypt hashes both work)
pw_ok() {
  local h; h="$(getent shadow "$1" | cut -d: -f2)"
  [[ -n "$h" ]] || return 1
  python3 -c '
import ctypes, ctypes.util, sys
lib = ctypes.CDLL(ctypes.util.find_library("crypt") or "libcrypt.so.2")
lib.crypt.restype = ctypes.c_char_p
lib.crypt.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
r = lib.crypt(sys.argv[1].encode(), sys.argv[2].encode())
sys.exit(0 if r and r.decode() == sys.argv[2] else 1)' "$2" "$h"
}

lab_main() {
  case "${1:-}" in
    create)  shift; cmd_create "$@" ;;
    exam)    shift; cmd_exam "$@" ;;
    grade)   shift; cmd_grade "$@" ;;
    reset)   cmd_reset ;;
    destroy) cmd_destroy ;;
    "" | -h | --help | help) usage ;;
    *) usage; FAILED=1; exit 1 ;;
  esac
}
