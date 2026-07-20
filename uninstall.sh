#!/bin/bash
#
# Kubernetes Full Uninstall
#   CentOS / RHEL 9 - dọn dẹp toàn bộ K8s + containerd + addons
#
# Chạy với quyền root:  sudo bash uninstall.sh
#
set -eo pipefail

[[ $EUID -eq 0 ]] || { echo "[ERROR] Phải chạy với quyền root (sudo bash uninstall.sh)."; exit 1; }

echo "=================================="
echo "  Kubernetes Full Uninstall"
echo "  CentOS/RHEL 9 - K8s + containerd"
echo "=================================="

read -rp "Thư mục dữ liệu Kubernetes để xoá [ví dụ /data/k8s]: " DATA_DIR
read -rp "Gỡ bỏ luôn gói (kubelet, kubeadm, kubectl, containerd)? [y/N]: " REMOVE_PKGS

export KUBECONFIG=/etc/kubernetes/admin.conf

# --- Step 1: Xoá addons (ArgoCD / Ingress / app) ---
echo
echo "--- Step 1: Xoá ArgoCD, NGINX Ingress & app resources ---"
if kubectl cluster-info &>/dev/null 2>&1; then
  kubectl delete application nginx-app -n argocd --ignore-not-found=true 2>/dev/null || true
  kubectl delete namespace nginx-app --ignore-not-found=true 2>/dev/null || true
  kubectl delete -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.10.1/deploy/static/provider/baremetal/deploy.yaml \
    --ignore-not-found=true 2>/dev/null || true
  kubectl delete -n argocd -f \
    https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml \
    --ignore-not-found=true 2>/dev/null || true
  kubectl delete namespace argocd --ignore-not-found=true 2>/dev/null || true
  kubectl delete namespace ingress-nginx --ignore-not-found=true 2>/dev/null || true
else
  echo "Cluster không reachable, bỏ qua xoá namespace."
fi

# --- Step 2: Dừng kubelet ---
echo
echo "--- Step 2: Dừng dịch vụ kubelet ---"
systemctl stop kubelet 2>/dev/null || true
systemctl disable kubelet 2>/dev/null || true

# --- Step 3: Reset kubeadm ---
echo
echo "--- Step 3: Reset kubeadm ---"
kubeadm reset -f 2>/dev/null || true
for m in $(mount 2>/dev/null | grep kubelet | awk '{print $3}'); do
  umount -l "$m" 2>/dev/null || true
done

# --- Step 4: Dọn thư mục hệ thống ---
echo
echo "--- Step 4: Xoá thư mục hệ thống ---"
rm -rf /etc/kubernetes
rm -rf /var/lib/kubelet
rm -rf /var/lib/etcd
rm -rf /etc/cni/net.d
rm -rf /var/lib/cni
rm -rf /opt/cni
rm -rf /run/containerd
rm -rf /var/lib/containerd
rm -rf /root/.kube
rm -f  /root/k8s-join-command.sh
rm -f  /root/kubeadm-config.yaml

# --- Step 5: Flush iptables ---
echo
echo "--- Step 5: Xoá iptables rules ---"
iptables -F 2>/dev/null || true
iptables -t nat -F 2>/dev/null || true
iptables -t mangle -F 2>/dev/null || true
iptables -X 2>/dev/null || true
ip6tables -F 2>/dev/null || true
ip6tables -t nat -F 2>/dev/null || true
ip6tables -X 2>/dev/null || true

# --- Step 6: Xoá interface ảo ---
echo
echo "--- Step 6: Xoá virtual network interfaces ---"
ip link delete cni0 2>/dev/null || true
ip link delete flannel.1 2>/dev/null || true
ip link delete kube-ipvs0 2>/dev/null || true
for iface in $(ip link show 2>/dev/null | grep -oP '(?<=\d: )(veth[^\@]+)'); do
  ip link delete "$iface" 2>/dev/null || true
done

# --- Step 7: Dừng containerd ---
echo
echo "--- Step 7: Dừng containerd ---"
systemctl stop containerd 2>/dev/null || true
systemctl disable containerd 2>/dev/null || true

# --- Step 8: Gỡ gói (tuỳ chọn) ---
if [[ "${REMOVE_PKGS,,}" == "y" || "${REMOVE_PKGS,,}" == "yes" ]]; then
  echo
  echo "--- Step 8: Gỡ bỏ gói Kubernetes & containerd ---"
  dnf remove -y kubelet kubeadm kubectl 2>/dev/null || true
  dnf remove -y containerd 2>/dev/null || true
  dnf autoremove -y 2>/dev/null || true
  rm -f /etc/yum.repos.d/kubernetes.repo
  rm -f /etc/modules-load.d/k8s.conf
  rm -f /etc/sysctl.d/k8s.conf
  sysctl --system 2>/dev/null || true
  rm -f /usr/local/bin/helm
else
  echo
  echo "--- Step 8: Bỏ qua gỡ gói (giữ lại để cài lại nhanh) ---"
fi

# --- Step 9: Xoá data dir ---
if [[ -n "$DATA_DIR" ]]; then
  echo
  echo "--- Step 9: Xoá thư mục dữ liệu: $DATA_DIR ---"
  rm -rf "${DATA_DIR:?}/"
fi

echo
echo "--- Reload systemd ---"
systemctl daemon-reexec
systemctl reset-failed 2>/dev/null || true

echo
echo "=================================="
echo "  Kubernetes đã được gỡ xong"
echo "=================================="
echo "  Ghi chú: khởi động lại server để"
echo "  xoá hoàn toàn kernel state/iptables."
echo "=================================="
