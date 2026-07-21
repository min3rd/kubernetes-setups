#!/bin/bash
#
# Cài đặt Kubernetes WORKER (non-interactive) - CentOS/RHEL 9, K8s v1.29
#
# Biến môi trường (chọn 1 trong 2 cách cung cấp lệnh join):
#   Cách A - dán nguyên lệnh join:
#     JOIN_CMD="kubeadm join 10.0.0.10:6443 --token xxx --discovery-token-ca-cert-hash sha256:yyy"
#   Cách B - truyền từng phần:
#     MASTER_IP=10.0.0.10  TOKEN=xxxx  HASH=sha256:yyyy
#
#   DATA_DIR     (tùy chọn) thư mục dữ liệu, mặc định /data/k8s
#   NODE_HOSTNAME(tùy chọn) hostname node, mặc định $(hostname)
#
# Cấu hình cũng có thể đọc từ file .env (cùng thư mục với script, hoặc
# chỉ định ENV_FILE=/path/to/file). Biến truyền trực tiếp sẽ ghi đè .env.
#
# Ví dụ:
#   sudo JOIN_CMD="$(ssh master 'cat /root/k8s-join-command.sh')" bash install-worker.sh
#   sudo MASTER_IP=10.0.0.10 TOKEN=xxxx HASH=sha256:yyyy bash install-worker.sh
#   sudo bash install-worker.sh               # đọc từ .env (hoặc ENV_FILE)
#
set -eo pipefail
source "$(dirname "$0")/common.sh"
load_env

DATA_DIR="${DATA_DIR:-/data/k8s}"
NODE_HOSTNAME="${NODE_HOSTNAME:-$(hostname)}"

if [[ -n "$JOIN_CMD" ]]; then
  echo "[debug] Dùng JOIN_CMD có sẵn."
elif [[ -n "$MASTER_IP" && -n "$TOKEN" && -n "$HASH" ]]; then
  JOIN_CMD="kubeadm join ${MASTER_IP}:6443 --token ${TOKEN} --discovery-token-ca-cert-hash ${HASH}"
  echo "[debug] Build JOIN_CMD từ MASTER_IP/TOKEN/HASH."
else
  fail "Cần cung cấp JOIN_CMD HOẶC (MASTER_IP + TOKEN + HASH) trong .env."
fi
[[ -n "$JOIN_CMD" ]] || fail "JOIN_CMD rỗng."
echo "[debug] JOIN_CMD chứa: $JOIN_CMD"
[[ "$JOIN_CMD" == kubeadm\ join* ]] || fail "Lệnh join phải bắt đầu bằng 'kubeadm join ...'."

mkdir -p "$DATA_DIR"
setup_hostname "$NODE_HOSTNAME"

disable_selinux_swap
configure_kernel
configure_firewall worker
install_base
install_containerd
install_kubernetes
install_helm

log "Join vào cluster"
eval "$JOIN_CMD"

echo -e "\n\033[1;32m=========================================================="
echo "  WORKER ĐÃ JOIN THÀNH CÔNG"
echo "==========================================================\033[0m"
echo "  Kiểm tra trên master:  kubectl get nodes"
echo "=========================================================="
