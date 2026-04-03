#!/usr/bin/env bash
set -euo pipefail

# K3s 集群节点清理脚本
#
# 用法:
#   sudo ./cleanup.sh [--force]
#
# 说明:
#   自动检测本节点角色（server / agent）并执行对应清理流程。
#   对于 server 节点（控制节点），会提示先从集群中驱逐本节点。
#   --force 参数跳过交互确认（适用于自动化脚本）。

if [ "$EUID" -ne 0 ]; then
  echo "错误：请使用 root 或 sudo 运行此脚本"
  exit 1
fi

FORCE="${1:-}"
NODE_NAME=$(hostname -s)

# 检测节点角色
IS_SERVER=false
IS_AGENT=false
if systemctl list-unit-files 2>/dev/null | grep -q "^k3s.service"; then
  IS_SERVER=true
fi
if systemctl list-unit-files 2>/dev/null | grep -q "^k3s-agent.service"; then
  IS_AGENT=true
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "=== K3s 集群节点清理脚本 ==="
echo ""
[ "$IS_SERVER" = "true" ] && echo "  检测到角色: K3s Server（控制节点）"
[ "$IS_AGENT" = "true" ]  && echo "  检测到角色: K3s Agent（Worker 节点）"
echo ""

# Server 节点特殊提示
if [ "$IS_SERVER" = "true" ] && [ "$FORCE" != "--force" ]; then
  echo "┌─────────────────────────────────────────────────────────────┐"
  echo "│  ⚠️   etcd quorum 警告                                      │"
  echo "│                                                             │"
  echo "│  控制节点退出会影响 etcd 集群 quorum。                      │"
  echo "│  请务必先在其他控制节点完成以下操作：                       │"
  echo "│                                                             │"
  echo "│  1. 驱逐本节点 Pod:                                         │"
  echo "│     kubectl drain ${NODE_NAME} \\                        │"
  echo "│       --ignore-daemonsets --delete-emptydir-data           │"
  echo "│  2. 从集群删除本节点:                                       │"
  echo "│     kubectl delete node ${NODE_NAME}                    │"
  echo "│                                                             │"
  echo "│  HA 集群需保留奇数个控制节点（≥3台中至少2台存活）           │"
  echo "└─────────────────────────────────────────────────────────────┘"
  echo ""
  read -p "确认已完成以上操作，继续清理？(y/N): " -n 1 -r || true
  echo ""
  if [[ ! ${REPLY:-} =~ ^[Yy]$ ]]; then
    echo "❌ 用户取消"
    exit 0
  fi
fi

if [ "$FORCE" != "--force" ]; then
  read -p "将完全卸载 K3s 并清除所有数据，确认继续？(y/N): " -n 1 -r || true
  echo ""
  if [[ ! ${REPLY:-} =~ ^[Yy]$ ]]; then
    echo "❌ 用户取消"
    exit 0
  fi
fi

echo ""
echo "[1/8] 停止并禁用 K3s 服务..."
for svc in k3s k3s-agent; do
  if systemctl is-active --quiet "$svc" 2>/dev/null; then
    systemctl stop "$svc" || true
  fi
  if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
    systemctl disable "$svc" || true
  fi
done
echo "  ✓ K3s 服务已停止"

echo "[2/8] 运行官方卸载脚本（如存在）..."
for script in /usr/local/bin/k3s-uninstall.sh /usr/local/bin/k3s-agent-uninstall.sh; do
  if [ -f "$script" ]; then
    "$script" 2>/dev/null || true
    echo "  ✓ $script 已执行"
  fi
done

echo "[3/8] 强制终止残留进程..."
for proc in k3s containerd containerd-shim containerd-shim-runc-v2; do
  pkill -9 "$proc" 2>/dev/null || true
done
sleep 2
echo "  ✓ 残留进程已清理"

echo "[4/8] 卸载挂载点..."
for mp in $(mount 2>/dev/null | grep -E '(k3s|kubelet|rancher|containerd)' | awk '{print $3}' || true); do
  umount -l "$mp" 2>/dev/null || true
done
echo "  ✓ 挂载点已卸载"

echo "[5/8] 删除 K3s 二进制文件..."
for bin in k3s kubectl crictl ctr k3s-killall.sh k3s-uninstall.sh k3s-agent-uninstall.sh; do
  rm -f "/usr/local/bin/$bin"
done
echo "  ✓ 二进制文件已删除"

echo "[6/8] 删除 K3s 数据目录..."
for dir in /var/lib/rancher/k3s /etc/rancher /run/k3s /var/lib/kubelet /var/lib/cni /opt/cni /etc/cni; do
  rm -rf "$dir"
done
echo "  ✓ 数据目录已删除"

echo "[7/8] 清理 systemd 服务文件..."
rm -f /etc/systemd/system/k3s.service
rm -f /etc/systemd/system/k3s-agent.service
rm -f /etc/profile.d/k3s-kubectl.sh
systemctl daemon-reload
echo "  ✓ 服务文件已清理"

echo "[8/8] 清理网络接口和 iptables..."
for iface in cni0 flannel.1 kube-ipvs0; do
  if ip link show "$iface" &>/dev/null; then
    ip link set "$iface" down 2>/dev/null || true
    ip link delete "$iface" 2>/dev/null || true
  fi
done
for table in filter nat mangle raw; do
  iptables -t "$table" -F 2>/dev/null || true
  iptables -t "$table" -X 2>/dev/null || true
done
echo "  ✓ 网络接口和 iptables 已清理"

# 清理日志
find /var/log -name "*k3s*" -type f -delete 2>/dev/null || true

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✓ K3s 节点清理完成"
echo ""
if [ "$IS_SERVER" = "true" ]; then
  echo "⚠️  请在其他控制节点补充执行（节点名: ${NODE_NAME}）:"
  echo "  kubectl delete node ${NODE_NAME}"
  echo "  kubectl delete secret -n kube-system ${NODE_NAME}.node-password.k3s"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
