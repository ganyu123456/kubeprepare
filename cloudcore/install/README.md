# CloudCore HA 离线安装包

在已有 K3s 集群基础上，以 **Kubernetes Deployment（多副本 + PodAntiAffinity）** 方式部署 CloudCore 高可用，并通过 **keepalived VIP** 对边缘节点暴露稳定接入地址。

## 前置条件

1. K3s 集群已部署（使用 `k3s-cluster` 安装包）
2. 本机是 K3s 控制节点（`/etc/rancher/k3s/k3s.yaml` 存在）
3. 已规划 CloudCore VIP（与控制节点同子网的空闲 IP）
4. 各 CloudCore 节点已在 K3s 集群中注册

## 快速开始

```bash
tar -xzf cloudcore-ha-1.22.0-amd64-{TAG}.tar.gz
cd cloudcore-ha-1.22.0-amd64-{TAG}

# 单节点（不需要 HA）
sudo ./install/install.sh --vip 192.168.1.10 --nodes "192.168.1.10"

# 三节点 HA（推荐）
sudo ./install/install.sh \
  --vip 192.168.1.200 \
  --nodes "192.168.1.10,192.168.1.11,192.168.1.12" \
  --replicas 3
```

## 参数说明

| 参数 | 必填 | 说明 |
|------|------|------|
| `--vip` | ✅ | CloudCore VIP，边缘节点使用此 IP 接入 |
| `--nodes` | ✅ | 运行 CloudCore 的 K3s 控制节点 IP 列表（逗号分隔） |
| `--replicas` | ❌ | CloudCore 副本数（默认 1） |
| `--kubeedge-version` | ❌ | KubeEdge 版本（默认 1.22.0） |
| `--skip-keepalived` | ❌ | 跳过 keepalived 安装（已手动配置时使用） |
| `--skip-edgemesh` | ❌ | 跳过 EdgeMesh 安装 |

## HA 架构

```
EdgeCore 接入:
  edge-node → CloudCore VIP:10000

keepalived VIP（CloudCore）:
  192.168.1.200 ─┬─ k3s-server-01 (CloudCore Pod, MASTER)
                 ├─ k3s-server-02 (CloudCore Pod, BACKUP)
                 └─ k3s-server-03 (CloudCore Pod, BACKUP)

CloudCore 以 Deployment 运行:
  - replicas: 3
  - PodAntiAffinity: 强制分散到不同节点
  - nodeSelector: cloudcore=ha-node
  - hostNetwork: true（使用宿主机 IP）
```

## keepalived 配置

安装完成后，在各 CloudCore 节点配置 keepalived：

```bash
# 安装 keepalived（在线或使用离线包）
apt-get install -y keepalived

# 在主节点（运行 VIP 的节点）
cp keepalived/keepalived-master.conf.tpl /etc/keepalived/keepalived.conf
cp keepalived/check_cloudcore.sh /etc/keepalived/check_cloudcore.sh
chmod +x /etc/keepalived/check_cloudcore.sh
# 修改 INTERFACE_NAME、VIP_ADDRESS/PREFIX、AUTH_PASSWORD
vi /etc/keepalived/keepalived.conf

# 在备节点
cp keepalived/keepalived-backup.conf.tpl /etc/keepalived/keepalived.conf
# ... 同上修改

systemctl enable keepalived && systemctl start keepalived
```

## 端口说明

| 端口 | 用途 |
|------|------|
| 10000 | CloudHub WebSocket（边缘节点接入） |
| 10001 | CloudHub QUIC |
| 10002 | CloudHub HTTPS（/readyz 健康检查） |
| 10003 | CloudStream（kubectl logs/exec） |
| 10004 | CloudStream Tunnel |
| 9443 | Router |

## 清理

```bash
sudo ./install/cleanup.sh
```

## 版本信息

- KubeEdge: v1.22.0
- EdgeMesh: v1.17.0
- 支持架构: amd64, arm64
