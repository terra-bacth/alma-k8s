#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# Interactive fresh Kubernetes bootstrap for AlmaLinux 10
#
# Topology:
#   - This machine becomes the single control-plane node.
#   - Zero or more AlmaLinux 10 worker nodes are configured over SSH.
#   - kubeadm + kubelet + kubectl
#   - containerd runtime
#   - Calico CNI using the Tigera operator
#
# IMPORTANT:
#   This script is intentionally DESTRUCTIVE. After explicit confirmation it
#   removes an existing kubeadm/Kubernetes installation and containerd state
#   from every node listed in the interactive questionnaire, then rebuilds it.
# ==============================================================================

DEFAULT_K8S_MINOR="v1.36"
DEFAULT_CALICO_VERSION="v3.32.2"
DEFAULT_POD_CIDR="172.20.0.0/16"
DEFAULT_SERVICE_CIDR="172.21.0.0/16"
CRI_SOCKET="unix:///run/containerd/containerd.sock"

log()  { printf '\033[1;32m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

on_error() {
  local rc=$?
  printf '\n\033[1;31m[ERROR]\033[0m Script failed at line %s (exit code %s).\n' "${BASH_LINENO[0]:-unknown}" "$rc" >&2
  printf 'Review the messages above. No automatic rollback is attempted.\n' >&2
  exit "$rc"
}
trap on_error ERR

[[ $EUID -eq 0 ]] || die "Run this script with sudo/root: sudo $0"
[[ -t 0 ]] || die "This installer is interactive. Run it from a terminal."

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

prompt_default() {
  local __var="$1" prompt="$2" default="$3" value
  read -r -p "$prompt [$default]: " value
  printf -v "$__var" '%s' "${value:-$default}"
}

prompt_required() {
  local __var="$1" prompt="$2" value
  while :; do
    read -r -p "$prompt: " value
    [[ -n "$value" ]] && { printf -v "$__var" '%s' "$value"; return; }
    warn "A value is required."
  done
}

prompt_yes_no() {
  local __var="$1" prompt="$2" default="$3" answer suffix
  if [[ "$default" == "yes" ]]; then suffix="Y/n"; else suffix="y/N"; fi
  while :; do
    read -r -p "$prompt [$suffix]: " answer
    answer="${answer:-$default}"
    case "${answer,,}" in
      y|yes) printf -v "$__var" '%s' "true"; return ;;
      n|no)  printf -v "$__var" '%s' "false"; return ;;
      *) warn "Please answer yes or no." ;;
    esac
  done
}

prompt_choice() {
  local __var="$1" prompt="$2" default="$3" allowed="$4" value
  while :; do
    read -r -p "$prompt [$default]: " value
    value="${value:-$default}"
    if [[ " $allowed " == *" $value "* ]]; then
      printf -v "$__var" '%s' "$value"
      return
    fi
    warn "Allowed values: $allowed"
  done
}

valid_hostname() {
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]
}

valid_ipv4() {
  local ip="$1" a b c d extra
  IFS=. read -r a b c d extra <<< "$ip"
  [[ -z "${extra:-}" && -n "${a:-}" && -n "${b:-}" && -n "${c:-}" && -n "${d:-}" ]] || return 1
  for o in "$a" "$b" "$c" "$d"; do
    [[ "$o" =~ ^[0-9]+$ ]] || return 1
    (( 10#$o >= 0 && 10#$o <= 255 )) || return 1
  done
}

ipv4_to_int() {
  local ip="$1" a b c d
  IFS=. read -r a b c d <<< "$ip"
  printf '%u\n' $(( (10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d ))
}

valid_cidr() {
  local cidr="$1" ip prefix extra
  IFS=/ read -r ip prefix extra <<< "$cidr"
  [[ -z "${extra:-}" ]] || return 1
  valid_ipv4 "$ip" || return 1
  [[ "${prefix:-}" =~ ^[0-9]+$ ]] || return 1
  (( prefix >= 0 && prefix <= 32 ))
}

cidr_range() {
  local cidr="$1" ip prefix ipn mask start end
  IFS=/ read -r ip prefix <<< "$cidr"
  ipn="$(ipv4_to_int "$ip")"
  if (( prefix == 0 )); then
    mask=0
  else
    mask=$(( (0xFFFFFFFF << (32-prefix)) & 0xFFFFFFFF ))
  fi
  start=$(( ipn & mask ))
  end=$(( start | ((~mask) & 0xFFFFFFFF) ))
  printf '%u %u\n' "$start" "$end"
}

cidr_contains_ip() {
  local ip="$1" cidr="$2" n start end
  n="$(ipv4_to_int "$ip")"
  read -r start end < <(cidr_range "$cidr")
  (( n >= start && n <= end ))
}

cidrs_overlap() {
  local c1="$1" c2="$2" s1 e1 s2 e2
  read -r s1 e1 < <(cidr_range "$c1")
  read -r s2 e2 < <(cidr_range "$c2")
  (( s1 <= e2 && s2 <= e1 ))
}

check_alma10_local() {
  [[ -r /etc/os-release ]] || die "/etc/os-release is missing."
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == "almalinux" ]] || die "Expected AlmaLinux; detected ID=${ID:-unknown}."
  [[ "${VERSION_ID%%.*}" == "10" ]] || die "This script is for AlmaLinux 10; detected ${VERSION_ID:-unknown}."
}

invoking_user_home() {
  local user="${SUDO_USER:-root}"
  getent passwd "$user" | cut -d: -f6
}

expand_path() {
  local p="$1" base
  if [[ "$p" == "~/"* ]]; then
    base="$(invoking_user_home)"
    printf '%s/%s\n' "$base" "${p#~/}"
  else
    printf '%s\n' "$p"
  fi
}

get_default_master_ip() {
  ip -o -4 addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1
}

check_alma10_local
require_cmd ip
require_cmd awk
require_cmd sed
require_cmd grep
require_cmd dnf

# Minimal AlmaLinux images may omit curl/SSH client tools. Installing these is
# non-destructive and is done before the rebuild confirmation.
if ! command -v curl >/dev/null 2>&1 || ! command -v ssh >/dev/null 2>&1 || ! command -v scp >/dev/null 2>&1; then
  log "Installing local installer prerequisites (curl, openssh-clients)"
  dnf install -y curl openssh-clients >/dev/null
fi
require_cmd ssh
require_cmd scp
require_cmd curl

printf '\n============================================================\n'
printf ' AlmaLinux 10 -> Fresh Kubernetes cluster installer (V3)\n'
printf '============================================================\n'
printf 'This will DELETE an existing Kubernetes/kubeadm cluster and\n'
printf 'containerd Kubernetes state on all nodes you specify.\n\n'

# ------------------------------ Interactive input -----------------------------
prompt_default K8S_MINOR "Kubernetes minor repository (example: v1.36)" "$DEFAULT_K8S_MINOR"
[[ "$K8S_MINOR" =~ ^v1\.[0-9]{1,2}$ ]] || die "Invalid Kubernetes minor: $K8S_MINOR"

prompt_default CALICO_VERSION "Calico version" "$DEFAULT_CALICO_VERSION"
[[ "$CALICO_VERSION" =~ ^v3\.[0-9]+\.[0-9]+$ ]] || die "Invalid Calico version: $CALICO_VERSION"

DEFAULT_MASTER_HOSTNAME="$(hostname -s 2>/dev/null || echo k8s-master)"
prompt_default MASTER_HOSTNAME "Control-plane hostname" "$DEFAULT_MASTER_HOSTNAME"
valid_hostname "$MASTER_HOSTNAME" || die "Invalid hostname: $MASTER_HOSTNAME"

DEFAULT_MASTER_IP="$(get_default_master_ip)"
[[ -n "$DEFAULT_MASTER_IP" ]] || DEFAULT_MASTER_IP="192.0.2.10"
while :; do
  prompt_default MASTER_IP "Control-plane IPv4 address" "$DEFAULT_MASTER_IP"
  valid_ipv4 "$MASTER_IP" && break
  warn "Enter a valid IPv4 address."
done

while :; do
  prompt_default POD_CIDR "Pod CIDR (must not overlap LAN/host/service networks)" "$DEFAULT_POD_CIDR"
  valid_cidr "$POD_CIDR" && break
  warn "Enter a valid IPv4 CIDR, for example 172.20.0.0/16."
done

while :; do
  prompt_default SERVICE_CIDR "Service CIDR (must not overlap LAN/host/pod networks)" "$DEFAULT_SERVICE_CIDR"
  valid_cidr "$SERVICE_CIDR" && break
  warn "Enter a valid IPv4 CIDR, for example 172.21.0.0/16."
done

cidrs_overlap "$POD_CIDR" "$SERVICE_CIDR" && die "Pod CIDR and Service CIDR overlap. Choose different ranges."
cidr_contains_ip "$MASTER_IP" "$POD_CIDR" && die "MASTER_IP $MASTER_IP is inside POD_CIDR $POD_CIDR. Choose a non-overlapping Pod CIDR."
cidr_contains_ip "$MASTER_IP" "$SERVICE_CIDR" && die "MASTER_IP $MASTER_IP is inside SERVICE_CIDR $SERVICE_CIDR. Choose a non-overlapping Service CIDR."

if ! ip -o -4 addr show | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "$MASTER_IP"; then
  die "The control-plane IP $MASTER_IP is not assigned to this machine."
fi

while :; do
  read -r -p "Number of worker nodes [2]: " WORKER_COUNT
  WORKER_COUNT="${WORKER_COUNT:-2}"
  [[ "$WORKER_COUNT" =~ ^[0-9]+$ ]] && break
  warn "Enter 0 or a positive integer."
done

SSH_KEY=""
if (( WORKER_COUNT > 0 )); then
  INVOKING_HOME="$(invoking_user_home)"
  DEFAULT_SSH_KEY="$INVOKING_HOME/.ssh/id_ed25519"
  [[ -f "$DEFAULT_SSH_KEY" ]] || DEFAULT_SSH_KEY="$INVOKING_HOME/.ssh/id_rsa"
  prompt_default SSH_KEY "SSH private key used to configure workers" "$DEFAULT_SSH_KEY"
  SSH_KEY="$(expand_path "$SSH_KEY")"
  [[ -f "$SSH_KEY" ]] || die "SSH private key not found: $SSH_KEY"
fi

prompt_choice FIREWALL_MODE \
  "Firewall mode: 'disable' (recommended for Calico lab) or 'open-ports'" \
  "disable" "disable open-ports"

if [[ "$FIREWALL_MODE" == "open-ports" ]]; then
  warn "Calico recommends disabling host firewalls/iptables managers unless they are carefully integrated."
fi

MASTER_SCHEDULE_DEFAULT="no"
(( WORKER_COUNT == 0 )) && MASTER_SCHEDULE_DEFAULT="yes"
prompt_yes_no ALLOW_SCHEDULING_ON_MASTER \
  "Allow normal workloads to run on the control-plane node?" "$MASTER_SCHEDULE_DEFAULT"

WORKER_NAMES=()
WORKER_IPS=()
WORKER_USERS=()
declare -A SEEN_NAMES=(["$MASTER_HOSTNAME"]=1)
declare -A SEEN_IPS=(["$MASTER_IP"]=1)

for ((i=1; i<=WORKER_COUNT; i++)); do
  printf '\n--- Worker %d of %d ---\n' "$i" "$WORKER_COUNT"
  default_name="$(printf 'k8s-worker%02d' "$i")"
  while :; do
    prompt_default node "Worker $i hostname" "$default_name"
    valid_hostname "$node" || { warn "Invalid hostname."; continue; }
    [[ -z "${SEEN_NAMES[$node]:-}" ]] || { warn "Hostname $node is already used."; continue; }
    break
  done

  while :; do
    prompt_required node_ip "Worker $i IPv4 address"
    valid_ipv4 "$node_ip" || { warn "Invalid IPv4 address."; continue; }
    [[ -z "${SEEN_IPS[$node_ip]:-}" ]] || { warn "IP $node_ip is already used."; continue; }
    cidr_contains_ip "$node_ip" "$POD_CIDR" && { warn "$node_ip is inside Pod CIDR $POD_CIDR."; continue; }
    cidr_contains_ip "$node_ip" "$SERVICE_CIDR" && { warn "$node_ip is inside Service CIDR $SERVICE_CIDR."; continue; }
    break
  done

  prompt_default ssh_user "Worker $i SSH user (root or passwordless sudo user)" "root"
  [[ "$ssh_user" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]] || die "Invalid SSH user: $ssh_user"

  WORKER_NAMES+=("$node")
  WORKER_IPS+=("$node_ip")
  WORKER_USERS+=("$ssh_user")
  SEEN_NAMES["$node"]=1
  SEEN_IPS["$node_ip"]=1
done

# ------------------------------ Preflight checks ------------------------------
SSH_ARGS=(
  -o BatchMode=yes
  -o ConnectTimeout=10
  -o StrictHostKeyChecking=accept-new
)
[[ -n "$SSH_KEY" ]] && SSH_ARGS+=( -i "$SSH_KEY" )

remote_target() {
  local idx="$1"
  printf '%s@%s' "${WORKER_USERS[$idx]}" "${WORKER_IPS[$idx]}"
}

remote_sudo() {
  local idx="$1"
  if [[ "${WORKER_USERS[$idx]}" == "root" ]]; then
    printf '%s' ""
  else
    printf '%s' "sudo -n "
  fi
}

log "Running preflight checks before deleting anything"

if [[ "$K8S_MINOR" == "v1.37" && "$CALICO_VERSION" == v3.32.* ]]; then
  warn "Calico 3.32 is tested through Kubernetes 1.36, not 1.37. The script will continue only if you confirm later."
fi

# Verify required web endpoints now, before destructive actions.
curl -fsIL --max-time 20 "https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/rpm/repodata/repomd.xml" >/dev/null || \
  die "Cannot reach Kubernetes ${K8S_MINOR} RPM repository."
curl -fsIL --max-time 20 "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml" >/dev/null || \
  die "Cannot retrieve Calico ${CALICO_VERSION} manifests."
curl -fsIL --max-time 20 "https://download.docker.com/linux/rhel/docker-ce.repo" >/dev/null || \
  die "Cannot reach Docker's RHEL repository used for containerd.io."

for ((i=0; i<WORKER_COUNT; i++)); do
  target="$(remote_target "$i")"
  log "Checking SSH and AlmaLinux 10 on ${WORKER_NAMES[$i]} (${WORKER_IPS[$i]})"
  ssh "${SSH_ARGS[@]}" "$target" 'echo SSH_OK' >/dev/null || die "Cannot SSH to $target using $SSH_KEY"

  if [[ "${WORKER_USERS[$i]}" != "root" ]]; then
    ssh "${SSH_ARGS[@]}" "$target" 'sudo -n true' >/dev/null || \
      die "$target needs passwordless sudo (sudo -n)."
  fi

  prefix="$(remote_sudo "$i")"
  ssh "${SSH_ARGS[@]}" "$target" \
    "${prefix}bash -c 'source /etc/os-release; [[ \"\$ID\" == almalinux && \"\${VERSION_ID%%.*}\" == 10 ]]'" || \
    die "$target is not AlmaLinux 10."
done

cluster_marker_local="no"
if [[ -e /etc/kubernetes/admin.conf || -e /etc/kubernetes/kubelet.conf || -d /var/lib/etcd ]]; then
  cluster_marker_local="YES"
fi

printf '\n==================== REBUILD SUMMARY ====================\n'
printf 'Control plane : %s (%s)\n' "$MASTER_HOSTNAME" "$MASTER_IP"
printf 'Kubernetes    : %s\n' "$K8S_MINOR"
printf 'Calico        : %s\n' "$CALICO_VERSION"
printf 'Pod CIDR      : %s\n' "$POD_CIDR"
printf 'Service CIDR  : %s\n' "$SERVICE_CIDR"
printf 'Firewall      : %s\n' "$FIREWALL_MODE"
printf 'Master sched. : %s\n' "$ALLOW_SCHEDULING_ON_MASTER"
printf 'Workers       : %d\n' "$WORKER_COUNT"
printf 'Old local K8s : %s\n' "$cluster_marker_local"
for ((i=0; i<WORKER_COUNT; i++)); do
  printf '  - %-18s %-15s SSH user=%s\n' "${WORKER_NAMES[$i]}" "${WORKER_IPS[$i]}" "${WORKER_USERS[$i]}"
done
printf '=========================================================\n'
printf '\nDESTRUCTIVE ACTIONS AFTER CONFIRMATION:\n'
printf '  * kubeadm reset (if present)\n'
printf '  * unmount stale kubelet/Calico mounts and delete K8s/CNI state\n'
printf '  * delete /var/lib/containerd and reinstall containerd.io\n'
printf '  * reinstall kubelet/kubeadm/kubectl and recreate the cluster\n\n'
read -r -p "Type REBUILD to erase/reinstall the listed nodes: " CONFIRM
[[ "$CONFIRM" == "REBUILD" ]] || die "Cancelled. Nothing destructive was done."

# ------------------------------ Helper scripts -------------------------------
TMPDIR_K8S="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_K8S"' EXIT
RESET_SCRIPT="$TMPDIR_K8S/k8s-node-reset.sh"
PREP_SCRIPT="$TMPDIR_K8S/k8s-node-prepare.sh"

cat > "$RESET_SCRIPT" <<'NODE_RESET'
#!/usr/bin/env bash
set -Eeuo pipefail
NODE_NAME="${1:?node name required}"
log() { printf '[RESET:%s] %s\n' "$NODE_NAME" "$*"; }

[[ $EUID -eq 0 ]] || { echo "Reset helper must run as root" >&2; exit 1; }
source /etc/os-release
[[ "${ID:-}" == "almalinux" && "${VERSION_ID%%.*}" == "10" ]] || {
  echo "Expected AlmaLinux 10, found ${PRETTY_NAME:-unknown}" >&2; exit 1;
}

FOUND=false
if [[ -e /etc/kubernetes/admin.conf || -e /etc/kubernetes/kubelet.conf || -d /var/lib/etcd || -d /var/lib/kubelet ]]; then
  FOUND=true
fi

if $FOUND; then
  log "Existing/stale Kubernetes state detected; removing it"
else
  log "No kubeadm state detected; enforcing a clean Kubernetes baseline anyway"
fi

systemctl stop kubelet 2>/dev/null || true

if command -v kubeadm >/dev/null 2>&1; then
  # Do not run kubeadm's cleanup-node phase during a forced rebuild.
  # cleanup-node asks the CRI to delete old pod sandboxes, which invokes the
  # old Calico CNI DEL plugin. If the old API server is already unavailable,
  # Calico tries to reach the old kubernetes service IP and reports errors such
  # as: error getting ClusterInformation ... connect: connection refused.
  #
  # We perform the node/CNI/runtime cleanup explicitly below, so let kubeadm
  # only run its preflight and (for a control plane) remove-etcd-member phases.
  timeout 90 kubeadm reset -f --skip-phases=cleanup-node || \
    log "kubeadm metadata/etcd cleanup returned a warning; continuing with forced local cleanup"
fi

systemctl stop containerd 2>/dev/null || true

# A stopped containerd can leave Kubernetes shim processes behind.  This host is
# being deliberately rebuilt and /var/lib/containerd is about to be deleted, so
# terminate stale shims before unmounting pod/Calico mount trees.
if command -v pkill >/dev/null 2>&1; then
  pkill -TERM -x containerd-shim-runc-v2 2>/dev/null || true
  pkill -TERM -x containerd-shim 2>/dev/null || true
  sleep 1
  pkill -KILL -x containerd-shim-runc-v2 2>/dev/null || true
  pkill -KILL -x containerd-shim 2>/dev/null || true
fi

# Never rm -rf a directory while a cgroup/bind mount is still mounted below it.
# Calico can leave /run/calico/cgroup backed by the host cgroup filesystem; trying
# to delete files such as cgroup.procs returns "Operation not permitted" and,
# because this helper uses set -e, aborts the rebuild.
unmount_tree() {
  local root="$1" pass mnt
  local -a mounts=()

  for pass in 1 2 3 4 5; do
    mapfile -t mounts < <(
      findmnt -rn -o TARGET 2>/dev/null |         awk -v root="$root" '$0 == root || index($0, root "/") == 1 { print length($0), $0 }' |         sort -rn | cut -d' ' -f2- || true
    )

    ((${#mounts[@]} == 0)) && return 0

    for mnt in "${mounts[@]}"; do
      [[ -n "$mnt" ]] || continue
      log "Unmounting stale mount: $mnt"
      umount -lf -- "$mnt" 2>/dev/null || true
    done
    sleep 1
  done

  mapfile -t mounts < <(
    findmnt -rn -o TARGET 2>/dev/null |       awk -v root="$root" '$0 == root || index($0, root "/") == 1' || true
  )
  if ((${#mounts[@]} > 0)); then
    printf '[RESET:%s] ERROR: mounts still remain under %s:\n' "$NODE_NAME" "$root" >&2
    printf '  %s\n' "${mounts[@]}" >&2
    return 1
  fi
}

unmount_tree /var/lib/kubelet
unmount_tree /run/calico

# kubeadm reset does not remove every CNI directory; explicitly wipe K8s/CNI state.
rm -rf -- \
  /etc/kubernetes \
  /var/lib/etcd \
  /var/lib/kubelet \
  /etc/cni/net.d \
  /var/lib/cni \
  /var/lib/calico \
  /run/calico \
  /var/lib/containerd \
  /etc/containerd \
  /etc/crictl.yaml

# Remove common Kubernetes/Calico virtual interfaces. Physical NICs are untouched.
for dev in cni0 flannel.1 vxlan.calico tunl0 kube-ipvs0; do
  ip link delete "$dev" 2>/dev/null || true
done
while read -r dev; do
  [[ -n "$dev" ]] && ip link delete "$dev" 2>/dev/null || true
done < <(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | sed 's/@.*//' | grep '^cali' || true)

# Remove Kubernetes packages and runtime so the next phase is a true reinstall.
# DNF5 on Alma/RHEL 10 uses disable_excludes as an option rather than the older flag.
dnf -y remove kubelet kubeadm kubectl cri-tools kubernetes-cni containerd.io \
  --setopt=disable_excludes=kubernetes >/dev/null 2>&1 || true
rm -f /etc/yum.repos.d/kubernetes.repo /etc/yum.repos.d/docker-ce.repo

log "Reset completed"
NODE_RESET
chmod 700 "$RESET_SCRIPT"

cat > "$PREP_SCRIPT" <<'NODE_PREP'
#!/usr/bin/env bash
set -Eeuo pipefail

NODE_NAME="${1:?node name required}"
NODE_IP="${2:?node IPv4 required}"
NODE_ROLE="${3:?node role required}"
K8S_MINOR="${4:?Kubernetes minor required}"
POD_CIDR="${5:?pod CIDR required}"
FIREWALL_MODE="${6:?firewall mode required}"

log() { printf '[PREP:%s] %s\n' "$NODE_NAME" "$*"; }
[[ $EUID -eq 0 ]] || { echo "Prepare helper must run as root" >&2; exit 1; }
source /etc/os-release
[[ "${ID:-}" == "almalinux" && "${VERSION_ID%%.*}" == "10" ]] || {
  echo "Expected AlmaLinux 10, found ${PRETTY_NAME:-unknown}" >&2; exit 1;
}

log "Setting hostname"
hostnamectl set-hostname "$NODE_NAME"

log "Disabling swap"
swapoff -a
cp -a /etc/fstab "/etc/fstab.k8s-backup.$(date +%Y%m%d%H%M%S)"
sed -ri '/^[[:space:]]*[^#].*[[:space:]]swap[[:space:]]/ s/^/# k8s-disabled-swap: /' /etc/fstab

log "Setting SELinux to permissive for kubeadm baseline"
setenforce 0 2>/dev/null || true
if grep -q '^SELINUX=' /etc/selinux/config; then
  sed -ri 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config
fi

log "Loading Kubernetes kernel modules"
cat > /etc/modules-load.d/k8s.conf <<'EOF_MODULES'
overlay
br_netfilter
EOF_MODULES
modprobe overlay
modprobe br_netfilter

cat > /etc/sysctl.d/99-kubernetes-cri.conf <<'EOF_SYSCTL'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF_SYSCTL
sysctl --system >/dev/null

log "Installing base packages"
dnf install -y curl ca-certificates iproute iproute-tc conntrack-tools socat ethtool >/dev/null

log "Configuring NetworkManager to ignore Calico interfaces"
mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/calico.conf <<'EOF_NM'
[keyfile]
unmanaged-devices=interface-name:cali*;interface-name:tunl*;interface-name:vxlan.calico;interface-name:vxlan-v6.calico;interface-name:wireguard.cali;interface-name:wg-v6.cali
EOF_NM
systemctl reload NetworkManager 2>/dev/null || true

log "Installing a fresh containerd.io from Docker's RHEL repository"
curl -fsSL https://download.docker.com/linux/rhel/docker-ce.repo -o /etc/yum.repos.d/docker-ce.repo
dnf install -y containerd.io >/dev/null
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -ri 's/(SystemdCgroup[[:space:]]*=[[:space:]]*)false/\1true/g' /etc/containerd/config.toml
sed -ri 's/^([[:space:]]*)disabled_plugins[[:space:]]*=[[:space:]]*\["cri"\]/\1disabled_plugins = []/' /etc/containerd/config.toml
systemctl daemon-reload
systemctl enable --now containerd
systemctl restart containerd

log "Configuring Kubernetes ${K8S_MINOR} RPM repository"
cat > /etc/yum.repos.d/kubernetes.repo <<EOF_K8S_REPO
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF_K8S_REPO

# AlmaLinux 10 uses DNF5. install_weak_deps=False follows upstream guidance for RHEL/CentOS 10+.
dnf install -y kubelet kubeadm kubectl \
  --setopt=disable_excludes=kubernetes \
  --setopt=install_weak_deps=False >/dev/null

cat > /etc/sysconfig/kubelet <<EOF_KUBELET
KUBELET_EXTRA_ARGS=--node-ip=${NODE_IP}
EOF_KUBELET
systemctl enable kubelet
systemctl restart kubelet 2>/dev/null || true

if systemctl list-unit-files firewalld.service >/dev/null 2>&1; then
  if [[ "$FIREWALL_MODE" == "disable" ]]; then
    log "Disabling firewalld"
    systemctl disable --now firewalld 2>/dev/null || true
  else
    log "Opening baseline Kubernetes/Calico ports in firewalld"
    systemctl enable --now firewalld
    firewall-cmd --permanent --add-port=10250/tcp >/dev/null
    firewall-cmd --permanent --add-port=4789/udp >/dev/null
    if [[ "$NODE_ROLE" == "control-plane" ]]; then
      firewall-cmd --permanent --add-port=6443/tcp >/dev/null
      firewall-cmd --permanent --add-port=2379-2380/tcp >/dev/null
      firewall-cmd --permanent --add-port=10257/tcp >/dev/null
      firewall-cmd --permanent --add-port=10259/tcp >/dev/null
    else
      firewall-cmd --permanent --add-port=30000-32767/tcp >/dev/null
      firewall-cmd --permanent --add-port=30000-32767/udp >/dev/null
    fi
    firewall-cmd --permanent --zone=trusted --add-source="$POD_CIDR" >/dev/null || true
    firewall-cmd --reload >/dev/null
  fi
fi

log "Node preparation completed"
NODE_PREP
chmod 700 "$PREP_SCRIPT"

run_remote_script() {
  local idx="$1" script="$2"; shift 2
  local target prefix
  target="$(remote_target "$idx")"
  prefix="$(remote_sudo "$idx")"
  cat "$script" | ssh "${SSH_ARGS[@]}" "$target" "${prefix}bash -s -- $*"
}

# ------------------------------ Destructive reset -----------------------------
log "Resetting worker nodes first"
for ((i=0; i<WORKER_COUNT; i++)); do
  log "Resetting ${WORKER_NAMES[$i]} (${WORKER_IPS[$i]})"
  # Node names are validated and do not contain shell whitespace.
  run_remote_script "$i" "$RESET_SCRIPT" "${WORKER_NAMES[$i]}"
done

log "Resetting the local control-plane node"
bash "$RESET_SCRIPT" "$MASTER_HOSTNAME"

# ------------------------------ Fresh installation ---------------------------
log "Preparing local control-plane node"
bash "$PREP_SCRIPT" "$MASTER_HOSTNAME" "$MASTER_IP" control-plane "$K8S_MINOR" "$POD_CIDR" "$FIREWALL_MODE"

log "Preparing worker nodes"
for ((i=0; i<WORKER_COUNT; i++)); do
  log "Preparing ${WORKER_NAMES[$i]} (${WORKER_IPS[$i]})"
  run_remote_script "$i" "$PREP_SCRIPT" \
    "${WORKER_NAMES[$i]}" "${WORKER_IPS[$i]}" worker "$K8S_MINOR" "$POD_CIDR" "$FIREWALL_MODE"
done

log "Initializing a new Kubernetes control plane"
kubeadm init \
  --node-name "$MASTER_HOSTNAME" \
  --apiserver-advertise-address "$MASTER_IP" \
  --pod-network-cidr "$POD_CIDR" \
  --service-cidr "$SERVICE_CIDR" \
  --cri-socket "$CRI_SOCKET"

export KUBECONFIG=/etc/kubernetes/admin.conf

log "Configuring kubectl for root"
mkdir -p /root/.kube
cp -f /etc/kubernetes/admin.conf /root/.kube/config
chmod 600 /root/.kube/config

if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
  USER_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
  if [[ -n "$USER_HOME" ]]; then
    log "Configuring kubectl for invoking user $SUDO_USER"
    mkdir -p "$USER_HOME/.kube"
    cp -f /etc/kubernetes/admin.conf "$USER_HOME/.kube/config"
    chown -R "$SUDO_USER":"$(id -gn "$SUDO_USER")" "$USER_HOME/.kube"
    chmod 600 "$USER_HOME/.kube/config"
  fi
fi

log "Installing Calico ${CALICO_VERSION}"
CALICO_BASE="https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests"
kubectl create -f "${CALICO_BASE}/v1_crd_projectcalico_org.yaml"
kubectl create -f "${CALICO_BASE}/tigera-operator.yaml"

log "Waiting for Tigera operator CRDs to be established"
kubectl wait --for=condition=Established \
  crd/installations.operator.tigera.io \
  crd/apiservers.operator.tigera.io \
  --timeout=120s

cat <<EOF_CALICO | kubectl create -f -
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    linuxDataplane: Iptables
    bgp: Disabled
    ipPools:
      - name: default-ipv4-ippool
        blockSize: 26
        cidr: ${POD_CIDR}
        encapsulation: VXLAN
        natOutgoing: Enabled
        nodeSelector: all()
---
apiVersion: operator.tigera.io/v1
kind: APIServer
metadata:
  name: default
spec: {}
EOF_CALICO

log "Creating a fresh worker join command"
JOIN_CMD="$(kubeadm token create --print-join-command)"

log "Joining worker nodes"
for ((i=0; i<WORKER_COUNT; i++)); do
  target="$(remote_target "$i")"
  prefix="$(remote_sudo "$i")"
  log "Joining ${WORKER_NAMES[$i]} (${WORKER_IPS[$i]})"
  ssh "${SSH_ARGS[@]}" "$target" \
    "${prefix}${JOIN_CMD} --node-name '${WORKER_NAMES[$i]}' --cri-socket '${CRI_SOCKET}'"
done

if [[ "$ALLOW_SCHEDULING_ON_MASTER" == "true" ]]; then
  log "Removing control-plane scheduling taint"
  kubectl taint nodes "$MASTER_HOSTNAME" node-role.kubernetes.io/control-plane- 2>/dev/null || true
fi

log "Waiting for all nodes to become Ready"
if ! kubectl wait --for=condition=Ready node --all --timeout=600s; then
  warn "Not every node became Ready within 10 minutes. Diagnostics follow."
  kubectl get nodes -o wide || true
  kubectl get pods -A -o wide || true
  kubectl get tigerastatus 2>/dev/null || true
  exit 1
fi

log "Waiting for Calico status resources to report availability"
for _ in {1..60}; do
  statuses="$(kubectl get tigerastatus --no-headers 2>/dev/null || true)"
  if [[ -n "$statuses" ]] && ! awk '{if ($2 != "True") bad=1} END{exit bad}' <<< "$statuses"; then
    break
  fi
  sleep 5
done

printf '\n============================================================\n'
log "Fresh Kubernetes cluster deployment finished"
printf '============================================================\n'
kubectl get nodes -o wide
printf '\n'
kubectl get pods -A
printf '\n'
kubectl get tigerastatus 2>/dev/null || true

cat <<EOF_DONE

Useful checks:
  kubectl get nodes -o wide
  kubectl get pods -A
  kubectl get tigerastatus
  kubectl cluster-info
  systemctl status kubelet --no-pager
  systemctl status containerd --no-pager

Admin kubeconfig:
  /etc/kubernetes/admin.conf

This installer is destructive. Re-running it and typing REBUILD will erase and
recreate the Kubernetes cluster on the same listed nodes.
EOF_DONE
