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
echo "此操作将完全卸载 k3s-agent 并清除相关数据"
echo ""

REPLY=""
read -p "是否继续清理？(y/N): " -n 1 -r || true
echo ""
if [[ ! ${REPLY:-} =~ ^[Yy]$ ]]; then
  echo "❌ 用户取消清理"
  exit 0
fi

echo ""
echo "[1/4] 停止并禁用 k3s-agent 服务..."
systemctl stop k3s-agent 2>/dev/null || true
systemctl disable k3s-agent 2>/dev/null || true
echo "✓ k3s-agent 服务已停止"

echo "[2/4] 删除 systemd 服务文件..."
rm -f /etc/systemd/system/k3s-agent.service
systemctl daemon-reload
echo "✓ 服务文件已删除"

echo "[3/4] 删除 k3s 二进制文件..."
rm -f /usr/local/bin/k3s
echo "✓ k3s 二进制文件已删除"

echo "[4/4] 清理 k3s agent 数据目录..."
rm -rf /var/lib/rancher/k3s/agent
rm -rf /var/lib/rancher/k3s/data
rm -f /var/log/k3s-worker-install.log
echo "✓ 数据目录已清理"

echo ""
echo "=== K3s Worker 节点清理完成 ==="
echo "节点已从本地卸载，如需从集群中删除节点记录，请在 master 节点执行："
echo "  kubectl delete node <node-name>"
