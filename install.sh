#!/bin/bash

set -e

echo "================================="
echo " Kubernetes Production Installer "
echo "      CentOS 9 / K8s v1.29       "
echo "================================="

read -p "Node role (master/worker): " ROLE
read -p "Kubernetes data directory (example /data/k8s): " DATA_DIR
read -p "Master API Server IP: " MASTER_IP

mkdir -p "$DATA_DIR"

echo "Disable SELinux & Swap"

setenforce 0 || true
sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config

swapoff -a
sed -i '/swap/d' /etc/fstab

echo "Kernel modules"

cat <<EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

echo "Kernel sysctl"

cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.ipv4.ip_forward=1
EOF

sysctl --system

echo
echo
echo
echo
echo
echo "================================="
echo "Install base packages"
echo "================================="

dnf install -y yum-utils device-mapper-persistent-data lvm2 git curl wget

echo
echo
echo
echo
echo
echo "================================="
echo "Install containerd"
echo "================================="

dnf install -y containerd

mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml

sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

systemctl enable containerd
systemctl restart containerd

echo
echo
echo
echo
echo
echo "================================="
echo "Install Kubernetes"
echo "================================="

cat <<EOF | tee /etc/yum.repos.d/kubernetes.repo
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

echo
echo
echo
echo
echo
echo "================================="
echo "Install Helm"
echo "================================="

export PATH=$PATH:/usr/local/bin

if ! command -v helm &> /dev/null
then
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

echo "Helm version:"
helm version || true

if [ "$ROLE" = "master" ]; then

echo
echo
echo
echo
echo
echo "================================="
echo "Initialize Kubernetes"
echo "================================="

echo "Create kubeadm config"

cat <<EOF > kubeadm-config.yaml
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: $MASTER_IP
  bindPort: 6443
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
networking:
  podSubnet: 10.244.0.0/16
etcd:
  local:
    dataDir: $DATA_DIR/etcd
EOF

echo "Initialize Kubernetes"

kubeadm init --config kubeadm-config.yaml

export KUBECONFIG=/etc/kubernetes/admin.conf

mkdir -p $HOME/.kube
sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

echo
echo
echo
echo
echo
echo "================================="
echo "Install Flannel network"
echo "================================="

kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml

echo "Wait for Flannel network to be ready..."
kubectl rollout status daemonset/kube-flannel-ds -n kube-flannel --timeout=120s || true
sleep 10

echo
echo
echo
echo
echo
echo "================================="
echo "Install NGINX Ingress Controller"
echo "================================="

kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.10.1/deploy/static/provider/baremetal/deploy.yaml

echo "Wait for NGINX Ingress Controller..."
kubectl rollout status deployment/ingress-nginx-controller -n ingress-nginx --timeout=180s || true

echo "Expose NGINX Ingress via NodePort 80/443"
kubectl patch svc ingress-nginx-controller -n ingress-nginx \
  --type='json' -p='
[
  {"op":"replace","path":"/spec/ports/0/nodePort","value":80},
  {"op":"replace","path":"/spec/ports/1/nodePort","value":443}
]' 2>/dev/null || true

echo
echo
echo
echo
echo
echo "================================="
echo "Install ArgoCD"
echo "================================="

kubectl create namespace argocd 2>/dev/null || true

kubectl apply -n argocd -f \
  https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml \
  --server-side

echo "Disable ArgoCD TLS (HTTP mode)..."
kubectl patch deployment argocd-server -n argocd \
  --type='json' -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--insecure"}]' || true

echo "Expose ArgoCD via NodePort 30080..."
kubectl patch svc argocd-server -n argocd \
  -p '{"spec":{"type":"NodePort","ports":[{"port":80,"targetPort":8080,"nodePort":30080,"protocol":"TCP","name":"http"}]}}' || true

echo "Wait for ArgoCD pods to be ready..."
kubectl wait --for=condition=Available deployment/argocd-server \
  -n argocd --timeout=300s || true

ARGOCD_PASSWORD=$(kubectl -n argocd wait --for=jsonpath='{.data.password}' \
  secret/argocd-initial-admin-secret --timeout=300s 2>/dev/null; \
  kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d)

echo
echo "Saving join command to /root/k8s-join-command.sh..."
kubeadm token create --print-join-command > /root/k8s-join-command.sh
chmod 600 /root/k8s-join-command.sh

echo
echo "=========================================================="
echo "  INSTALLATION COMPLETE"
echo "=========================================================="
echo
echo "  ArgoCD NodePort : http://$MASTER_IP:30080"
echo "  ArgoCD User     : admin"
echo "  ArgoCD Pass     : $ARGOCD_PASSWORD"
echo
echo "  Configure your external nginx to proxy_pass to:"
echo "    http://$MASTER_IP:30080"
echo
echo "  Worker join command saved to: /root/k8s-join-command.sh"
echo "=========================================================="

fi

if [ "$ROLE" = "worker" ]; then

echo
read -p "Paste the kubeadm join command from master: " JOIN_CMD
eval "$JOIN_CMD"

echo
echo "Worker node joined successfully."

fi

echo
echo "Installation complete"