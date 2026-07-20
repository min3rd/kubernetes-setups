# Kubernetes Setups (CentOS/RHEL 9 — K8s v1.29)

Cài đặt cụm Kubernetes dạng **master + worker** trên CentOS 9 / Rocky 9 / RHEL 9
bằng containerd, flannel CNI, NGINX Ingress và ArgoCD.

## Thành phần cài đặt

| Thành phần        | Chi tiết                                              |
|-------------------|-------------------------------------------------------|
| Container runtime | containerd (SystemdCgroup = true)                     |
| Kubernetes        | v1.29 (kubelet / kubeadm / kubectl)                   |
| CNI               | flannel (pod subnet `10.244.0.0/16`)                  |
| Ingress           | NGINX Ingress Controller (baremetal, NodePort 80/443) |
| GitOps            | ArgoCD (NodePort 30080, mode `--insecure`)            |
| Tooling           | Helm 3                                               |

## Cấu trúc script

| File                 | Mô tả                                                        |
|----------------------|--------------------------------------------------------------|
| `common.sh`          | Hàm dùng chung (kernel, firewall, containerd, k8s, helm).    |
| `install-master.sh`  | Cài master **non-interactive** qua env var / `.env`. Chạy SSH/Ansible.|
| `install-worker.sh`  | Cài worker **non-interactive** qua env var / `.env`. Chạy SSH/Ansible.|
| `uninstall.sh`       | Gỡ toàn bộ.                                                  |

## Cấu hình qua file `.env` (khuyên dùng)

Thay vì truyền env var trên dòng lệnh, bạn có thể đặt cấu hình vào file `.env`:

```bash
cp .env.example .env
# sửa IP, token... trong .env
sudo bash install-master.sh     # tự động đọc ./env
sudo bash install-worker.sh     # tự động đọc ./env
```

Quy tắc:
- Mỗi biến một dòng `KEY=value`; dòng `#` là comment.
- Biến truyền trực tiếp (`MASTER_IP=... bash script.sh`) **ghi đè** giá trị trong `.env`.
- Chỉ định file khác: `ENV_FILE=/path/file sudo bash install-master.sh`.
- File `.env` đã được thêm vào `.gitignore` để không lỡ commit thông tin môi trường.

Biến có thể đặt trong `.env`:

| Biến           | Dùng cho | Bắt buộc | Mặc định      |
|----------------|----------|----------|---------------|
| `MASTER_IP`    | master   | ✅       | —             |
| `DATA_DIR`     | cả hai   | ❌       | `/data/k8s`   |
| `NODE_HOSTNAME`| cả hai   | ❌       | `$(hostname)` |
| `POD_SUBNET`   | master   | ❌       | `10.244.0.0/16` |
| `K8S_VERSION`  | master   | ❌       | `v1.29.0`     |
| `JOIN_CMD`     | worker   | ✅*      | —             |
| `TOKEN`        | worker   | ✅*      | —             |
| `HASH`         | worker   | ✅*      | —             |

\* Worker cần `JOIN_CMD` HOẶC (`MASTER_IP` + `TOKEN` + `HASH`).

### Lấy token join cho worker

Trên master, sau khi cài xong (hoặc token cũ hết hạn sau 2h):

```bash
kubeadm token create --print-join-command
# đưa vào .env:  JOIN_CMD="<kết quả ở trên>"
```

## Cách chạy tự động (non-interactive, khuyên dùng cho Ansible/SSH)

### Master

```bash
sudo MASTER_IP=10.0.0.10 DATA_DIR=/data/k8s bash install-master.sh
```

Biến môi trường master:

| Biến           | Bắt buộc | Mặc định     | Ý nghĩa                     |
|----------------|----------|--------------|-----------------------------|
| `MASTER_IP`    | ✅       | —            | IP advertise của API server |
| `DATA_DIR`     | ❌       | `/data/k8s`  | Thư mục dữ liệu             |
| `NODE_HOSTNAME`| ❌       | `$(hostname)`| Hostname node               |
| `POD_SUBNET`   | ❌       | `10.244.0.0/16`| Dải pod subnet            |
| `K8S_VERSION`  | ❌       | `v1.29.0`    | Phiên bản K8s               |

Cuối cài đặt, lệnh join worker được in ra và lưu tại `/root/k8s-join-command.sh`.

### Worker

Cung cấp lệnh join bằng **1 trong 2 cách**:

```bash
# Cách A: dán nguyên lệnh join
sudo JOIN_CMD="$(ssh master 'cat /root/k8s-join-command.sh')" bash install-worker.sh

# Cách B: truyền từng phần
sudo MASTER_IP=10.0.0.10 TOKEN=xxxx HASH=sha256:yyyy bash install-worker.sh
```

Kiểm tra trên master: `kubectl get nodes`.

## Ví dụ Ansible (không kèm file playbook)

```yaml
# inventory
master ansible_host=10.0.0.10
worker ansible_host=10.0.0.11

# chạy
- hosts: master
  become: true
  tasks:
    - shell: "MASTER_IP={{ ansible_host }} bash /opt/k8s/install-master.sh"
- hosts: worker
  become: true
  tasks:
    - shell: "JOIN_CMD='{{ hostvars['master']['join_cmd'] }}' bash /opt/k8s/install-worker.sh"
```

(Token có hạn dùng 2h; nếu hết hạn, chạy `kubeadm token create --print-join-command`
trên master để lấy mới.)

## NodePort range

Script mở rộng `service-node-port-range` thành `80-32767` để expose NGINX Ingress
qua port 80/443. Bỏ phần `apiServer.extraArgs` trong `install-master.sh` nếu không cần.

## Gỡ cài đặt

```bash
sudo bash uninstall.sh
```

Sau đó khởi động lại server để dọn sạch kernel state & iptables.

## Khắc phục nhanh

| Triệu chứng                          | Xử lý                                                       |
|--------------------------------------|-------------------------------------------------------------|
| Worker join lỗi preflight hostname   | Script tự thêm `IP hostname` vào `/etc/hosts`. Kiểm tra lại. |
| Worker không join được               | Firewall chặn 6443/10250 — `firewall-cmd --list-all`.      |
| Pod không liên lạc được              | Port flannel `8472/udp`, `8285/udp` bị chặn.               |
| Patch NodePort 80/443 lỗi            | Đã mở `service-node-port-range` trong config.              |
| kubectl báo không kết nối            | `export KUBECONFIG=/etc/kubernetes/admin.conf`.             |
