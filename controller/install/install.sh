#!/usr/bin/env bash
set -euo pipefail

# K3s 额外控制节点离线安装脚本（HA 高可用扩容）
#
# 用途: sudo ./install.sh <first-server-ip:port> <node-token> <this-node-ip> [node-name]
# 示例: sudo ./install.sh 192.168.1.10:6443 K10xxx...::server:xxx 192.168.1.11 cloudedge-controller-02
#
# 说明:
#   此脚本用于在已有 K3s 集群基础上，以内置 etcd 模式加入第二、三个控制节点，
#   实现 K3s HA 高可用。第一个控制节点须已由 cloud/install/install.sh 安装
#   且以 --cluster-init 模式启动（内置 etcd）。
#
# 前提条件:
#   1. 第一个控制节点已正常运行（cloud 安装包已完成，含 --cluster-init）
#   2. 本节点与第一个控制节点以下端口互通: 6443、2379、2380
#   3. 在第一个控制节点执行以下命令获取 token:
#      cat /var/lib/rancher/k3s/server/token

if [ "$EUID" -ne 0 ]; then
  echo "错误：此脚本需要使用 root 或 sudo 运行"
  exit 1
fi

FIRST_SERVER_ADDR_PORT="${1:-}"
NODE_TOKEN="${2:-}"
NODE_IP="${3:-}"
NODE_NAME="${4:-k3s-controller-$(hostname -s)}"

K3S_VERSION="v1.34.2+k3s1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_LOG="/var/log/k3s-controller-install.log"

# =====================================
# 参数校验
# =====================================

if [ -z "$FIRST_SERVER_ADDR_PORT" ] || [ -z "$NODE_TOKEN" ] || [ -z "$NODE_IP" ]; then
  echo "错误：缺少必需的参数"
  echo ""
  echo "用法: sudo ./install.sh <first-server-ip:port> <node-token> <this-node-ip> [node-name]"
  echo ""
  echo "示例: sudo ./install.sh 192.168.1.10:6443 K10xxx...::server:xxx 192.168.1.11 cloudedge-controller-02"
  echo ""
  echo "获取 node-token（在第一个控制节点执行）:"
  echo "  cat /var/lib/rancher/k3s/server/token"
  exit 1
fi

# 解析第一个控制节点的地址和端口
if [[ "$FIRST_SERVER_ADDR_PORT" == *:* ]]; then
  FIRST_SERVER_ADDR="${FIRST_SERVER_ADDR_PORT%%:*}"
  FIRST_SERVER_PORT="${FIRST_SERVER_ADDR_PORT##*:}"
  if ! [[ "$FIRST_SERVER_PORT" =~ ^[0-9]+$ ]]; then
    FIRST_SERVER_ADDR="$FIRST_SERVER_ADDR_PORT"
    FIRST_SERVER_PORT="6443"
  fi
else
  FIRST_SERVER_ADDR="$FIRST_SERVER_ADDR_PORT"
  FIRST_SERVER_PORT="6443"
fi

# 校验 IP 格式
if ! [[ "$FIRST_SERVER_ADDR" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
  echo "错误：无效的第一个控制节点 IP: $FIRST_SERVER_ADDR"
  exit 1
fi
if ! [[ "$NODE_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
  echo "错误：无效的本节点 IP: $NODE_IP"
  exit 1
fi

# 校验节点名称符合 RFC 1123
if ! [[ "$NODE_NAME" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?(\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*$ ]]; then
  echo "错误：节点名称 '$NODE_NAME' 不符合 RFC 1123 规范"
  echo "  必须为小写字母、数字、'-' 或 '.'，且首尾为字母数字"
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

echo "=== K3s 控制节点离线安装脚本（HA 扩容）===" | tee "$INSTALL_LOG"
echo "K3s 版本:         $K3S_VERSION" | tee -a "$INSTALL_LOG"
echo "架构:             $ARCH" | tee -a "$INSTALL_LOG"
echo "第一个控制节点:   https://$FIRST_SERVER_ADDR:$FIRST_SERVER_PORT" | tee -a "$INSTALL_LOG"
echo "本节点 IP:        $NODE_IP" | tee -a "$INSTALL_LOG"
echo "本节点名称:       $NODE_NAME" | tee -a "$INSTALL_LOG"
echo "" | tee -a "$INSTALL_LOG"

# =====================================
# 检查是否已安装
# =====================================
if systemctl list-units --full -all 2>/dev/null | grep -q "^k3s\.service"; then
  echo "⚠️  警告：检测到系统已安装 k3s server 服务" | tee -a "$INSTALL_LOG"
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

# =====================================
# 步骤 1: 检查与第一个控制节点的网络连通性
# =====================================
echo "[1/5] 检查网络连通性..." | tee -a "$INSTALL_LOG"

check_port() {
  local host="$1" port="$2" timeout="${3:-5}"
  if command -v nc &>/dev/null; then
    nc -z -w "$timeout" "$host" "$port" 2>/dev/null
  else
    timeout "$timeout" bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null
  fi
}

ALL_PORTS_OK=true
for port in "$FIRST_SERVER_PORT" 2379 2380; do
  if check_port "$FIRST_SERVER_ADDR" "$port"; then
    echo "  ✓ $FIRST_SERVER_ADDR:$port 可达" | tee -a "$INSTALL_LOG"
  else
    echo "  ✗ $FIRST_SERVER_ADDR:$port 不可达（请检查防火墙）" | tee -a "$INSTALL_LOG"
    ALL_PORTS_OK=false
  fi
done

if [ "$ALL_PORTS_OK" = false ]; then
  echo "警告：部分端口不可达，安装可能失败。确认网络后可继续。" | tee -a "$INSTALL_LOG"
  REPLY=""
  read -p "是否继续安装？(y/N): " -n 1 -r || true
  echo ""
  if [[ ! ${REPLY:-} =~ ^[Yy]$ ]]; then
    echo "❌ 用户取消安装"
    exit 1
  fi
fi

# =====================================
# 步骤 2: 安装 k3s 二进制文件
# =====================================
echo "[2/5] 安装 k3s 二进制文件..." | tee -a "$INSTALL_LOG"

K3S_BIN=$(find "$SCRIPT_DIR" -name "k3s-${ARCH}" -type f 2>/dev/null | head -1)
if [ -z "$K3S_BIN" ]; then
  echo "❌ 错误：未在 $SCRIPT_DIR 中找到 k3s-${ARCH} 二进制文件" | tee -a "$INSTALL_LOG"
  echo "   请确认离线包已完整解压且包含 k3s-${ARCH}" | tee -a "$INSTALL_LOG"
  exit 1
fi

# 停止旧服务（如有）
systemctl stop k3s 2>/dev/null || true
systemctl disable k3s 2>/dev/null || true
rm -f /etc/systemd/system/k3s.service

cp "$K3S_BIN" /usr/local/bin/k3s
chmod +x /usr/local/bin/k3s
echo "✓ k3s 二进制文件已安装: $(k3s --version 2>/dev/null | head -1)" | tee -a "$INSTALL_LOG"

# =====================================
# 步骤 3: 配置 k3s server systemd 服务
# =====================================
echo "[3/5] 配置 k3s server systemd 服务..." | tee -a "$INSTALL_LOG"

mkdir -p /etc/rancher/k3s

# token 和节点名写入环境文件（避免出现在进程列表中）
cat > /etc/rancher/k3s/k3s.env << EOF
K3S_TOKEN=${NODE_TOKEN}
K3S_NODE_NAME=${NODE_NAME}
EOF
chmod 600 /etc/rancher/k3s/k3s.env

# 服务文件：--server 模式加入已有 HA 集群（不带 --cluster-init）
#
# 重要：K3s "critical config"（egress-selector-mode、cluster-cidr、service-cidr、
# cluster-dns 等）在集群初始化时已写入 etcd，加入节点不得重复指定这些参数。
# 若加入节点指定了这些参数，K3s 会将其与 etcd 存储值比对，任何不匹配即报错退出。
# 加入节点只需指定节点级参数（server、advertise-address、node-name、tls-san）
# 以及 bind-address 等非 critical 的运行时参数。
cat > /etc/systemd/system/k3s.service << EOF
[Unit]
Description=Lightweight Kubernetes
Documentation=https://k3s.io
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
EnvironmentFile=-/etc/rancher/k3s/k3s.env
ExecStart=/usr/local/bin/k3s server \\
  --server=https://${FIRST_SERVER_ADDR}:${FIRST_SERVER_PORT} \\
  --advertise-address=${NODE_IP} \\
  --node-name=${NODE_NAME} \\
  --tls-san=${NODE_IP} \\
  --bind-address=0.0.0.0 \\
  --kube-apiserver-arg=bind-address=0.0.0.0 \\
  --kube-apiserver-arg=advertise-address=${NODE_IP} \\
  --kube-apiserver-arg=kubelet-certificate-authority= \\
  --kube-controller-manager-arg=bind-address=0.0.0.0 \\
  --kube-controller-manager-arg=node-cidr-mask-size=24 \\
  --kube-scheduler-arg=bind-address=0.0.0.0
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
SyslogIdentifier=k3s

[Install]
WantedBy=multi-user.target
EOF

chmod 644 /etc/systemd/system/k3s.service
systemctl daemon-reload
systemctl enable k3s
echo "✓ k3s server 服务配置完成" | tee -a "$INSTALL_LOG"

# =====================================
# 步骤 4: 启动服务并等待就绪
# =====================================
echo "[4/5] 启动 k3s server 服务..." | tee -a "$INSTALL_LOG"

# --no-block 立即返回，避免 Type=notify+TimeoutStartSec=0 导致永久阻塞
systemctl start --no-block k3s

echo "等待 k3s server 启动（最多 120 秒）..." | tee -a "$INSTALL_LOG"
for i in $(seq 1 60); do
  STATUS=$(systemctl is-active k3s 2>/dev/null || echo "unknown")
  if [ "$STATUS" = "active" ]; then
    echo "✓ k3s server 服务已启动 (${i}×2s)" | tee -a "$INSTALL_LOG"
    break
  elif [ "$STATUS" = "failed" ]; then
    echo "❌ k3s server 服务启动失败" | tee -a "$INSTALL_LOG"
    systemctl status k3s --no-pager | tee -a "$INSTALL_LOG"
    echo "" | tee -a "$INSTALL_LOG"
    echo "常见原因排查：" | tee -a "$INSTALL_LOG"
    echo "  1. 确认第一个控制节点使用了 --cluster-init（内置 etcd 模式）" | tee -a "$INSTALL_LOG"
    echo "  2. 确认 token 正确（来自 cat /var/lib/rancher/k3s/server/token）" | tee -a "$INSTALL_LOG"
    echo "  3. 确认端口 6443/2379/2380 互通" | tee -a "$INSTALL_LOG"
    echo "  4. 若报 'critical configuration mismatched'，说明此节点参数与集群不符" | tee -a "$INSTALL_LOG"
    echo "     查看详细日志: journalctl -u k3s -n 50 --no-pager" | tee -a "$INSTALL_LOG"
    exit 1
  fi
  if [ $((i % 10)) -eq 0 ]; then
    echo "  等待中... (${i}/60) 状态: $STATUS" | tee -a "$INSTALL_LOG"
  fi
  sleep 2
done

STATUS=$(systemctl is-active k3s 2>/dev/null || echo "unknown")
if [ "$STATUS" != "active" ]; then
  echo "⚠️  k3s server 启动超时，最终状态: $STATUS" | tee -a "$INSTALL_LOG"
  echo "   请手动检查: journalctl -u k3s -f" | tee -a "$INSTALL_LOG"
fi

# 等待 kubeconfig 就绪
echo "等待 kubeconfig 就绪..." | tee -a "$INSTALL_LOG"
for i in $(seq 1 30); do
  if [ -f /etc/rancher/k3s/k3s.yaml ]; then
    echo "✓ kubeconfig 已就绪" | tee -a "$INSTALL_LOG"
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "⚠️  kubeconfig 等待超时，跳过镜像加载步骤" | tee -a "$INSTALL_LOG"
  fi
  sleep 2
done

# =====================================
# 步骤 5: 加载 K3s 系统镜像到 containerd
# =====================================
echo "[5/5] 加载 K3s 系统镜像到 containerd..." | tee -a "$INSTALL_LOG"

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

# =====================================
# 安装完成
# =====================================
echo "" | tee -a "$INSTALL_LOG"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee -a "$INSTALL_LOG"
echo "=== K3s 控制节点安装完成 ===" | tee -a "$INSTALL_LOG"
echo "本节点:           $NODE_NAME ($NODE_IP)" | tee -a "$INSTALL_LOG"
echo "已加入集群:       https://$FIRST_SERVER_ADDR:$FIRST_SERVER_PORT" | tee -a "$INSTALL_LOG"
echo "" | tee -a "$INSTALL_LOG"
echo "=== 后续步骤 ===" | tee -a "$INSTALL_LOG"
echo "1. 检查 k3s server 服务状态:" | tee -a "$INSTALL_LOG"
echo "   systemctl status k3s" | tee -a "$INSTALL_LOG"
echo "2. 查看 k3s server 实时日志:" | tee -a "$INSTALL_LOG"
echo "   journalctl -u k3s -f" | tee -a "$INSTALL_LOG"
echo "3. 在任意控制节点验证新节点已加入（ROLES 应为 control-plane）:" | tee -a "$INSTALL_LOG"
echo "   kubectl get nodes" | tee -a "$INSTALL_LOG"
echo "4. 验证 etcd 成员列表（在任意控制节点执行）:" | tee -a "$INSTALL_LOG"
echo "   k3s etcd-snapshot ls 2>/dev/null || kubectl get endpoints -n kube-system" | tee -a "$INSTALL_LOG"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee -a "$INSTALL_LOG"
echo "" | tee -a "$INSTALL_LOG"
echo "安装日志: $INSTALL_LOG" | tee -a "$INSTALL_LOG"
