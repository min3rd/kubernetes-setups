#!/bin/bash
#
# Cài đặt Kubernetes MASTER (non-interactive) - CentOS/RHEL 9, K8s v1.29
#
# Biến môi trường:
#   MASTER_IP    (bắt buộc) IP để advertise API server
#   DATA_DIR     (tùy chọn) thư mục dữ liệu, mặc định /data/k8s
#   NODE_HOSTNAME(tùy chọn) hostname node, mặc định $(hostname)
#   POD_SUBNET   (tùy chọn) mặc định 10.244.0.0/16
#   K8S_VERSION  (tùy chọn) mặc định v1.29.0
#
# Cấu hình cũng có thể đọc từ file .env (cùng thư mục với script, hoặc
# chỉ định ENV_FILE=/path/to/file). Biến truyền trực tiếp sẽ ghi đè .env.
#
# Ví dụ:
#   sudo MASTER_IP=10.0.0.10 DATA_DIR=/data/k8s bash install-master.sh
#   sudo bash install-master.sh                 # đọc từ ./env (hoặc ENV_FILE)
#
set -eo pipefail
source "$(dirname "$0")/common.sh"
load_env

MASTER_IP="${MASTER_IP:?Thiếu MASTER_IP (truyền env hoặc đặt trong .env)}"
DATA_DIR="${DATA_DIR:-/data/k8s}"
NODE_HOSTNAME="${NODE_HOSTNAME:-$(hostname)}"
POD_SUBNET="${POD_SUBNET:-10.244.0.0/16}"
K8S_VERSION="${K8S_VERSION:-v1.29.0}"

mkdir -p "$DATA_DIR"
setup_hostname "$NODE_HOSTNAME"

disable_selinux_swap
configure_kernel
configure_firewall master
install_base
install_containerd
install_kubernetes
install_helm

log "Tạo kubeadm config"
cat > /root/kubeadm-config.yaml <<EOF
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
localAPIEndpoint:
  advertiseAddress: ${MASTER_IP}
  bindPort: 6443
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: ${K8S_VERSION}
networking:
  podSubnet: ${POD_SUBNET}
  serviceSubnet: 10.96.0.0/12
apiServer:
  extraArgs:
    # Cho phép NodePort trong dải 80-32767 để expose ingress qua port 80/443
    service-node-port-range: 80-32767
etcd:
  local:
    dataDir: ${DATA_DIR}/etcd
EOF

log "Khởi tạo Kubernetes control-plane"
kubeadm init --config /root/kubeadm-config.yaml --upload-certs

export KUBECONFIG=/etc/kubernetes/admin.conf
mkdir -p "$HOME/.kube"
cp /etc/kubernetes/admin.conf "$HOME/.kube/config"
chown "$(id -u):$(id -g)" "$HOME/.kube/config"

log "Bỏ taint control-plane (cho phép chạy pod trên master - single node)"
kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || true

log "Cài đặt Flannel CNI"
kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml
kubectl rollout status daemonset/kube-flannel-ds -n kube-flannel --timeout=180s || true

log "Chờ node master sẵn sàng (Ready)..."
kubectl wait --for=condition=Ready "node/$(hostname)" --timeout=180s || true

log "Cài đặt NGINX Ingress Controller"
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.10.1/deploy/static/provider/baremetal/deploy.yaml
kubectl rollout status deployment/ingress-nginx-controller -n ingress-nginx --timeout=180s || true

log "Expose NGINX Ingress qua NodePort 80/443"
kubectl patch svc ingress-nginx-controller -n ingress-nginx \
  --type='json' -p='[
  {"op":"replace","path":"/spec/ports/0/nodePort","value":80},
  {"op":"replace","path":"/spec/ports/1/nodePort","value":443}
]' || true

log "Cài đặt ArgoCD"
kubectl create namespace argocd 2>/dev/null || true
kubectl apply -n argocd -f \
  https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml \
  --server-side
kubectl patch deployment argocd-server -n argocd \
  --type='json' -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--insecure"}]' || true
kubectl patch svc argocd-server -n argocd \
  -p '{"spec":{"type":"NodePort","ports":[{"port":80,"targetPort":8080,"nodePort":30080,"protocol":"TCP","name":"http"}]}}' || true
kubectl wait --for=condition=Available deployment/argocd-server -n argocd --timeout=300s || true
kubectl -n argocd wait --for=condition=Ready secret/argocd-initial-admin-secret --timeout=300s 2>/dev/null || true
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)

log "Tạo lệnh join cho worker"
kubeadm token create --print-join-command > /root/k8s-join-command.sh
chmod 600 /root/k8s-join-command.sh

echo -e "\n\033[1;32m=========================================================="
echo "  CÀI ĐẶT MASTER HOÀN TẤT"
echo "==========================================================\033[0m"
echo "  ArgoCD URL     : http://${MASTER_IP}:30080"
echo "  ArgoCD User    : admin"
echo "  ArgoCD Pass    : ${ARGOCD_PASSWORD}"
echo "  Ingress NodePort: 80 / 443"
echo
echo "  Lệnh join worker:"
echo "    $(cat /root/k8s-join-command.sh)"
echo "=========================================================="
