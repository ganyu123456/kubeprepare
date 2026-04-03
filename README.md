# KubeEdge 工业云边协同平台 — 离线安装项目

> **v2 架构**：已重构为模块化三段式安装，支持 K3s 集群 HA + CloudCore HA。

## 核心特性

| 特性 | 说明 |
|------|------|
| **完全离线** | 所有二进制、镜像、Helm Chart、系统依赖 deb 均离线打包 |
| **K3s 高可用** | 多控制节点 + embedded etcd + keepalived VIP，K3s API Server HA |
| **CloudCore 高可用** | 多副本 Deployment + keepalived VIP，CloudCore HA |
| **三段式解耦安装** | K3s 集群 / CloudCore / EdgeCore 独立安装，互不依赖 |
| **多架构支持** | amd64 / arm64 均有对应离线包 |
| **一键安装/清理** | 每个模块均提供 `install.sh` 和 `cleanup.sh` |

## 版本信息

| 组件 | 版本 |
|------|------|
| KubeEdge | v1.22.0 |
| K3s | v1.34.2+k3s1 |
| EdgeMesh | v1.17.0 |
| Metrics Server | v0.8.0 |
| Helm | v3.19.2 |

---

## 安装架构

```
┌─────────────────────────────────────────────────────────────────┐
│                      云端（Cloud Side）                          │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │              K3s 集群 (k3s-cluster 离线包)                │   │
│  │                                                          │   │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐   │   │
│  │  │  controller-1│  │  controller-2│  │  controller-3│   │   │
│  │  │  (--init)    │  │  (--server)  │  │  (--server)  │   │   │
│  │  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘   │   │
│  │         └─────────────────┴──────────────────┘           │   │
│  │                      embedded etcd                       │   │
│  │                   K3s API VIP (keepalived)               │   │
│  └──────────────────────────────────────────────────────────┘   │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │             CloudCore HA (cloudcore 离线包)               │   │
│  │                                                          │   │
│  │   CloudCore Pod x3 (hostNetwork, podAntiAffinity)        │   │
│  │   CloudCore VIP (keepalived) ← EdgeCore 统一接入点        │   │
│  │   + Controller Manager + Admission + EdgeMesh Server     │   │
│  └──────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
                              |
                   WebSocket 长连接（10000/10001）
                              |
┌─────────────────────────────────────────────────────────────────┐
│                     边缘端（Edge Side）                          │
│                                                                  │
│     EdgeCore (edgecore 离线包)                                   │
│     containerd + runc + CNI + EdgeMesh Agent                     │
└─────────────────────────────────────────────────────────────────┘
```

---

## 快速开始

### 第一步：安装 K3s 集群

下载 `k3s-cluster-<version>-<arch>-<tag>.tar.gz`，解压后：

```bash
# 1. 首控制节点（初始化集群）
sudo ./install/install.sh --init 192.168.1.10 controller-1

# 2. 扩容第二/三控制节点（HA）
sudo ./install/install.sh --server 192.168.1.10:6443 <TOKEN> 192.168.1.11 controller-2
sudo ./install/install.sh --server 192.168.1.10:6443 <TOKEN> 192.168.1.12 controller-3

# 3. 加入 Worker 节点
sudo ./install/install.sh --agent 192.168.1.10:6443 <TOKEN> worker-01

# 4. （可选）配置 K3s API Server VIP
#    编辑 keepalived/ 下的模板文件后安装 keepalived
```

> Token 在 `--init` 完成后自动打印到终端。

### 第二步：安装 CloudCore HA

下载 `cloudcore-ha-v<version>-<arch>-<tag>.tar.gz`，解压后：

```bash
# --vip:   CloudCore 对外统一地址（需提前规划，keepalived 管理）
# --nodes: 安装 CloudCore 的控制节点 IP（逗号分隔，1～3 个）

# 单节点 CloudCore
sudo ./install/install.sh --vip 192.168.1.100 --nodes "192.168.1.10"

# 三节点 CloudCore HA
sudo ./install/install.sh --vip 192.168.1.100 --nodes "192.168.1.10,192.168.1.11,192.168.1.12" --replicas 3
```

安装完成后 Edge Token 保存在 `/etc/kubeedge/token.txt`。

### 第三步：安装 EdgeCore（边缘节点）

下载 `edgecore-v<version>-<arch>-<tag>.tar.gz`，解压后：

```bash
# CLOUDCORE_VIP：第二步规划的 CloudCore VIP
# EDGE_TOKEN：第二步输出的 Edge Token
sudo ./install/install.sh 192.168.1.100 <EDGE_TOKEN> edge-node-01
```

---

## 项目结构

```
01-package-code-ganyu/
├── .github/
│   └── workflows/
│       ├── build-release-k3s-cluster.yml   # ✅ K3s 集群离线包构建（新）
│       ├── build-release-cloudcore-ha.yml  # ✅ CloudCore HA 离线包构建（新）
│       ├── build-release-edgecore.yml      # ✅ EdgeCore 离线包构建（新）
│       ├── build-release-postgresql.yml    # PostgreSQL 离线包
│       ├── build-release-redis.yml         # Redis 离线包
│       ├── build-release-nfs.yml           # NFS 离线包
│       ├── build-release-cloud.yml         # ⚠️ 已废弃
│       ├── build-release-controller.yml    # ⚠️ 已废弃
│       ├── build-release-worker.yml        # ⚠️ 已废弃
│       └── build-release-edge.yml          # ⚠️ 已废弃
│
├── k3s-cluster/                            # ✅ K3s 集群安装（三合一）
│   ├── install/
│   │   ├── install.sh                      # --init / --server / --agent 三模式
│   │   ├── cleanup.sh                      # 集群节点清理
│   │   └── README.md                       # 安装说明
│   └── keepalived/                         # K3s API Server VIP 模板
│       ├── keepalived-master.conf.tpl
│       ├── keepalived-backup.conf.tpl
│       ├── check_apiserver.sh
│       └── README.md
│
├── cloudcore/                              # ✅ CloudCore HA 安装
│   ├── install/
│   │   ├── install.sh                      # CloudCore HA 一键安装
│   │   └── cleanup.sh                      # 仅清理 CloudCore（不影响 K3s）
│   ├── manifests/                          # K8s 清单文件
│   │   ├── 01-ha-prepare.yaml              # RBAC / CRDs / Namespace
│   │   ├── 02-ha-configmap.yaml            # CloudCore 配置（已修复 dynamicController+cloudStream）
│   │   ├── 03-ha-deployment.yaml           # CloudCore Deployment（多副本）
│   │   └── 08-service.yaml                 # CloudCore Service（NodePort）
│   ├── script/
│   │   ├── certgen.sh                      # 证书生成脚本
│   │   └── refresh_stream_cert.sh          # 刷新 CloudStream 证书
│   └── keepalived/                         # CloudCore VIP 模板
│       ├── keepalived-master.conf.tpl
│       ├── keepalived-backup.conf.tpl
│       └── check_cloudcore.sh
│
├── edgecore/                               # ✅ EdgeCore 边缘端安装
│   └── install/
│       ├── install.sh                      # EdgeCore 一键安装
│       ├── cleanup.sh                      # EdgeCore 清理
│       └── README.md                       # 安装说明
│
├── postgresql/                             # PostgreSQL 离线包
├── redis/                                  # Redis 离线包
├── debug/                                  # 调试工具
├── docs/                                   # 文档
│   ├── HA_DEPLOYMENT_GUIDE.md              # ✅ 完整 HA 部署手册（新）
│   ├── EDGEMESH_DEPLOYMENT.md              # EdgeMesh 部署指南
│   ├── EDGECORE_CONFIG_BEST_PRACTICES.md   # EdgeCore 配置最佳实践
│   └── ...
│
├── cloud/          # ⚠️ 已废弃，参见 cloud/DEPRECATED.md
├── controller/     # ⚠️ 已废弃，参见 controller/DEPRECATED.md
├── worker/         # ⚠️ 已废弃，参见 worker/DEPRECATED.md
└── cloudcore-ha/   # ⚠️ 已废弃，参见 cloudcore-ha/DEPRECATED.md
```

---

## GitHub Actions 构建工作流

| 工作流 | 触发路径 | 产物 |
|--------|---------|------|
| `build-release-k3s-cluster.yml` | `k3s-cluster/**` | `k3s-cluster-<k3s_ver>-<arch>-<tag>.tar.gz` |
| `build-release-cloudcore-ha.yml` | `cloudcore/**` | `cloudcore-ha-v<kubeedge_ver>-<arch>-<tag>.tar.gz` |
| `build-release-edgecore.yml` | `edgecore/**` | `edgecore-v<kubeedge_ver>-<arch>-<tag>.tar.gz` |

构建由 `v*` tag push 自动触发，也可在 GitHub Actions 页面手动触发 (`workflow_dispatch`)。

---

## 离线包内容说明

### k3s-cluster 离线包

```
k3s-cluster-<version>.tar.gz
├── k3s-{arch}                     # K3s 二进制
├── helm                           # Helm 二进制
├── images/
│   └── k3s-airgap-images-{arch}.tar.zst  # K3s 官方 airgap 镜像包
├── helm-charts/
│   └── edgemesh.tgz               # EdgeMesh Helm Chart
├── nfs/                           # nfs-common 离线 deb
├── keepalived/                    # keepalived 离线 deb
├── install/
│   ├── install.sh
│   ├── cleanup.sh
│   └── README.md
└── keepalived/                    # VIP 配置模板
    ├── keepalived-master.conf.tpl
    ├── keepalived-backup.conf.tpl
    └── check_apiserver.sh
```

### cloudcore-ha 离线包

```
cloudcore-ha-v<version>.tar.gz
├── keadm / helm                   # 工具二进制
├── images/
│   ├── cloudcore-v*.tar
│   ├── iptables-manager-v*.tar
│   ├── controllermanager-v*.tar
│   ├── edgemesh-server/agent-*.tar
│   └── metrics-server-*.tar
├── helm-charts/edgemesh.tgz
├── istio-crds/                    # Istio CRDs（EdgeMesh 依赖）
├── keepalived-deb/                # keepalived 离线 deb
├── install/
│   ├── install.sh
│   └── cleanup.sh
├── manifests/                     # K8s 清单
└── keepalived/                    # CloudCore VIP 模板
```

### edgecore 离线包

```
edgecore-v<version>.tar.gz
├── edgecore / keadm / runc / helm
├── bin/                           # containerd-static binaries
├── cni-bin/                       # CNI 插件
├── images/
│   ├── kubeedge-installation-package-v*.tar
│   ├── kubeedge-pause-3.6.tar
│   ├── edgemesh-agent-*.tar
│   └── eclipse-mosquitto-1.6.15.tar
├── nfs/                           # nfs-common 离线 deb
├── helm-charts/edgemesh.tgz
└── install/
    ├── install.sh
    └── cleanup.sh
```

---

## 详细文档

- [完整 HA 部署手册](./docs/HA_DEPLOYMENT_GUIDE.md) — 端到端 HA 部署流程（推荐阅读）
- [K3s 集群安装说明](./k3s-cluster/install/README.md)
- [EdgeMesh 部署指南](./docs/EDGEMESH_DEPLOYMENT.md)
- [EdgeCore 配置最佳实践](./docs/EDGECORE_CONFIG_BEST_PRACTICES.md)
- [IoT MQTT 集成指南](./docs/IOT_MQTT_INTEGRATION.md)

## 故障排除

```bash
# K3s 节点清理
sudo ./k3s-cluster/install/cleanup.sh

# 仅清理 CloudCore（保留 K3s）
sudo ./cloudcore/install/cleanup.sh

# EdgeCore 清理
sudo ./edgecore/install/cleanup.sh
```

## 旧架构迁移

如果你正在使用旧的 `cloud/`、`controller/`、`worker/` 目录，请参考：

- [cloud/ 迁移说明](./cloud/DEPRECATED.md)
- [controller/ 迁移说明](./controller/DEPRECATED.md)
- [worker/ 迁移说明](./worker/DEPRECATED.md)
- [cloudcore-ha/ 迁移说明](./cloudcore-ha/DEPRECATED.md)
