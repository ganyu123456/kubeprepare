# K3s 集群离线安装包

本安装包支持三种角色，使用**同一个离线包**，通过不同安装命令区分：

| 角色 | 命令 | 说明 |
|------|------|------|
| K3s 首控制节点 | `--init` | 初始化集群，内置 etcd `--cluster-init` |
| K3s 扩容控制节点 | `--server` | 加入已有集群，扩展 HA 控制平面 |
| K3s Worker 节点 | `--agent` | 作为计算节点加入集群 |

## 快速开始

### 1. 首控制节点（建集群）

```bash
tar -xzf k3s-cluster-v1.34.2+k3s1-amd64-{TAG}.tar.gz
cd k3s-cluster-v1.34.2+k3s1-amd64-{TAG}

# 参数: <本节点对外IP> [节点名称]
sudo ./install/install.sh --init 192.168.1.10 k3s-server-01
```

安装完成后会输出 `K3S_TOKEN`，保存用于后续扩容。

### 2. 扩容控制节点（HA 高可用，建议 3 台）

```bash
# 参数: <首节点IP:PORT> <K3S_TOKEN> <本节点IP> [节点名称]
sudo ./install/install.sh --server 192.168.1.10:6443 K10xxx...::server:xxx 192.168.1.11 k3s-server-02
sudo ./install/install.sh --server 192.168.1.10:6443 K10xxx...::server:xxx 192.168.1.12 k3s-server-03
```

> TOKEN 在首节点安装完成后输出，也可执行 `cat /var/lib/rancher/k3s/server/token` 获取。

### 3. Worker 节点

```bash
# 参数: <Server IP:PORT> <K3S_TOKEN> [节点名称]
sudo ./install/install.sh --agent 192.168.1.10:6443 K10xxx...::server:xxx k3s-worker-01
```

> Worker 节点可以连接任意控制节点 IP，建议使用 keepalived VIP（见下方 HA 说明）。

## HA 高可用架构

```
                  ┌─────────────────────┐
                  │  keepalived VIP     │
                  │  192.168.1.100:6443 │  ← K3s API Server VIP
                  └──────┬──────────────┘
                         │
          ┌──────────────┼──────────────┐
          │              │              │
   ┌──────▼──────┐ ┌──────▼──────┐ ┌──────▼──────┐
   │ k3s-server-01│ │ k3s-server-02│ │ k3s-server-03│
   │  etcd MASTER │ │  etcd FOLLOWER│ │  etcd FOLLOWER│
   └─────────────┘ └─────────────┘ └─────────────┘
```

keepalived 配置模板见 `keepalived/` 目录。

## 端口要求

| 端口 | 协议 | 用途 |
|------|------|------|
| 6443 | TCP | K3s API Server |
| 2379 | TCP | etcd client |
| 2380 | TCP | etcd peer |
| 8472 | UDP | Flannel VXLAN |
| 10250 | TCP | kubelet |

## 清理/重装

```bash
sudo ./install/cleanup.sh
# Server 节点请先在其他节点执行 kubectl drain 和 kubectl delete node
```

## 安装后步骤

K3s 集群部署完成后，继续安装 **CloudCore HA**：

```bash
tar -xzf cloudcore-ha-1.22.0-amd64-{TAG}.tar.gz
cd cloudcore-ha-1.22.0-amd64-{TAG}
sudo ./install/install.sh --vip 192.168.1.200 --nodes "192.168.1.10,192.168.1.11,192.168.1.12"
```

## 版本信息

- K3s: v1.34.2+k3s1
- 支持架构: amd64, arm64
