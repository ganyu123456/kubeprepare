# KubeEdge 1.22 离线安装项目

## 简介

这是一个完整的 KubeEdge 1.22 离线安装解决方案，包括：
- **云端（Master）**：K3s + KubeEdge CloudCore + EdgeMesh + Metrics Server（支持 amd64/arm64）
- **K3s Worker 节点**：纯 k3s agent，扩展云端 Kubernetes 集群算力（支持 amd64/arm64）
- **边缘端**：containerd + runc + KubeEdge EdgeCore（支持 amd64/arm64）
- **日志与监控**：kubectl logs/exec + kubectl top（完全离线支持）

> kubectl logs/exec 无法执行到边缘问题待解决

支持在**完全离线环境**下快速部署 KubeEdge 边缘计算基础设施。

### 完整离线支持

✅ **云端镜像完整打包**
- 包含所有 K3s 系统镜像 (8个)
- 包含所有 KubeEdge 组件镜像 (4个)
  - cloudcore:v1.22.0
  - iptables-manager:v1.22.0
  - controller-manager:v1.22.0
  - admission:v1.22.0
- 包含 EdgeMesh Agent 镜像 (v1.17.0)
- 包含 EdgeMesh 离线 Helm Chart
- 包含 Istio CRDs (3个：destinationrule, gateway, virtualservice)
- 【新增】包含 Metrics Server 镜像 (v0.4.1)
- 自动启用 CloudCore dynamicController（支持 metaServer）
- 【新增】自动启用 CloudStream（支持 kubectl logs/exec）
- 安装前自动预导入，无需联网

✅ **边缘日志采集与资源监控**
- **kubectl logs** - 从云端查看边缘 Pod 日志
- **kubectl exec** - 在边缘 Pod 中执行命令
- **kubectl top node** - 查看边缘节点资源使用情况
- **kubectl top pod** - 查看边缘 Pod 资源使用情况
- 完全自动化配置，无需手动操作
- CloudStream + EdgeStream 自动启用
- Metrics Server 自动部署和配置
- iptables 规则自动配置

## 快速开始

### 1. 获取离线安装包

项目使用 GitHub Actions 自动构建并发布离线安装包到 [Releases](../../releases) 页面。

**云端包命名格式**:
- `kubeedge-cloud-1.22.0-k3s-v1.34.2+k3s1-amd64.tar.gz`
- `kubeedge-cloud-1.22.0-k3s-v1.34.2+k3s1-arm64.tar.gz`

**K3s Worker 包命名格式**:
- `k3s-worker-v1.34.2+k3s1-amd64.tar.gz`
- `k3s-worker-v1.34.2+k3s1-arm64.tar.gz`

**边缘端包命名格式**:
- `kubeedge-edge-1.22.0-amd64.tar.gz`
- `kubeedge-edge-1.22.0-arm64.tar.gz`

下载对应架构的安装包后即可使用。

### 2. 云端安装（一键部署）

```bash
# 解压离线包
tar -xzf kubeedge-cloud-1.22.0-k3s-v1.34.2+k3s1-amd64.tar.gz
cd kubeedge-cloud-1.22.0-k3s-v1.34.2+k3s1-amd64

# 安装（需要 sudo）
# 参数1: 对外 IP 地址（必需）
# 参数2: 节点名称（可选，默认 k3s-master）
sudo ./install/install.sh 192.168.1.100
# 或指定节点名称
sudo ./install/install.sh 192.168.1.100 my-master
```

安装完成后将自动输出边缘节点的接入 token，保存在 `/etc/kubeedge/token.txt`。

### 3. K3s Worker 节点安装（一键部署）

```bash
# 解压离线包
tar -xzf k3s-worker-v1.34.2+k3s1-amd64.tar.gz
cd k3s-worker-v1.34.2+k3s1-amd64

# 安装（需要 sudo）
# 参数1: master 地址（格式：IP:PORT，端口通常为 6443）
# 参数2: k3s token（master 节点执行 cat /var/lib/rancher/k3s/server/node-token 获取）
# 参数3: worker 节点名称（可选，默认 k3s-worker-<hostname>）
sudo ./install.sh 192.168.122.231:6443 K10xxx...::xxx:sh worker-01
```

在 master 节点验证 worker 已加入：
```bash
kubectl get nodes
```

> **注意**：K3s Worker 节点是纯 Kubernetes 计算节点，用于扩展云端算力。
> 若需部署 KubeEdge **边缘节点**（EdgeCore），请使用边缘端安装包。

### 4. 边缘端安装（一键部署）

```bash
# 解压离线包
tar -xzf kubeedge-edge-1.22.0-amd64.tar.gz
cd kubeedge-edge-1.22.0-amd64

# 安装（需要 sudo）
# 参数1: 云端地址（格式：IP:PORT，端口通常为 10000）
# 参数2: token（云端安装时生成）
# 参数3: 边缘节点名称（必需）
sudo ./install/install.sh 192.168.1.100:10000 <token> edge-node-1
```

在云端验证边缘节点：
```bash
kubectl get nodes
```

## 项目结构

```
kubeprepare/
├── .github/
│   └── workflows/                   # GitHub Actions 自动化构建流程
│       ├── build-release-cloud.yml  # 云端离线包自动构建和发布
│       ├── build-release-worker.yml # K3s Worker 节点离线包自动构建和发布
│       └── build-release-edge.yml   # 边缘端离线包自动构建和发布
├── cloud/                           # 云端相关（K3s Master + CloudCore）
│   ├── install/
│   │   ├── install.sh               # 云端安装脚本
│   │   └── README.md                # 云端详细说明
│   ├── release/                     # 离线包临时构建目录（由 Actions 生成）
│   └── systemd/                     # 系统服务配置文件
├── worker/                          # K3s Worker 节点相关
│   └── install/
│       ├── install.sh               # Worker 节点安装脚本
│       └── cleanup.sh               # Worker 节点清理脚本
├── edge/                            # 边缘端相关（KubeEdge EdgeCore）
│   ├── install/
│   │   ├── install.sh               # 边缘端安装脚本
│   │   └── README.md                # 边缘端详细说明
│   ├── release/                     # 离线包临时构建目录（由 Actions 生成）
│   └── systemd/                     # 系统服务配置文件
│       └── mosquitto.service        # MQTT Broker 服务配置
├── docs/                           # 项目文档目录
│   ├── EDGEMESH_DEPLOYMENT.md      # EdgeMesh 完整部署方案（含官方最佳实践）
│   ├── EDGECORE_CONFIG_BEST_PRACTICES.md # EdgeCore 配置最佳实践
│   ├── K3S_NETWORK_CONFIG.md       # K3s 网络配置详解
│   ├── IOT_MQTT_INTEGRATION.md     # IoT MQTT 集成指南
│   ├── QUICK_DEPLOY_LOGS_METRICS.md # 【新增】日志与监控快速部署指南
│   ├── LOG_METRICS_OFFLINE_DEPLOYMENT.md # 【新增】日志与监控完整方案文档
│   ├── PROJECT_STRUCTURE.md        # 项目结构说明
│   ├── CI_CD_ARCHITECTURE.md       # CI/CD 架构设计
│   ├── BUILD_FLOW_SUMMARY.md       # 构建流程总结
│   ├── OFFLINE_IMAGE_FIX.md        # 离线镜像修复报告
│   ├── CHANGELOG_CI_CD.md          # CI/CD 变更日志
│   ├── TESTING_CHECKLIST.md        # 测试检查清单
│   └── ...                         # 其他文档
├── cleanup.sh                      # 清理脚本（用于重新安装）
├── verify_cloud_images.sh          # 云端镜像完整性验证工具
├── setup_ssh_key.sh                # SSH 密钥配置脚本
└── README.md                       # 本文件
```

## 功能特性

✅ **完全离线支持** - 所有二进制文件、配置和容器镜像已完整打包
  - 包含 14 个容器镜像（8个 K3s + 4个 KubeEdge + 1个 EdgeMesh + 1个 Metrics Server）
  - 包含 EdgeMesh 离线 Helm Chart (v1.17.0)
  - 包含 Istio CRDs (destinationrule, gateway, virtualservice)
  - 包含 Metrics Server v0.8.0 部署清单和配置脚本
  - K3s 内置 metrics-server 已自动禁用（避免冲突）
  - 支持纯离线环境部署，无需任何网络连接

✅ **边缘日志采集与资源监控** - 【新增功能】
  - **kubectl logs** - 从云端实时查看边缘 Pod 日志
  - **kubectl exec** - 在边缘 Pod 中执行命令（调试利器）
  - **kubectl top node** - 监控边缘节点 CPU/内存使用情况
  - **kubectl top pod** - 监控边缘 Pod 资源消耗
  - CloudStream + EdgeStream 自动配置和启用
  - Metrics Server v0.8.0 自动部署（与 K3s 版本对齐）
  - K3s 内置 metrics-server 自动禁用（避免冲突）
  - iptables NAT 规则自动配置
  - 完全自动化，零手动配置

✅ **EdgeMesh 最佳实践** - 遵循官方部署指南
  - CloudCore 自动启用 dynamicController（支持 metaServer）
  - 自动安装 Istio CRDs（EdgeMesh 必需依赖）
  - 可选安装 EdgeMesh Agent（自动生成 PSK 密码）
  - 边缘节点使用 host 网络 + EdgeMesh 实现服务发现和通信

✅ **多架构支持** - amd64 和 arm64 兼容

✅ **一键安装** - 云端、Worker 和边缘端均支持自动化部署
  - 云端：`sudo ./install/install.sh <IP> [节点名]`
  - Worker：`sudo ./install.sh <master-ip:port> <k3s-token> [节点名]`
  - 边缘：`sudo ./install/install.sh <云端地址> <token> <节点名>`

✅ **镜像预导入** - 安装前自动加载所有镜像，避免在线拉取

✅ **Token 安全机制** - 云端自动生成 token 供边缘端接入

✅ **持续集成** - GitHub Actions 自动构建和发布到 Release
  - 自动构建多架构离线包（云端 / Worker / 边缘端 三类独立包）
  - 自动下载和打包所有依赖
  - 自动发布到 GitHub Releases

✅ **完整性验证** - 提供验证脚本确保离线包完整性
  - `verify_cloud_images.sh` 验证云端镜像完整性

✅ **IoT 友好** - 支持 MQTT Broker 部署
  - Mosquitto 服务配置文件
  - 完整的 MQTT 集成指南

## 节点角色说明

| 节点类型 | 安装包 | 角色说明 |
|----------|--------|---------|
| **云端 Master** | `kubeedge-cloud-*.tar.gz` | K3s 主节点 + KubeEdge CloudCore，集群控制面 |
| **K3s Worker** | `k3s-worker-*.tar.gz` | K3s Agent，扩展云端计算算力，与 master 在同一 k8s 集群 |
| **KubeEdge 边缘** | `kubeedge-edge-*.tar.gz` | EdgeCore，通过 KubeEdge 接入，适用于网络条件差的边缘场景 |

> **Worker vs 边缘节点区别：**
> - **K3s Worker**：稳定内网连接，常规 Kubernetes 节点，参与 k8s 调度，支持所有 k8s 功能
> - **KubeEdge 边缘**：弱网/离线场景，通过 WebSocket 长连接接入，专为 IoT/工业边缘设计

## 网络架构

### 边缘节点网络模式

边缘节点采用 **host 网络模式**，不使用 CNI 插件：
- ✅ 简化配置，无需为每个边缘节点分配独立的 Pod 网段
- ✅ 更适合边缘场景的资源限制
- ✅ 通过 EdgeMesh 实现服务网格能力

### EdgeMesh 服务网格

EdgeMesh 提供边缘服务发现和流量代理：
- **服务发现**: 通过 EdgeMesh DNS (169.254.96.16)
- **流量代理**: EdgeMesh Agent 实现服务间通信
- **高可用**: 支持配置多个中继节点
- **跨网络**: 支持边缘节点在不同网络环境下的通信

> 📘 详细部署步骤请参考 [EdgeMesh 部署指南](./docs/EDGEMESH_DEPLOYMENT.md)

## 详细文档

### 安装指南
- [云端安装指南](./cloud/install/README.md) - K3s + CloudCore 完整安装流程
- [边缘端安装指南](./edge/install/README.md) - EdgeCore 安装和配置
- [快速部署指南](./docs/QUICK_DEPLOY.md) - 快速上手部署步骤

### 配置和最佳实践
- [EdgeMesh 部署指南](./docs/EDGEMESH_DEPLOYMENT.md) - 边缘服务网格完整部署方案（含官方最佳实践）
- [EdgeCore 配置最佳实践](./docs/EDGECORE_CONFIG_BEST_PRACTICES.md) - EdgeCore + EdgeMesh 最小化配置
- [K3s 网络配置详解](./docs/K3S_NETWORK_CONFIG.md) - K3s 网络架构和配置说明

### 功能扩展
- [日志与监控快速部署](./docs/QUICK_DEPLOY_LOGS_METRICS.md) - 【新增】kubectl logs/exec/top 功能使用指南
- [日志与监控完整方案](./docs/LOG_METRICS_OFFLINE_DEPLOYMENT.md) - 【新增】离线环境日志采集与资源监控完整方案
- [IoT MQTT 集成指南](./docs/IOT_MQTT_INTEGRATION.md) - 边缘端 MQTT Broker 部署
- [SSH 密钥配置](./docs/SSH_KEY_SETUP.md) - SSH 免密访问配置

### 技术研究和分析
- [项目结构说明](./docs/PROJECT_STRUCTURE.md) - 项目目录和文件组织
- [CI/CD 架构设计](./docs/CI_CD_ARCHITECTURE.md) - GitHub Actions 自动化构建
- [构建流程总结](./docs/BUILD_FLOW_SUMMARY.md) - 离线包构建流程详解
- [离线镜像修复报告](./docs/OFFLINE_IMAGE_FIX.md) - 完整离线支持的技术实现
- [CI/CD 变更日志](./docs/CHANGELOG_CI_CD.md) - GitHub Actions 配置变更记录

### 测试和验证
- [测试检查清单](./docs/TESTING_CHECKLIST.md) - 完整的功能测试清单

## 验证工具

### 验证云端离线包完整性

```bash
# 验证构建的离线包是否包含所有必需镜像
bash verify_cloud_images.sh kubeedge-cloud-1.22.0-k3s-v1.34.2+k3s1-amd64.tar.gz
```

验证内容：
- ✓ 4个KubeEdge组件镜像
- ✓ 8个K3s系统镜像  
- ✓ 所有必需的二进制文件和配置

## 故障排除

### 清理重新安装

**云端 / 边缘节点：**
```bash
sudo bash cleanup.sh
```

**K3s Worker 节点：**
```bash
sudo ./cleanup.sh
# 清理后如需从 k8s 集群中删除节点记录，在 master 执行：
kubectl delete node <node-name>
```

清理内容：
- 停止并卸载相关服务（k3s-agent / edgecore）
- 删除二进制文件
- 清理配置文件和数据目录

### 日志采集与资源监控验证

**自动验证（推荐）:**
```bash
cd /data/kubeedge-cloud-xxx
sudo bash manifests/verify-logs-metrics.sh
```

验证项目：
- ✓ CloudCore 和 CloudStream 状态
- ✓ Metrics Server 部署状态
- ✓ iptables 规则配置
- ✓ kubectl logs/exec 功能
- ✓ kubectl top 功能

**使用示例:**
```bash
# 查看边缘 Pod 日志
kubectl logs <pod-name> -n <namespace>

# 在边缘 Pod 中执行命令
kubectl exec -it <pod-name> -n <namespace> -- /bin/bash

# 查看边缘节点资源使用情况
kubectl top node

# 查看边缘 Pod 资源使用情况
kubectl top pod -A
```

详细功能说明参考 [日志与监控快速部署指南](./docs/QUICK_DEPLOY_LOGS_METRICS.md)

### EdgeMesh 部署

**自动部署 (推荐):**
- cloud 安装脚本会自动检测 helm-charts 目录
- 提示时选择 `y` 即可自动部署 EdgeMesh
- PSK 密码自动生成并保存到 `edgemesh-psk.txt`

**手动部署:**
```bash
# 使用 cloud 安装包中的离线 Helm Chart
cd /data/kubeedge-cloud-xxx
helm install edgemesh ./helm-charts/edgemesh.tgz \
  --namespace kubeedge \
  --set agent.image=kubeedge/edgemesh-agent:v1.17.0 \
  --set agent.psk="$(openssl rand -base64 32)" \
  --set agent.relayNodes[0].nodeName=<master-node> \
  --set agent.relayNodes[0].advertiseAddress="{<云端IP>}"
```

**完全离线**: EdgeMesh 镜像和 Helm Chart 已预先打包在 cloud 安装包中，无需外网连接。

详细步骤参考 [EdgeMesh 部署指南](./docs/EDGEMESH_DEPLOYMENT.md)

## 版本信息

- **KubeEdge**: v1.22.0
- **K3s**: v1.34.2+k3s1（云端 Master 和 K3s Worker 共用）
- **EdgeMesh**: v1.17.0
- **Metrics Server**: v0.8.0 (与 K3s 内置版本对齐)
- **Istio CRDs**: v1.22.0 (destinationrule, gateway, virtualservice)
- **支持架构**: amd64, arm64

## 技术栈

- **容器运行时**: containerd (边缘) / K3s 内置 containerd (云端)
- **Kubernetes**: K3s (轻量级 Kubernetes 发行版)
- **边缘计算**: KubeEdge (CloudCore + EdgeCore)
- **服务网格**: EdgeMesh (边缘服务发现和流量代理)
- **网络模式**: 边缘节点 host 网络 + EdgeMesh DNS (169.254.96.16)
- **IoT 协议**: MQTT Broker (eclipse-mosquitto:2.0, 边缘本地运行)

## 核心文档

### 部署与配置
- [快速部署手册](docs/QUICK_DEPLOY.md) - 完整离线部署流程
- [SSH 密钥配置](docs/SSH_KEY_SETUP.md) - 云边通信密钥设置
- [EdgeMesh 部署指南](docs/EDGEMESH_DEPLOYMENT.md) - 服务网格部署

### IoT 与 MQTT
- **[MQTT 版本决策](docs/MQTT_VERSION_DECISION.md)** - MQTT 版本选择和统一方案 ⭐
- [IoT MQTT 部署策略](docs/IOT_MQTT_DEPLOYMENT_STRATEGY.md) - 本地 vs 云端部署对比

### 最佳实践
- [CNI 与 EdgeMesh 最佳实践](docs/CNI_EDGEMESH_BEST_PRACTICES.md)
- [EdgeCore 配置最佳实践](docs/EDGECORE_CONFIG_BEST_PRACTICES.md)
- [K3s 网络配置说明](docs/K3S_NETWORK_CONFIG.md)

### 问题解决
- [离线镜像修复指南](docs/OFFLINE_IMAGE_FIX.md) - 镜像加载和容器运行问题
- [测试检查清单](docs/TESTING_CHECKLIST.md) - 安装后验证步骤

