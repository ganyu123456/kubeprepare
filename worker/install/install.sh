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

# 步骤2: 创建 k3s-agent systemd 服务
echo "[2/3] 配置 k3s-agent systemd 服务..." | tee -a "$INSTALL_LOG"

cat > /etc/systemd/system/k3s-agent.service << EOF
[Unit]
Description=Lightweight Kubernetes Agent
Documentation=https://k3s.io
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/local/bin/k3s agent \\
  --server=https://${K3S_MASTER_ADDR}:${K3S_MASTER_PORT} \\
  --token=${K3S_TOKEN} \\
  --node-name=${NODE_NAME}
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
EOF

chmod 644 /etc/systemd/system/k3s-agent.service
systemctl daemon-reload
systemctl enable k3s-agent
echo "✓ k3s-agent 服务配置完成" | tee -a "$INSTALL_LOG"

# 步骤3: 启动服务并等待就绪
echo "[3/3] 启动 k3s-agent 服务..." | tee -a "$INSTALL_LOG"

if ! systemctl start k3s-agent; then
  echo "❌ 启动 k3s-agent 失败，查看日志:" | tee -a "$INSTALL_LOG"
  systemctl status k3s-agent --no-pager | tee -a "$INSTALL_LOG"
  exit 1
fi

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
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee -a "$INSTALL_LOG"
echo "" | tee -a "$INSTALL_LOG"
echo "安装日志: $INSTALL_LOG" | tee -a "$INSTALL_LOG"
