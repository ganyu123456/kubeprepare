# KubeEdge 工业云边协同平台 — 完整 HA 部署手册

> 本文档是端到端的高可用部署指南，涵盖 K3s 集群 HA + CloudCore HA + EdgeCore 的完整安装流程。

---

## 目录

1. [架构规划](#1-架构规划)
2. [环境准备](#2-环境准备)
3. [第一阶段：安装 K3s 集群](#3-第一阶段安装-k3s-集群)
4. [第二阶段：配置 K3s API Server VIP](#4-第二阶段配置-k3s-api-server-vip)
5. [第五阶段：安装 CloudCore HA](#5-第三阶段安装-cloudcore-ha)
6. [第六阶段：配置 CloudCore VIP](#6-第四阶段配置-cloudcore-vip)
7. [第七阶段：安装 EdgeCore](#7-第五阶段安装-edgecore)
8. [验证整体链路](#8-验证整体链路)
9. [运维操作](#9-运维操作)
10. [常见问题](#10-常见问题)

---

## 1. 架构规划

### 1.1 推荐节点规划（生产环境）

| 节点 | IP | 角色 | 说明 |
|------|----|------|------|
| controller-1 | 192.168.1.10 | K3s init server | 初始化集群，第一个控制节点 |
| controller-2 | 192.168.1.11 | K3s server | HA 第二控制节点 |
| controller-3 | 192.168.1.12 | K3s server | HA 第三控制节点（etcd 奇数投票） |
| worker-1 | 192.168.1.20 | K3s agent | 工作节点（可按需扩容） |
| edge-1 | 192.168.2.10 | EdgeCore | 边缘节点 1 |
| edge-2 | 192.168.2.11 | EdgeCore | 边缘节点 2 |

### 1.2 VIP 规划

| VIP | 用途 | 管理工具 |
|-----|------|---------|
| 192.168.1.100 | K3s API Server VIP | keepalived（控制节点上） |
| 192.168.1.101 | CloudCore VIP | keepalived（控制节点上） |

> **重要**：两个 VIP 必须与节点 IP 在同一子网，且当前未被任何设备使用。

### 1.3 端口规划

**K3s 集群**

| 端口 | 协议 | 说明 |
|------|------|------|
| 6443 | TCP | K3s API Server |
| 2379-2380 | TCP | etcd peer/client |
| 10250 | TCP | kubelet |
| 8472 | UDP | flannel VXLAN |

**CloudCore**

| 端口 | 协议 | 说明 |
|------|------|------|
| 10000 | TCP | CloudHub（WebSocket，EdgeCore 连接） |
| 10001 | TCP | CloudHub（QUIC，可选） |
| 10002 | TCP | CloudStream（kubectl logs/exec） |
| 10003 | TCP | CloudStream 通道 |
| 10004 | TCP | CloudHub HTTPS |

---

## 2. 环境准备

### 2.1 操作系统要求

- Linux（Ubuntu 20.04/22.04、麒麟 V10、CentOS 8/Stream 9）
- 内核 ≥ 4.15
- 控制节点：建议 4C/8G/50G+
- 边缘节点：最低 1C/512M（ARM64 设备亦可）

### 2.2 网络要求

```bash
# 控制节点间需要互通（SSH + etcd + API Server 端口）
# 边缘节点到 CloudCore VIP 的 10000/10001/10002 端口需要可达

# 检查端口连通性（在边缘节点执行）
nc -zv 192.168.1.101 10000
nc -zv 192.168.1.101 10002
```

### 2.3 关闭 swap 和 SELinux/AppArmor

```bash
# 关闭 swap
sudo swapoff -a
sudo sed -i '/swap/d' /etc/fstab

# Ubuntu 关闭 AppArmor（可选）
sudo systemctl stop apparmor
sudo systemctl disable apparmor

# CentOS/麒麟 关闭 SELinux
sudo setenforce 0
sudo sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
```

### 2.4 时间同步

```bash
# 所有节点执行（云边时间偏差 > 5min 会导致证书认证失败）
sudo timedatectl set-timezone Asia/Shanghai
sudo timedatectl set-ntp true
timedatectl status
```

### 2.5 获取离线安装包

从 GitHub Releases 下载以下三个包（选择对应架构）：

```
k3s-cluster-<k3s_version>-amd64-<tag>.tar.gz
cloudcore-ha-v<kubeedge_version>-amd64-<tag>.tar.gz
edgecore-v<kubeedge_version>-amd64-<tag>.tar.gz
```

使用 sha256sum 校验完整性：

```bash
sha256sum -c k3s-cluster-*.sha256sum.txt
sha256sum -c cloudcore-ha-*.sha256sum.txt
sha256sum -c edgecore-*.sha256sum.txt
```

---

## 3. 第一阶段：安装 K3s 集群

### 3.1 解压安装包

在每个控制/工作节点上解压对应包：

```bash
mkdir -p /opt/k3s-cluster && cd /opt/k3s-cluster
tar -xzf /path/to/k3s-cluster-*.tar.gz
```

### 3.2 初始化首控制节点（controller-1）

```bash
# 在 controller-1 上执行
sudo ./install/install.sh --init 192.168.1.10 controller-1
```

安装完成后终端会输出：

```
=================================================
K3s 首节点初始化完成！
节点 IP: 192.168.1.10
节点名: controller-1

扩容第二/三控制节点：
  sudo ./install/install.sh --server 192.168.1.10:6443 K10xxx...::server:yyy controller-2

加入 Worker 节点：
  sudo ./install/install.sh --agent 192.168.1.10:6443 K10xxx...::server:yyy worker-01
=================================================
```

**保存 Token** 供后续步骤使用：

```bash
cat /var/lib/rancher/k3s/server/node-token
```

### 3.3 加入第二控制节点（controller-2）

```bash
# 在 controller-2 上执行（使用上一步的 Token）
sudo ./install/install.sh --server 192.168.1.10:6443 <TOKEN> 192.168.1.11 controller-2
```

### 3.4 加入第三控制节点（controller-3）

```bash
# 在 controller-3 上执行
sudo ./install/install.sh --server 192.168.1.10:6443 <TOKEN> 192.168.1.12 controller-3
```

### 3.5 验证 K3s 集群

```bash
# 在任意控制节点执行
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl get nodes -o wide
```

期望输出：

```
NAME           STATUS   ROLES                       AGE   VERSION
controller-1   Ready    control-plane,etcd,master   5m    v1.34.2+k3s1
controller-2   Ready    control-plane,etcd,master   3m    v1.34.2+k3s1
controller-3   Ready    control-plane,etcd,master   1m    v1.34.2+k3s1
```

### 3.6 加入 Worker 节点（可选）

```bash
# 在 worker-1 上执行
sudo ./install/install.sh --agent 192.168.1.10:6443 <TOKEN> worker-1
```

---

## 4. 第二阶段：配置 K3s API Server VIP

> 此步骤为可选但强烈推荐。VIP 可以在控制节点故障时自动切换，kubectl 和后续 cloudcore 等组件无需更改连接地址。

### 4.1 安装 keepalived

离线安装包内已包含 keepalived deb 包：

```bash
# 在所有控制节点上执行
cd /opt/k3s-cluster
sudo dpkg -i keepalived/*.deb 2>/dev/null || sudo apt-get install -f -y
```

### 4.2 配置 controller-1（主节点）

```bash
# 查看网卡名称
ip addr show | grep -E "^[0-9]+:" | awk '{print $2}'

# 复制并编辑配置文件（修改 INTERFACE、VIP 等占位符）
cp ./keepalived/keepalived-master.conf.tpl /etc/keepalived/keepalived.conf
vi /etc/keepalived/keepalived.conf
# 替换以下占位符：
# __INTERFACE__  → 实际网卡名（如 eth0、ens33）
# __VIP__        → 192.168.1.100
# __VIP_PREFIX__ → 24（对应 /24 子网掩码）
# __AUTH_PASS__  → 自定义密码（8字符以内，所有节点保持一致）

# 复制健康检查脚本
cp ./keepalived/check_apiserver.sh /etc/keepalived/
chmod +x /etc/keepalived/check_apiserver.sh

# 启动 keepalived
sudo systemctl enable keepalived
sudo systemctl start keepalived
```

### 4.3 配置 controller-2 和 controller-3（备节点）

```bash
# 使用 backup 模板，priority 分别设为 100 和 90
cp ./keepalived/keepalived-backup.conf.tpl /etc/keepalived/keepalived.conf
vi /etc/keepalived/keepalived.conf
# 同样替换占位符，注意 priority 要比 master 低
cp ./keepalived/check_apiserver.sh /etc/keepalived/
chmod +x /etc/keepalived/check_apiserver.sh
sudo systemctl enable keepalived && sudo systemctl start keepalived
```

### 4.4 验证 VIP

```bash
# 在任意节点检查 VIP 是否绑定
ip addr show | grep 192.168.1.100

# 通过 VIP 访问 API Server
kubectl --server=https://192.168.1.100:6443 \
  --kubeconfig=/etc/rancher/k3s/k3s.yaml get nodes
```

---

## 5. 第三阶段：安装 CloudCore HA

### 5.1 解压安装包

在 **controller-1**（或任意一台控制节点）上执行：

```bash
mkdir -p /opt/cloudcore && cd /opt/cloudcore
tar -xzf /path/to/cloudcore-ha-v*.tar.gz
```

### 5.2 执行安装

```bash
# 格式：sudo ./install/install.sh --vip <VIP> --nodes "<IP1>[,IP2,IP3]" [--replicas N]
# 单副本（测试用）
sudo ./install/install.sh --vip 192.168.1.101 --nodes "192.168.1.10"

# 三副本 HA（生产推荐）
sudo ./install/install.sh --vip 192.168.1.101 --nodes "192.168.1.10,192.168.1.11,192.168.1.12" --replicas 3
```

安装脚本会自动完成：

1. 检查 K3s / kubectl 可用
2. （可选）安装 keepalived 并生成 CloudCore VIP 配置
3. 加载所有 CloudCore 相关镜像（CloudCore、iptables-manager、Controller Manager 等）
4. 运行 `keadm init` 生成 CloudCore 证书（使用 VIP 作为 advertiseAddress）
5. 删除旧的单副本 CloudCore（如有）
6. 为指定节点打标签 `cloudcore=ha-node`
7. 按顺序 `kubectl apply` 所有 manifests：
   - `01-ha-prepare.yaml`（RBAC/CRDs/Namespace）
   - `02-ha-configmap.yaml`（动态替换 VIP 占位符）
   - `03-ha-deployment.yaml`（多副本 Deployment）
   - `08-service.yaml`（NodePort Service）
8. 部署 KubeEdge Controller Manager
9. 安装 Istio CRDs（EdgeMesh 依赖）
10. 配置 CloudStream iptables NAT 规则
11. （可选）安装 EdgeMesh
12. 保存 Edge Token 到 `/etc/kubeedge/token.txt`

### 5.3 验证 CloudCore

```bash
# 查看 CloudCore Pod 状态（期望 3/3 Running）
kubectl get pods -n kubeedge -l k8s-app=kubeedge,kubeedge=cloudcore

# 查看 CloudCore 日志
kubectl logs -n kubeedge -l k8s-app=kubeedge,kubeedge=cloudcore --tail=50

# 查看 Service
kubectl get svc -n kubeedge

# 获取 Edge Token
cat /etc/kubeedge/token.txt
```

---

## 6. 第四阶段：配置 CloudCore VIP

> 为 CloudCore 也配置独立 VIP，使边缘节点连接地址在 CloudCore Pod 迁移时保持不变。

### 6.1 安装 keepalived（如未安装）

```bash
cd /opt/cloudcore
sudo dpkg -i keepalived-deb/*.deb 2>/dev/null || sudo apt-get install -f -y
```

### 6.2 配置 VIP（主/备节点）

使用安装包内的模板：

```bash
# 主节点（controller-1）
cp ./keepalived/keepalived-master.conf.tpl /etc/keepalived/keepalived-cloudcore.conf
vi /etc/keepalived/keepalived-cloudcore.conf
# 替换：
# __INTERFACE__  → 实际网卡名
# __VIP__        → 192.168.1.101
# __VIP_PREFIX__ → 24
# __AUTH_PASS__  → 密码（与备节点一致）

cp ./keepalived/check_cloudcore.sh /etc/keepalived/
chmod +x /etc/keepalived/check_cloudcore.sh

# 重载 keepalived（如果已经运行，merge 配置或重启）
sudo systemctl reload keepalived || sudo systemctl restart keepalived
```

> **注意**：若控制节点上已有 K3s API VIP 的 keepalived 运行，可在同一 keepalived 进程中添加第二个 `vrrp_instance` 块，使用不同的 `virtual_router_id`。

### 6.3 验证 CloudCore VIP

```bash
# 检查 VIP 是否绑定
ip addr show | grep 192.168.1.101

# 通过 VIP 测试 CloudCore 健康接口
curl -sk https://192.168.1.101:10002/readyz
# 期望返回: ok
```

---

## 7. 第五阶段：安装 EdgeCore

### 7.1 解压安装包（在边缘节点上）

```bash
mkdir -p /opt/edgecore && cd /opt/edgecore
tar -xzf /path/to/edgecore-v*.tar.gz
```

### 7.2 获取 Edge Token

```bash
# 在控制节点上获取 token
cat /etc/kubeedge/token.txt
```

### 7.3 执行安装

```bash
# 格式：sudo ./install/install.sh <CLOUDCORE_VIP> <EDGE_TOKEN> [EDGE_NODE_NAME]
sudo ./install/install.sh 192.168.1.101 <TOKEN> edge-node-01
```

### 7.4 验证边缘节点

```bash
# 在控制节点上检查
kubectl get nodes
# 期望看到 edge-node-01 出现，STATUS 为 Ready

# 在边缘节点上检查 EdgeCore 状态
sudo systemctl status edgecore
journalctl -u edgecore -f --lines=50
```

---

## 8. 验证整体链路

### 8.1 验证节点状态

```bash
kubectl get nodes -o wide
```

期望输出（所有节点 Ready）：

```
NAME           STATUS   ROLES                       VERSION
controller-1   Ready    control-plane,etcd,master   v1.34.2+k3s1
controller-2   Ready    control-plane,etcd,master   v1.34.2+k3s1
controller-3   Ready    control-plane,etcd,master   v1.34.2+k3s1
worker-1       Ready    <none>                      v1.34.2+k3s1
edge-node-01   Ready    agent,edge                  v1.34.2+k3s1
```

### 8.2 验证 CloudCore HA

```bash
# 查看所有 CloudCore Pod
kubectl get pods -n kubeedge -l kubeedge=cloudcore -o wide

# 模拟故障：删除一个 Pod，观察自动恢复
kubectl delete pod -n kubeedge <cloudcore-pod-name>
kubectl get pods -n kubeedge -w
```

### 8.3 验证 kubectl logs/exec

```bash
# 在边缘节点部署测试 Pod
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: edge-test
  namespace: default
spec:
  nodeSelector:
    kubernetes.io/hostname: edge-node-01
  hostNetwork: true
  containers:
  - name: busybox
    image: docker.io/library/busybox:latest
    command: ["sleep", "3600"]
EOF

# 等待 Pod 运行
kubectl wait --for=condition=Ready pod/edge-test --timeout=60s

# 测试 logs
kubectl logs edge-test

# 测试 exec
kubectl exec -it edge-test -- echo "hello from edge"
```

### 8.4 验证 Metrics Server

```bash
# 查看节点资源使用情况（包含边缘节点）
kubectl top nodes

# 查看 Pod 资源使用情况
kubectl top pods -A
```

### 8.5 验证 HA 切换（K3s API VIP 故障转移）

```bash
# 关闭 controller-1 上的 keepalived（模拟故障）
sudo systemctl stop keepalived

# 在其他节点检查 VIP 是否转移
ip addr show | grep 192.168.1.100

# 通过 VIP 继续访问 K3s
kubectl --server=https://192.168.1.100:6443 \
  --kubeconfig=/etc/rancher/k3s/k3s.yaml get nodes

# 恢复
sudo systemctl start keepalived
```

---

## 9. 运维操作

### 9.1 扩容 K3s 控制节点

```bash
# 准备新控制节点，解压 k3s-cluster 包后执行：
sudo ./install/install.sh --server <K3S_VIP>:6443 <TOKEN> <NEW_NODE_IP> controller-4
```

> 注意：控制节点数量应保持奇数（3、5...），保证 etcd 选主仲裁。

### 9.2 下线 K3s 控制节点

```bash
# 1. 在 master 节点先 drain
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data

# 2. 从集群删除节点记录
kubectl delete node <node-name>

# 3. 在目标节点执行清理
sudo ./k3s-cluster/install/cleanup.sh
```

### 9.3 更新 CloudCore 版本

```bash
# 1. 清理旧版本（不影响 K3s）
sudo ./cloudcore/install/cleanup.sh

# 2. 下载新版本 cloudcore-ha 离线包并重新安装
sudo ./install/install.sh <VIP> <NODE_IPS>
```

### 9.4 刷新 CloudStream 证书

```bash
cd /opt/cloudcore/script
sudo ./refresh_stream_cert.sh
```

### 9.5 EdgeCore 下线

```bash
# 在控制节点
kubectl drain <edge-node-name> --ignore-daemonsets --delete-emptydir-data
kubectl delete node <edge-node-name>

# 在边缘节点
sudo ./edgecore/install/cleanup.sh
```

### 9.6 查看系统状态

```bash
# K3s 服务状态
sudo systemctl status k3s

# etcd 集群健康（在控制节点）
sudo k3s etcd-snapshot ls

# CloudCore 日志
kubectl logs -n kubeedge -l kubeedge=cloudcore -f --max-log-requests 10

# EdgeCore 日志（在边缘节点）
journalctl -u edgecore -f
```

---

## 10. 常见问题

### Q: etcd 集群无法启动或 leader 选举失败

**原因**：控制节点数量为偶数，或节点间网络不通。

**解决**：
```bash
# 检查 etcd 端口连通性（2379/2380）
nc -zv <controller-2-ip> 2379
nc -zv <controller-2-ip> 2380

# 查看 etcd 日志
journalctl -u k3s --since "10 minutes ago" | grep etcd
```

### Q: EdgeCore 无法连接 CloudCore（超时 / 证书错误）

**检查步骤**：
```bash
# 1. 确认 VIP 可达
ping 192.168.1.101
nc -zv 192.168.1.101 10000

# 2. 确认 Token 正确
cat /etc/kubeedge/token.txt

# 3. 查看 EdgeCore 详细日志
journalctl -u edgecore -n 100 | grep -E "error|failed|cert"

# 4. 检查 CloudCore 证书的 advertiseAddress
kubectl get cm -n kubeedge cloudcore-config -o yaml | grep advertiseAddress
```

### Q: kubectl logs/exec 无法使用

**原因**：CloudStream 的 iptables NAT 规则未配置，或 EdgeStream 未启用。

**解决**：
```bash
# 在控制节点检查 iptables 规则（期望有 DNAT 到 10003）
sudo iptables -t nat -L PREROUTING -n -v | grep 10003

# 如果没有，手动添加
sudo iptables -t nat -A PREROUTING -p tcp --dport 10003 \
  -j DNAT --to-destination 127.0.0.1:10003
sudo iptables-save > /etc/iptables/rules.v4

# 在边缘节点检查 EdgeStream 是否启用
grep -A3 "edgeStream" /etc/kubeedge/config/edgecore.yaml
```

### Q: VIP 不切换（keepalived 故障转移失败）

**检查步骤**：
```bash
# 查看 keepalived 状态
sudo systemctl status keepalived
journalctl -u keepalived -n 50

# 检查 VRRP 通告（需要 224.0.0.18 组播可达）
sudo tcpdump -i <interface> vrrp

# 手动测试健康检查脚本
/etc/keepalived/check_apiserver.sh && echo "healthy" || echo "unhealthy"
```

### Q: metrics-server 无法获取边缘节点数据

**原因**：metrics-server 默认不支持 kubelet 的 insecure 端口，需要添加 `--kubelet-insecure-tls`。

**解决**：
```bash
kubectl edit deployment metrics-server -n kube-system
# 在 args 中添加：
# - --kubelet-insecure-tls
# - --kubelet-preferred-address-types=InternalIP,Hostname,ExternalIP
```

### Q: CloudCore Pod 在某节点不调度

**原因**：节点未打上 `cloudcore=ha-node` 标签，或 podAntiAffinity 阻止调度。

**解决**：
```bash
# 手动打标签
kubectl label node <node-name> cloudcore=ha-node

# 查看调度事件
kubectl describe pod -n kubeedge <cloudcore-pod-name> | grep -A20 Events
```

---

## 附录：一键部署示例脚本

以下脚本示例适合在测试环境中快速验证整个流程：

```bash
#!/usr/bin/env bash
# 示例：3控1工1边的最小化 HA 环境

set -euo pipefail

K3S_VIP="192.168.1.100"
CLOUDCORE_VIP="192.168.1.101"
CONTROLLER_1="192.168.1.10"
CONTROLLER_2="192.168.1.11"
CONTROLLER_3="192.168.1.12"
EDGE_1="192.168.2.10"

echo "=== 步骤1: 初始化 K3s controller-1 ==="
ssh root@${CONTROLLER_1} "cd /opt/k3s-cluster && sudo ./install/install.sh --init ${CONTROLLER_1} controller-1"

echo "=== 获取 Token ==="
TOKEN=$(ssh root@${CONTROLLER_1} "cat /var/lib/rancher/k3s/server/node-token")
echo "Token: ${TOKEN}"

echo "=== 步骤2: 加入 controller-2 ==="
ssh root@${CONTROLLER_2} "cd /opt/k3s-cluster && sudo ./install/install.sh --server ${CONTROLLER_1}:6443 '${TOKEN}' ${CONTROLLER_2} controller-2"

echo "=== 步骤3: 加入 controller-3 ==="
ssh root@${CONTROLLER_3} "cd /opt/k3s-cluster && sudo ./install/install.sh --server ${CONTROLLER_1}:6443 '${TOKEN}' ${CONTROLLER_3} controller-3"

echo "=== 步骤4: 安装 CloudCore HA ==="
ssh root@${CONTROLLER_1} "cd /opt/cloudcore && sudo ./install/install.sh --vip ${CLOUDCORE_VIP} --nodes '${CONTROLLER_1},${CONTROLLER_2},${CONTROLLER_3}' --replicas 3"

echo "=== 获取 Edge Token ==="
EDGE_TOKEN=$(ssh root@${CONTROLLER_1} "cat /etc/kubeedge/token.txt")

echo "=== 步骤5: 安装 EdgeCore ==="
ssh root@${EDGE_1} "cd /opt/edgecore && sudo ./install/install.sh ${CLOUDCORE_VIP} '${EDGE_TOKEN}' edge-node-01"

echo "=== 部署完成！验证中... ==="
ssh root@${CONTROLLER_1} "kubectl get nodes"
```
