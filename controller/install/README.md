# K3s 控制节点离线安装包（HA 高可用扩容）

## 概述

此安装包用于在已有 K3s 单控制节点集群的基础上，扩容为**多控制节点 HA 高可用集群**。

K3s HA 高可用原理：
- 第一个控制节点以 `--cluster-init` 启动，使用**内置 etcd** 作为数据存储
- 第二、三个控制节点以 `--server` 方式加入，共同组成 etcd 集群
- etcd 集群保证控制平面状态高可用（3 节点可容忍 1 节点故障）

```
                  ┌─────────────────────────────┐
                  │         K3s HA 集群          │
                  │                             │
    ┌─────────────┴──┐  ┌──┴──────────┐  ┌──┴────────────┐
    │  controller-01 │  │ controller-02│  │ controller-03 │
    │  (cloud 包)    │  │ (此安装包)   │  │  (此安装包)   │
    │  --cluster-init│  │  --server   │  │  --server     │
    │  etcd leader   │  │  etcd member│  │  etcd member  │
    │  + CloudCore   │  │             │  │               │
    └────────────────┘  └─────────────┘  └───────────────┘
```

---

## 前提条件

### 1. 第一个控制节点已启用内置 etcd

第一个控制节点（cloud 安装包）的 `/etc/systemd/system/k3s.service` 中必须包含 `--cluster-init` 参数。

> **重要：** 默认的 cloud 安装包已在 ExecStart 中加入了 `--cluster-init`。若你的第一个控制节点是在更早版本的安装包部署的（不含此参数），请参考 [从 SQLite 迁移到 HA](#从-sqlite-迁移到-ha) 章节。

验证方式（在第一个控制节点执行）：
```bash
grep cluster-init /etc/systemd/system/k3s.service
# 应输出: --cluster-init \
```

### 2. 网络端口互通

本节点与第一个控制节点之间，以下端口必须双向互通：

| 端口 | 协议 | 用途 |
|------|------|------|
| 6443 | TCP | K8s API Server |
| 2379 | TCP | etcd client |
| 2380 | TCP | etcd peer 通信 |

### 3. 获取加入 token

在第一个控制节点执行：
```bash
cat /var/lib/rancher/k3s/server/token
```

> 注意：此处使用 `server/token`，而非 `server/node-token`（两者均可用，前者更简洁）

---

## 安装

### 解压安装包

```bash
tar -xzf k3s-controller-<version>-<arch>-<tag>.tar.gz
cd <解压目录>
```

### 执行安装

```bash
sudo ./install.sh <first-server-ip:port> <node-token> <this-node-ip> [node-name]
```

**参数说明：**

| 参数 | 必填 | 说明 |
|------|------|------|
| `first-server-ip:port` | 是 | 第一个控制节点地址（端口默认 6443） |
| `node-token` | 是 | 来自 `/var/lib/rancher/k3s/server/token` |
| `this-node-ip` | 是 | 本节点对外 IP（用于 advertise-address 和 tls-san） |
| `node-name` | 否 | 节点名称，默认 `k3s-controller-<hostname>`，需符合 RFC 1123 |

**示例：**

```bash
# 加入第二个控制节点
sudo ./install.sh 192.168.1.10:6443 K10xxx...::server:xxx 192.168.1.11 cloudedge-controller-02

# 加入第三个控制节点
sudo ./install.sh 192.168.1.10:6443 K10xxx...::server:xxx 192.168.1.12 cloudedge-controller-03
```

---

## 验证安装

安装完成后，在任意控制节点执行：

```bash
# 查看所有节点，控制节点 ROLES 应为 control-plane
kubectl get nodes

# 预期输出（3 控制节点集群）：
# NAME                     STATUS   ROLES           AGE   VERSION
# cloudedge-controller-01  Ready    control-plane   ...   v1.34.2+k3s1
# cloudedge-controller-02  Ready    control-plane   ...   v1.34.2+k3s1
# cloudedge-controller-03  Ready    control-plane   ...   v1.34.2+k3s1
```

验证 etcd 健康状态：
```bash
# 在任意控制节点执行
k3s etcd-snapshot ls

# 或通过 etcdctl（k3s 内置）
ETCDCTL_ENDPOINTS='https://127.0.0.1:2379' \
  ETCDCTL_CACERT='/var/lib/rancher/k3s/server/tls/etcd/server-ca.crt' \
  ETCDCTL_CERT='/var/lib/rancher/k3s/server/tls/etcd/server-client.crt' \
  ETCDCTL_KEY='/var/lib/rancher/k3s/server/tls/etcd/server-client.key' \
  k3s etcd-snapshot ls
```

---

## 卸载 / 节点退出集群

> ⚠️ **必须按顺序操作，避免破坏 etcd quorum**

**步骤 1：在其他控制节点驱逐 Pod**
```bash
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data
```

**步骤 2：在其他控制节点删除节点**
```bash
kubectl delete node <node-name>
```

**步骤 3：在本节点执行清理**
```bash
sudo ./cleanup.sh
```

---

## 故障排查

### 节点无法加入集群

```bash
# 查看 k3s server 日志
journalctl -u k3s -f

# 常见错误排查：
# 1. "connection refused" → 确认第一个控制节点 6443 端口开放
# 2. "failed to find token" → 确认 token 正确
# 3. "etcd cluster is unavailable" → 确认第一个控制节点使用了 --cluster-init
```

### 确认第一个节点是否使用内置 etcd

```bash
# 在第一个控制节点执行
grep cluster-init /etc/systemd/system/k3s.service && echo "✓ 已启用 etcd HA" || echo "✗ 未启用，需要重装"
```

### 节点状态为 NotReady

```bash
# 查看节点事件
kubectl describe node <node-name>

# 查看 kubelet 日志
journalctl -u k3s --since "5 minutes ago"
```

---

## 从 SQLite 迁移到 HA

若第一个控制节点最初以 SQLite 模式（无 `--cluster-init`）安装，**无法直接原地升级为 HA**，需要：

1. 备份现有工作负载的 YAML（`kubectl get all -A -o yaml > backup.yaml`）
2. 使用 cloud 安装包**重新安装**第一个控制节点（新版包含 `--cluster-init`）
3. 重新部署工作负载
4. 使用此安装包加入第二、三个控制节点

---

## HA 集群节点数量建议

| 控制节点数 | etcd quorum | 可容忍故障节点数 | 建议场景 |
|-----------|------------|----------------|---------|
| 1 个 | 1/1 | 0 | 开发/测试 |
| 3 个 | 2/3 | 1 | **生产推荐** |
| 5 个 | 3/5 | 2 | 高可靠性要求 |

> 始终保持奇数个控制节点，避免 etcd split-brain。

---

## 相关文档

- [K3s HA with Embedded DB](https://docs.k3s.io/datastore/ha-embedded)
- [cloud 安装包 README](../../cloud/install/README.md)
- [worker 安装包 README](../../worker/install/README.md)
