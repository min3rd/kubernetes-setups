#!/bin/bash

set -e

echo "=================================="
echo " Kubernetes Full Uninstall Script "
echo "      CentOS 9 / ArgoCD + Nginx   "
echo "=================================="

read -p "Enter Kubernetes data directory to remove (example /data/k8s): " DATA_DIR
read -p "Remove Kubernetes packages (kubelet, kubeadm, kubectl, containerd)? [y/N]: " REMOVE_PKGS

echo
echo "--- Step 1: Remove ArgoCD and Nginx App resources ---"

export KUBECONFIG=/etc/kubernetes/admin.conf

if kubectl cluster-info &>/dev/null 2>&1; then
  echo "Deleting ArgoCD Application nginx-app..."
  kubectl delete application nginx-app -n argocd --ignore-not-found=true 2>/dev/null || true

  echo "Deleting nginx-app namespace..."
  kubectl delete namespace nginx-app --ignore-not-found=true 2>/dev/null || true

  echo "Deleting NGINX Ingress Controller..."
  kubectl delete -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.10.1/deploy/static/provider/baremetal/deploy.yaml \
    --ignore-not-found=true 2>/dev/null || true

  echo "Deleting ArgoCD..."
  kubectl delete -n argocd -f \
    https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml \
    --ignore-not-found=true 2>/dev/null || true

  echo "Deleting argocd namespace..."
  kubectl delete namespace argocd --ignore-not-found=true 2>/dev/null || true

  echo "Deleting ingress-nginx namespace..."
  kubectl delete namespace ingress-nginx --ignore-not-found=true 2>/dev/null || true
else
  echo "Cluster not reachable, skipping namespace cleanup."
fi

echo
echo "--- Step 2: Stopping Kubernetes services ---"

systemctl stop kubelet 2>/dev/null || true
systemctl disable kubelet 2>/dev/null || true

echo
echo "--- Step 3: Reset kubeadm ---"

kubeadm reset -f 2>/dev/null || true

echo "Unmounting kubelet mounts..."
for m in $(mount 2>/dev/null | grep kubelet | awk '{print $3}'); do
  umount -l "$m" 2>/dev/null || true
done

echo
echo "--- Step 4: Cleaning system directories ---"

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

echo
echo "--- Step 5: Cleaning iptables rules ---"

iptables -F
iptables -t nat -F
iptables -t mangle -F
iptables -X
ip6tables -F 2>/dev/null || true
ip6tables -t nat -F 2>/dev/null || true
ip6tables -X 2>/dev/null || true

echo
echo "--- Step 6: Removing virtual network interfaces ---"

ip link delete cni0     2>/dev/null || true
ip link delete flannel.1 2>/dev/null || true
ip link delete kube-ipvs0 2>/dev/null || true

for iface in $(ip link show | grep -oP '(?<=\d: )(veth[^\@]+)'); do
  ip link delete "$iface" 2>/dev/null || true
done

echo
echo "--- Step 7: Stopping containerd ---"

systemctl stop containerd 2>/dev/null || true
systemctl disable containerd 2>/dev/null || true

if [[ "${REMOVE_PKGS,,}" == "y" || "${REMOVE_PKGS,,}" == "yes" ]]; then
  echo
  echo "--- Step 8: Removing Kubernetes and containerd packages ---"

  dnf remove -y kubelet kubeadm kubectl 2>/dev/null || true
  dnf remove -y containerd 2>/dev/null || true
  dnf autoremove -y 2>/dev/null || true

  echo "Removing Kubernetes yum repo..."
  rm -f /etc/yum.repos.d/kubernetes.repo

  echo "Removing kernel config files..."
  rm -f /etc/modules-load.d/k8s.conf
  rm -f /etc/sysctl.d/k8s.conf
  sysctl --system 2>/dev/null || true

  echo "Removing Helm..."
  rm -f /usr/local/bin/helm
else
  echo
  echo "--- Step 8: Skipping package removal ---"
fi

if [ -n "$DATA_DIR" ]; then
  echo
  echo "--- Removing custom data directory: $DATA_DIR ---"
  rm -rf "${DATA_DIR:?}/"
fi

echo
echo "--- Reloading systemd ---"

systemctl daemon-reexec
systemctl reset-failed 2>/dev/null || true

echo
echo "=================================="
echo " Kubernetes removed successfully  "
echo "=================================="
echo
echo " NOTE: Reboot the server to fully"
echo " clear kernel state and iptables."
echo "=================================="