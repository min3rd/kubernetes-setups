#!/bin/bash
# common.sh - các hàm cài đặt dùng chung cho K8s trên CentOS/RHEL 9
# Sử dụng:  source "$(dirname "$0")/common.sh"  (phải chạy bằng root)
#
# Không thực thi lệnh nào khi được source, chỉ định nghĩa hàm.

fail() { echo -e "\033[1;31m[ERROR] $*\033[0m"; exit 1; }
log()  { echo -e "\n\033[1;32m========== $* ==========\033[0m"; }
warn() { echo -e "\033[1;33m[WARN] $*\033[0m"; }

[[ $EUID -eq 0 ]] || fail "Script phải chạy với quyền root (sudo)."

# Đọc cấu hình từ file .env (hoặc ENV_FILE=/path/to/file).
# - Biến đã được export sẵn (truyền trực tiếp) vẫn giữ nguyên, KHÔNG bị ghi đè.
# - Chỉ load các biến KEY=VALUE, bỏ qua dòng comment (#) và dòng trống.
load_env() {
  local env_file="${ENV_FILE:-$(dirname "$0")/.env}"
  [[ -f "$env_file" ]] || return 0
  log "Đọc cấu hình từ $env_file"
  local line key val
  while IFS= read -r line || [[ -n "$line" ]]; do
    # bỏ khoảng trắng đầu/cuối, bỏ qua comment & dòng trống
    line="$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [[ -z "$line" || "$line" == \#* ]] && continue
    key="${line%%=*}"
    val="${line#*=}"
    # chỉ set nếu biến chưa được định nghĩa
    [[ -z "${!key+x}" ]] && export "$key=$val"
  done < "$env_file"
}

disable_selinux_swap() {
  log "Tắt SELinux & Swap"
  setenforce 0 2>/dev/null || true
  sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config 2>/dev/null || true
  sed -i 's/^SELINUX=disabled/SELINUX=permissive/'  /etc/selinux/config 2>/dev/null || true
  swapoff -a
  sed -i '/\bswap\b/d' /etc/fstab
}

configure_kernel() {
  log "Cấu hình kernel modules & sysctl"
  cat > /etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
  modprobe overlay
  modprobe br_netfilter
  cat > /etc/sysctl.d/k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
  sysctl --system
}

configure_firewall() {
  local role="$1"
  log "Cấu hình firewall ($role)"
  if systemctl is-active --quiet firewalld; then
    if [[ "$role" == "master" ]]; then
      firewall-cmd --permanent --add-port=6443/tcp      # kube-apiserver
      firewall-cmd --permanent --add-port=2379-2380/tcp # etcd
      firewall-cmd --permanent --add-port=10250/tcp     # kubelet API
      firewall-cmd --permanent --add-port=10251/tcp     # kube-scheduler
      firewall-cmd --permanent --add-port=10252/tcp     # kube-controller-manager
      firewall-cmd --permanent --add-port=10255/tcp     # kubelet read-only
    else
      firewall-cmd --permanent --add-port=10250/tcp     # kubelet API
    fi
    firewall-cmd --permanent --add-port=8285/udp        # flannel udp
    firewall-cmd --permanent --add-port=8472/udp        # flannel vxlan
    firewall-cmd --permanent --add-port=30000-32767/tcp # NodePort range
    firewall-cmd --reload
    echo "Firewall: các port cần thiết đã mở."
  else
    warn "firewalld không hoạt động; đảm bảo các port (6443, 10250, 8472/udp, 30000-32767) được mở bởi firewall khác."
  fi
}

setup_hostname() {
  local name="${1:-$(hostname)}"
  hostnamectl set-hostname "$name" 2>/dev/null || true
  local ip
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
  if [[ -n "$ip" && -z "$(grep -w "$name" /etc/hosts)" ]]; then
    echo "$ip $name" >> /etc/hosts
  fi
}

install_base() {
  log "Cài đặt gói cơ bản"
  dnf install -y yum-utils device-mapper-persistent-data lvm2 git curl wget
}

install_containerd() {
  log "Cài đặt containerd"
  dnf install -y containerd
  mkdir -p /etc/containerd
  containerd config default > /etc/containerd/config.toml
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  sed -i 's#sandbox_image = ".*"#sandbox_image = "registry.k8s.io/pause:3.9"#' /etc/containerd/config.toml
  systemctl enable --now containerd
}

install_kubernetes() {
  log "Cài đặt Kubernetes"
  cat > /etc/yum.repos.d/kubernetes.repo <<'EOF'
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.29/rpm/
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.29/rpm/repodata/repomd.xml.key
EOF
  dnf install -y kubelet kubeadm kubectl --disableexcludes=kubernetes
  systemctl enable kubelet
}

install_helm() {
  log "Cài đặt Helm"
  export PATH=$PATH:/usr/local/bin
  if ! command -v helm &>/dev/null; then
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  fi
  helm version || true
}
