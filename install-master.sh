#!/bin/bash
#
# Cài đặt Kubernetes MASTER (non-interactive, hỗ trợ HA nhiều master)
#   CentOS/RHEL 9, K8s v1.29
#
# Biến môi trường:
#   MASTER_IP              (bắt buộc) IP advertise của node này (localAPIEndpoint)
#   CONTROL_PLANE_ENDPOINT (tùy chọn) VIP:6443 hoặc LB:6443 cho HA.
#                           Nếu có -> tạo cụm HA. Worker/master khác kết nối qua đây.
#   FIRST_MASTER           (tùy chọn) "true" (mặc định) nếu là master đầu tiên (kubeadm init).
#                           "false" nếu là master bổ sung (kubeadm join --control-plane).
#   DATA_DIR               (tùy chọn) thư mục dữ liệu, mặc định /data/k8s
#   NODE_HOSTNAME          (tùy chọn) hostname node, mặc định $(hostname)
#   POD_SUBNET             (tùy chọn) mặc định 10.244.0.0/16
#   K8S_VERSION            (tùy chọn) mặc định v1.29.0
#
# Cấu hình cũng có thể đọc từ file .env (hoặc ENV_FILE=/path/to/file).
#
# Trường hợp MASTER BỔ SUNG (FIRST_MASTER=false) cần thêm một trong 2:
#   Cách A: JOIN_CMD="kubeadm join <endpoint>:6443 --token ... --discovery-token-ca-cert-hash ... --control-plane --certificate-key ..."
#   Cách B: MASTER_IP + TOKEN + HASH + CERT_KEY  (CONTROL_PLANE_ENDPOINT nếu đã đặt khi init)
#
# Ví dụ:
#   # Master đầu (HA qua VIP 10.0.0.100:6443)
#   sudo MASTER_IP=10.0.0.10 CONTROL_PLANE_ENDPOINT=10.0.0.100:6443 bash install-master.sh
#   # Master bổ sung
#   sudo MASTER_IP=10.0.0.11 FIRST_MASTER=false JOIN_CMD="$(ssh master1 'cat /root/k8s-controlplane-join.sh')" bash install-master.sh
#
set -eo pipefail
source "$(dirname "$0")/common.sh"
load_env

MASTER_IP="${MASTER_IP:?Thiếu MASTER_IP (truyền env hoặc đặt trong .env)}"
CONTROL_PLANE_ENDPOINT="${CONTROL_PLANE_ENDPOINT:-}"
FIRST_MASTER="${FIRST_MASTER:-true}"
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

# ============================================================
# MASTER ĐẦU TIÊN -> kubeadm init
# ============================================================
if [[ "$FIRST_MASTER" == "true" ]]; then

  log "Tạo kubeadm config"
  {
    cat <<EOF
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
localAPIEndpoint:
  advertiseAddress: ${MASTER_IP}
  bindPort: 6443
EOF
    # Nếu có VIP/LB thì khai báo controlPlaneEndpoint để cụm HA
    if [[ -n "$CONTROL_PLANE_ENDPOINT" ]]; then
      cat <<EOF
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
controlPlaneEndpoint: ${CONTROL_PLANE_ENDPOINT}
kubernetesVersion: ${K8S_VERSION}
networking:
  podSubnet: ${POD_SUBNET}
  serviceSubnet: 10.96.0.0/12
apiServer:
  extraArgs:
    service-node-port-range: 80-32767
etcd:
  local:
    dataDir: ${DATA_DIR}/etcd
EOF
    else
      cat <<EOF
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: ${K8S_VERSION}
networking:
  podSubnet: ${POD_SUBNET}
  serviceSubnet: 10.96.0.0/12
apiServer:
  extraArgs:
    service-node-port-range: 80-32767
etcd:
  local:
    dataDir: ${DATA_DIR}/etcd
EOF
    fi
  } > /root/kubeadm-config.yaml

  log "Khởi tạo Kubernetes control-plane (master đầu)"
  kubeadm init --config /root/kubeadm-config.yaml --upload-certs

  export KUBECONFIG=/etc/kubernetes/admin.conf
  mkdir -p "$HOME/.kube"
  cp /etc/kubernetes/admin.conf "$HOME/.kube/config"
  chown "$(id -u):$(id -g)" "$HOME/.kube/config"

  log "Bỏ taint control-plane (cho phép chạy pod trên master)"
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

  # --- Sinh lệnh join ---
  log "Tạo lệnh join cho worker"
  kubeadm token create --print-join-command > /root/k8s-join-command.sh
  chmod 600 /root/k8s-join-command.sh

  log "Tạo lệnh join cho control-plane (master bổ sung)"
  if [[ -n "${JOIN_CMD_CONTROL_PLANE:-}" ]]; then
    echo "${JOIN_CMD_CONTROL_PLANE}" > /root/k8s-controlplane-join.sh
  else
    CERT_KEY=$(kubeadm certs certificate-key)
    JOIN_LINE=$(kubeadm token create --print-join-command)
    TOKEN_VAL=$(echo "$JOIN_LINE" | awk '{for(i=1;i<=NF;i++) if($i=="--token"){print $(i+1)}}')
    HASH_VAL=$(echo "$JOIN_LINE" | grep -o 'sha256:[a-f0-9]*')
    CP_ENDPOINT="${CONTROL_PLANE_ENDPOINT:-${MASTER_IP}:6443}"
    echo "kubeadm join ${CP_ENDPOINT} --token ${TOKEN_VAL} --discovery-token-ca-cert-hash ${HASH_VAL} --control-plane --certificate-key ${CERT_KEY}" \
      > /root/k8s-controlplane-join.sh
  fi
  chmod 600 /root/k8s-controlplane-join.sh

  echo -e "\n\033[1;32m=========================================================="
  echo "  CÀI ĐẶT MASTER ĐẦU HOÀN TẤT (HA: ${CONTROL_PLANE_ENDPOINT:-single})"
  echo "==========================================================\033[0m"
  echo "  ArgoCD URL     : http://${MASTER_IP}:30080"
  echo "  ArgoCD User    : admin"
  echo "  ArgoCD Pass    : ${ARGOCD_PASSWORD}"
  echo "  Ingress NodePort: 80 / 443"
  echo
  echo "  Lệnh join WORKER:"
  echo "    $(cat /root/k8s-join-command.sh)"
  echo
  echo "  Lệnh join MASTER BỔ SUNG (FIRST_MASTER=false):"
  echo "    $(cat /root/k8s-controlplane-join.sh)"
  echo "=========================================================="

# ============================================================
# MASTER BỔ SUNG -> kubeadm join --control-plane
# ============================================================
else
  if [[ -n "${JOIN_CMD_CONTROL_PLANE:-}" ]]; then
    JOIN_CMD="${JOIN_CMD_CONTROL_PLANE}"
  elif [[ -n "$JOIN_CMD" ]]; then
    : # tương thích ngược
  elif [[ -n "$MASTER_IP" && -n "$TOKEN" && -n "$HASH" && -n "$CERT_KEY" ]]; then
    CP_ENDPOINT="${CONTROL_PLANE_ENDPOINT:-${MASTER_IP}:6443}"
    JOIN_CMD="kubeadm join ${CP_ENDPOINT} --token ${TOKEN} --discovery-token-ca-cert-hash ${HASH} --control-plane --certificate-key ${CERT_KEY}"
  else
    fail "Master bổ sung cần JOIN_CMD HOẶC (MASTER_IP + TOKEN + HASH + CERT_KEY)."
  fi
  [[ "$JOIN_CMD" == kubeadm\ join* ]] || fail "Lệnh join phải bắt đầu bằng 'kubeadm join ...'."
  [[ "$JOIN_CMD" == *--control-plane* ]] || fail "Master bổ sung cần lệnh join chứa '--control-plane'."

  log "Join vào control-plane (master bổ sung)"
  eval "$JOIN_CMD"

  export KUBECONFIG=/etc/kubernetes/admin.conf
  mkdir -p "$HOME/.kube"
  cp /etc/kubernetes/admin.conf "$HOME/.kube/config"
  chown "$(id -u):$(id -g)" "$HOME/.kube/config"

  echo -e "\n\033[1;32m=========================================================="
  echo "  MASTER BỔ SUNG ĐÃ JOIN THÀNH CÔNG"
  echo "==========================================================\033[0m"
  echo "  Kiểm tra trên bất kỳ master:  kubectl get nodes"
  echo "=========================================================="
fi
