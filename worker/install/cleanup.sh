#!/usr/bin/env bash
set -euo pipefail

# K3s Worker 节点清理脚本
# 用途: sudo ./cleanup.sh
# 说明: 彻底卸载 k3s-agent，用于重新安装或退出集群

if [ "$EUID" -ne 0 ]; then
  echo "错误：此脚本需要使用 root 或 sudo 运行"
  exit 1
fi

echo "=== K3s Worker 节点清理脚本 ==="
echo "此操作将完全卸载 k3s-agent 并清除所有相关数据"
echo ""

REPLY=""
read -p "是否继续清理？(y/N): " -n 1 -r || true
echo ""
if [[ ! ${REPLY:-} =~ ^[Yy]$ ]]; then
  echo "❌ 用户取消清理"
  exit 0
fi

# 获取当前节点名（用于后续 master 侧提示）
NODE_NAME=$(hostname)

echo ""
echo "[1/5] 停止并禁用 k3s-agent 服务..."
systemctl stop k3s-agent 2>/dev/null || true
systemctl disable k3s-agent 2>/dev/null || true
echo "✓ k3s-agent 服务已停止"

echo "[2/5] 强制终止残留的 k3s / containerd-shim 进程..."
# 先 SIGTERM，再 SIGKILL，确保进程彻底退出
for sig in TERM KILL; do
  for proc in k3s containerd-shim containerd-shim-runc-v2; do
    pkill -"$sig" -x "$proc" 2>/dev/null || true
  done
  sleep 1
done
echo "✓ 残留进程已清理"

echo "[3/5] 卸载 k3s 相关挂载点..."
# 逐一卸载，不存在时忽略错误
for mp in $(mount | grep -oP '(?<=on )/run/k3s\S*' 2>/dev/null) \
           $(mount | grep -oP '(?<=on )/var/lib/rancher/k3s\S*' 2>/dev/null) \
           $(mount | grep -oP '(?<=on )/var/lib/kubelet\S*' 2>/dev/null); do
  umount -l "$mp" 2>/dev/null || true
done
echo "✓ 挂载点已卸载"

echo "[4/5] 删除 systemd 服务及二进制文件..."
rm -f /etc/systemd/system/k3s-agent.service
systemctl daemon-reload
rm -f /usr/local/bin/k3s
echo "✓ 服务文件和二进制已删除"

echo "[5/5] 清理所有 k3s 数据目录和 CNI 网络..."
# k3s 数据与配置
rm -rf /var/lib/rancher/k3s
rm -rf /etc/rancher/k3s
rm -rf /run/k3s

# kubelet / CNI
rm -rf /var/lib/kubelet
rm -rf /var/lib/cni
rm -rf /opt/cni/bin
rm -rf /etc/cni/net.d

# 日志
rm -f /var/log/k3s-worker-install.log

# 清理 CNI 网络接口（忽略不存在的接口）
for iface in cni0 flannel.1 kube-ipvs0; do
  if ip link show "$iface" &>/dev/null; then
    ip link set "$iface" down 2>/dev/null || true
    ip link delete "$iface" 2>/dev/null || true
  fi
done

# 清理网络命名空间
ip netns list 2>/dev/null | grep -E '^(cni|k3s)' | while read -r ns _; do
  ip netns delete "$ns" 2>/dev/null || true
done

echo "✓ 数据目录和网络已清理"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "=== 本节点 k3s-agent 已彻底卸载 ==="
echo ""
echo "⚠️  重要：若要重装此节点，必须在 master 节点执行以下命令清理旧记录"
echo "   否则重装时会出现 'Node authorization rejected' 错误（节点密码冲突）"
echo ""
echo "━━━ 在 master 节点执行（节点名: ${NODE_NAME}）━━━"
echo ""
echo "  # 步骤1：删除 Kubernetes 节点对象和密码 Secret"
echo "  kubectl delete node ${NODE_NAME} 2>/dev/null || true"
echo "  kubectl delete secret -n kube-system ${NODE_NAME}.node-password.k3s 2>/dev/null || true"
echo ""
echo "  # 步骤2：删除 k3s 本地节点密码文件中的记录（关键，kubectl 删不到）"
echo "  sed -i '/${NODE_NAME}/d' /var/lib/rancher/k3s/server/cred/node-passwd"
echo ""
echo "  完成后无需重启 k3s-server，重新运行 install.sh 即可。"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
