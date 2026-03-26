#!/usr/bin/env bash
set -euo pipefail

# K3s Worker 节点离线安装脚本
# 用途: sudo ./install.sh <master-ip:port> <k3s-token> [node-name]
# 示例: sudo ./install.sh 192.168.122.231:6443 K10xxx...::xxx sh worker-01

if [ "$EUID" -ne 0 ]; then
  echo "错误：此脚本需要使用 root 或 sudo 运行"
  exit 1
fi

K3S_MASTER_ADDR_PORT="${1:-}"
K3S_TOKEN="${2:-}"
NODE_NAME="${3:-k3s-worker-$(hostname -s)}"
K3S_VERSION="v1.34.2+k3s1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_LOG="/var/log/k3s-worker-install.log"

# 验证参数
if [ -z "$K3S_MASTER_ADDR_PORT" ] || [ -z "$K3S_TOKEN" ]; then
  echo "错误：缺少必需的参数"
  echo "用法: sudo ./install.sh <master-ip:port> <k3s-token> [node-name]"
  echo "示例: sudo ./install.sh 192.168.122.231:6443 K10xxx...::xxx:sh worker-01"
  exit 1
fi

# 解析 master 地址和端口
if [[ "$K3S_MASTER_ADDR_PORT" == *:* ]]; then
  K3S_MASTER_ADDR="${K3S_MASTER_ADDR_PORT%%:*}"
  K3S_MASTER_PORT="${K3S_MASTER_ADDR_PORT##*:}"
  if ! [[ "$K3S_MASTER_PORT" =~ ^[0-9]+$ ]]; then
    K3S_MASTER_ADDR="$K3S_MASTER_ADDR_PORT"
    K3S_MASTER_PORT="6443"
  fi
else
  K3S_MASTER_ADDR="$K3S_MASTER_ADDR_PORT"
  K3S_MASTER_PORT="6443"
fi

# 校验 node-name 合法性
if ! [[ "$NODE_NAME" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?(\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*$ ]]; then
  echo "错误：节点名称 '$NODE_NAME' 不符合 RFC 1123 规范，必须为小写字母、数字、'-'或'.'，且首尾为字母数字。"
  exit 1
fi

# 检测系统架构
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  ARCH="amd64" ;;
  aarch64) ARCH="arm64" ;;
  *)
    echo "错误：不支持的架构: $ARCH"
    exit 1
    ;;
esac

# ─────────────────────────────────────
# 函数: 安装 nfs-common（离线优先，在线回退）
# ─────────────────────────────────────
install_nfs_common() {
  if dpkg -l nfs-common 2>/dev/null | grep -q "^ii" || command -v mount.nfs4 &>/dev/null; then
    echo "✓ nfs-common 已安装" | tee -a "$INSTALL_LOG"
    return 0
  fi
  echo "[系统依赖] 安装 nfs-common（NFS 客户端，K8s NFS PVC 挂载必需）..." | tee -a "$INSTALL_LOG"
  NFS_DIR=$(find "$SCRIPT_DIR" -maxdepth 2 -type d -name "nfs" 2>/dev/null | head -1)
  if [ -n "$NFS_DIR" ] && ls "$NFS_DIR"/*.deb &>/dev/null 2>&1; then
    echo "  使用离线 deb 包安装..." | tee -a "$INSTALL_LOG"
    dpkg -i --force-depends "$NFS_DIR"/*.deb >> "$INSTALL_LOG" 2>&1 || true
    apt-get install -f -y -qq >> "$INSTALL_LOG" 2>&1 || true
  fi
  if dpkg -l nfs-common 2>/dev/null | grep -q "^ii"; then
    echo "✓ nfs-common 离线安装成功" | tee -a "$INSTALL_LOG"
    return 0
  fi
  echo "  在线安装 nfs-common..." | tee -a "$INSTALL_LOG"
  apt-get update -qq >> "$INSTALL_LOG" 2>&1 && \
    apt-get install -y -qq nfs-common >> "$INSTALL_LOG" 2>&1 && \
    echo "✓ nfs-common 在线安装成功" | tee -a "$INSTALL_LOG" || \
    echo "⚠️  nfs-common 安装失败，NFS PVC 挂载可能受影响" | tee -a "$INSTALL_LOG"
}

# ─────────────────────────────────────
# 函数: 安装 helm 到系统 PATH
# ─────────────────────────────────────
install_helm_to_path() {
  if command -v helm &>/dev/null; then
    echo "✓ helm 已在 PATH: $(helm version --short 2>/dev/null)" | tee -a "$INSTALL_LOG"
    return 0
  fi
  HELM_BIN=$(find "$SCRIPT_DIR" -maxdepth 2 -name "helm" -type f 2>/dev/null | head -1)
  if [ -z "$HELM_BIN" ]; then
    echo "⚠️  未在离线包中找到 helm 二进制文件，跳过安装" | tee -a "$INSTALL_LOG"
    return 0
  fi
  echo "[系统依赖] 安装 helm 到 /usr/local/bin/..." | tee -a "$INSTALL_LOG"
  cp "$HELM_BIN" /usr/local/bin/helm
  chmod +x /usr/local/bin/helm
  echo "✓ helm 安装成功: $(helm version --short 2>/dev/null)" | tee -a "$INSTALL_LOG"
}

echo "=== K3s Worker 节点离线安装脚本 ===" | tee "$INSTALL_LOG"
echo "K3s 版本: $K3S_VERSION" | tee -a "$INSTALL_LOG"
echo "架构: $ARCH" | tee -a "$INSTALL_LOG"
echo "Master 地址: https://$K3S_MASTER_ADDR:$K3S_MASTER_PORT" | tee -a "$INSTALL_LOG"
echo "节点名称: $NODE_NAME" | tee -a "$INSTALL_LOG"
echo "" | tee -a "$INSTALL_LOG"

# 检查是否已安装
if systemctl list-units --full -all 2>/dev/null | grep -q "k3s-agent.service"; then
  echo "⚠️  警告: 检测到系统已安装 k3s-agent" | tee -a "$INSTALL_LOG"
  echo "   如需重新安装，请先运行清理脚本: sudo ./cleanup.sh" | tee -a "$INSTALL_LOG"
  echo "" | tee -a "$INSTALL_LOG"
  REPLY=""
  read -p "是否继续？这将覆盖现有安装 (y/N): " -n 1 -r || true
  echo ""
  if [[ ! ${REPLY:-} =~ ^[Yy]$ ]]; then
    echo "❌ 用户取消安装"
    exit 1
  fi
fi

# 步骤0: 安装系统依赖
echo "[0/3] 安装系统依赖（nfs-common、helm）..." | tee -a "$INSTALL_LOG"
install_nfs_common
install_helm_to_path

# 步骤1: 安装 k3s 二进制文件
echo "[1/3] 安装 k3s 二进制文件..." | tee -a "$INSTALL_LOG"
K3S_BIN=$(find "$SCRIPT_DIR" -name "k3s-${ARCH}" -type f 2>/dev/null | head -1)
if [ -z "$K3S_BIN" ]; then
  echo "❌ 错误: 未在 $SCRIPT_DIR 中找到 k3s-${ARCH} 二进制文件" | tee -a "$INSTALL_LOG"
  echo "   请确认离线包已完整解压且包含 k3s-${ARCH}" | tee -a "$INSTALL_LOG"
  exit 1
fi

# 停止旧服务（如有）
systemctl stop k3s-agent 2>/dev/null || true
systemctl disable k3s-agent 2>/dev/null || true
rm -f /etc/systemd/system/k3s-agent.service

cp "$K3S_BIN" /usr/local/bin/k3s
chmod +x /usr/local/bin/k3s
echo "✓ k3s 二进制文件已安装: $(k3s --version 2>/dev/null | head -1)" | tee -a "$INSTALL_LOG"

# 步骤2: 创建 k3s-agent systemd 服务（参照官方 k3s install 脚本方式）
echo "[2/3] 配置 k3s-agent systemd 服务..." | tee -a "$INSTALL_LOG"

# 用环境文件传参，与官方 k3s 在线安装方式保持一致
# 注意：node-role.kubernetes.io/* 是受保护前缀，不能通过 --node-label 由节点自己设置
#       加入后由 master 执行 kubectl label node 来打 worker 角色标签
mkdir -p /etc/rancher/k3s
cat > /etc/rancher/k3s/k3s.env << EOF
K3S_URL=https://${K3S_MASTER_ADDR}:${K3S_MASTER_PORT}
K3S_TOKEN=${K3S_TOKEN}
K3S_NODE_NAME=${NODE_NAME}
EOF
chmod 600 /etc/rancher/k3s/k3s.env

cat > /etc/systemd/system/k3s-agent.service << 'SVCEOF'
[Unit]
Description=Lightweight Kubernetes Agent
Documentation=https://k3s.io
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
EnvironmentFile=-/etc/rancher/k3s/k3s.env
ExecStart=/usr/local/bin/k3s agent
KillMode=process
Delegate=yes
LimitNOFILE=1048576
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
TimeoutStartSec=0
Restart=always
RestartSec=5s
StandardOutput=journal
StandardError=journal
SyslogIdentifier=k3s-agent

[Install]
WantedBy=multi-user.target
SVCEOF

chmod 644 /etc/systemd/system/k3s-agent.service
systemctl daemon-reload
systemctl enable k3s-agent
echo "✓ k3s-agent 服务配置完成" | tee -a "$INSTALL_LOG"

# 步骤3: 非阻塞启动，等待进程存活
echo "[3/4] 启动 k3s-agent 服务..." | tee -a "$INSTALL_LOG"

# --no-block 立即返回，避免 Type=notify+TimeoutStartSec=0 导致永久阻塞
systemctl start --no-block k3s-agent

echo "等待 k3s-agent 启动（最多 60 秒）..." | tee -a "$INSTALL_LOG"
for i in $(seq 1 30); do
  STATUS=$(systemctl is-active k3s-agent 2>/dev/null || echo "unknown")
  if [ "$STATUS" = "active" ]; then
    echo "✓ k3s-agent 服务已启动 (${i}×2s)" | tee -a "$INSTALL_LOG"
    break
  elif [ "$STATUS" = "failed" ]; then
    echo "❌ k3s-agent 服务启动失败" | tee -a "$INSTALL_LOG"
    systemctl status k3s-agent --no-pager | tee -a "$INSTALL_LOG"
    exit 1
  fi
  if [ $((i % 5)) -eq 0 ]; then
    echo "  等待中... (${i}/30) 状态: $STATUS" | tee -a "$INSTALL_LOG"
  fi
  sleep 2
done

STATUS=$(systemctl is-active k3s-agent 2>/dev/null || echo "unknown")
if [ "$STATUS" != "active" ]; then
  echo "⚠️  k3s-agent 启动超时，最终状态: $STATUS" | tee -a "$INSTALL_LOG"
  echo "   请手动检查: journalctl -u k3s-agent -f" | tee -a "$INSTALL_LOG"
fi

# 步骤4: 加载 K3s 系统镜像到 containerd
echo "[4/4] 加载 K3s 系统镜像到 containerd..." | tee -a "$INSTALL_LOG"

IMAGES_DIR=$(find "$SCRIPT_DIR" -type d -name "images" 2>/dev/null | head -1)

if [ -n "$IMAGES_DIR" ] && [ -d "$IMAGES_DIR" ]; then
  # 等待 containerd 就绪
  echo "  等待 containerd 就绪..." | tee -a "$INSTALL_LOG"
  for i in $(seq 1 30); do
    if k3s ctr images ls >/dev/null 2>&1; then
      echo "  ✓ containerd 已就绪" | tee -a "$INSTALL_LOG"
      break
    fi
    if [ "$i" -eq 30 ]; then
      echo "  ⚠️  containerd 等待超时，跳过镜像加载" | tee -a "$INSTALL_LOG"
    fi
    sleep 2
  done

  IMAGE_COUNT=$(find "$IMAGES_DIR" -name "*.tar" -type f 2>/dev/null | wc -l)
  echo "  找到 $IMAGE_COUNT 个镜像文件" | tee -a "$INSTALL_LOG"

  LOADED=0
  FAILED=0
  for image_tar in "$IMAGES_DIR"/*.tar; do
    if [ -f "$image_tar" ]; then
      image_name=$(basename "$image_tar")
      if k3s ctr images import "$image_tar" >> "$INSTALL_LOG" 2>&1; then
        LOADED=$((LOADED + 1))
        echo "  ✓ $image_name" | tee -a "$INSTALL_LOG"
      else
        FAILED=$((FAILED + 1))
        echo "  ✗ $image_name（失败）" | tee -a "$INSTALL_LOG"
      fi
    fi
  done
  echo "  镜像加载完成: $LOADED 成功, $FAILED 失败" | tee -a "$INSTALL_LOG"
else
  echo "  ⚠️  未找到镜像目录，跳过镜像加载" | tee -a "$INSTALL_LOG"
fi

echo "" | tee -a "$INSTALL_LOG"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee -a "$INSTALL_LOG"
echo "=== K3s Worker 节点安装完成 ===" | tee -a "$INSTALL_LOG"
echo "节点名称: $NODE_NAME" | tee -a "$INSTALL_LOG"
echo "Master:   https://$K3S_MASTER_ADDR:$K3S_MASTER_PORT" | tee -a "$INSTALL_LOG"
echo "" | tee -a "$INSTALL_LOG"
echo "=== 后续步骤 ===" | tee -a "$INSTALL_LOG"
echo "1. 检查 k3s-agent 服务状态:" | tee -a "$INSTALL_LOG"
echo "   systemctl status k3s-agent" | tee -a "$INSTALL_LOG"
echo "2. 查看 k3s-agent 实时日志:" | tee -a "$INSTALL_LOG"
echo "   journalctl -u k3s-agent -f" | tee -a "$INSTALL_LOG"
echo "3. 在 master 节点验证 worker 已加入:" | tee -a "$INSTALL_LOG"
echo "   kubectl get nodes" | tee -a "$INSTALL_LOG"
echo "4. 在 master 节点为该节点打上 worker 角色标签:" | tee -a "$INSTALL_LOG"
echo "   kubectl label node ${NODE_NAME} node-role.kubernetes.io/worker=''" | tee -a "$INSTALL_LOG"
echo "   （node-role.kubernetes.io/* 是受保护前缀，只能由 master 设置）" | tee -a "$INSTALL_LOG"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee -a "$INSTALL_LOG"
echo "" | tee -a "$INSTALL_LOG"
echo "安装日志: $INSTALL_LOG" | tee -a "$INSTALL_LOG"
