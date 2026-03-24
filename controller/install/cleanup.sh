#!/usr/bin/env bash
set -euo pipefail

# K3s 控制节点清理脚本（HA 场景）
# 用途: sudo ./cleanup.sh
# 说明: 彻底卸载 k3s server，将本节点从 HA 集群中移除

if [ "$EUID" -ne 0 ]; then
  echo "错误：此脚本需要使用 root 或 sudo 运行"
  exit 1
fi

NODE_NAME=$(cat /etc/rancher/k3s/k3s.env 2>/dev/null | grep K3S_NODE_NAME | cut -d= -f2 || hostname)

echo "=== K3s 控制节点清理脚本 ==="
echo ""
echo "┌─────────────────────────────────────────────────────────────┐"
echo "│  ⚠️   etcd quorum 警告  ⚠️                                  │"
echo "│                                                             │"
echo "│  控制节点退出会影响 etcd 集群 quorum。                      │"
echo "│  运行此脚本前，请务必先在其他控制节点完成以下操作：         │"
echo "│                                                             │"
echo "│  步骤 1: 驱逐本节点上的 Pod                                 │"
echo "│    kubectl drain ${NODE_NAME} \\                          │"
echo "│      --ignore-daemonsets --delete-emptydir-data            │"
echo "│                                                             │"
echo "│  步骤 2: 从集群中删除本节点                                 │"
echo "│    kubectl delete node ${NODE_NAME}                      │"
echo "│                                                             │"
echo "│  完成以上操作后，再运行本清理脚本。                         │"
echo "│  （HA 集群至少保留 3 个控制节点中的 2 个，否则集群不可用）  │"
echo "└─────────────────────────────────────────────────────────────┘"
echo ""

REPLY=""
read -p "确认已在其他节点完成 kubectl drain 和 kubectl delete node？(y/N): " -n 1 -r || true
echo ""
if [[ ! ${REPLY:-} =~ ^[Yy]$ ]]; then
  echo "❌ 用户取消清理"
  echo "   请先在其他控制节点执行以上步骤，再重新运行此脚本"
  exit 0
fi

echo ""
REPLY=""
read -p "此操作将完全卸载 k3s server 并清除所有数据，确认继续？(y/N): " -n 1 -r || true
echo ""
if [[ ! ${REPLY:-} =~ ^[Yy]$ ]]; then
  echo "❌ 用户取消清理"
  exit 0
fi

echo ""

# =====================================
# 步骤 1: 停止并禁用 k3s 服务
# =====================================
echo "[1/6] 停止并禁用 k3s server 服务..."
systemctl stop k3s 2>/dev/null || true
systemctl disable k3s 2>/dev/null || true
echo "✓ k3s server 服务已停止"

# =====================================
# 步骤 2: 强制终止残留进程
# =====================================
echo "[2/6] 强制终止残留的 k3s / containerd-shim 进程..."
for sig in TERM KILL; do
  for proc in k3s containerd containerd-shim containerd-shim-runc-v2; do
    pkill -"$sig" -x "$proc" 2>/dev/null || true
  done
  sleep 1
done
echo "✓ 残留进程已清理"

# =====================================
# 步骤 3: 卸载 k3s 相关挂载点
# =====================================
echo "[3/6] 卸载 k3s 相关挂载点..."
for mp in $(mount 2>/dev/null | grep -oP '(?<=on )/run/k3s\S*') \
           $(mount 2>/dev/null | grep -oP '(?<=on )/var/lib/rancher/k3s\S*') \
           $(mount 2>/dev/null | grep -oP '(?<=on )/var/lib/kubelet\S*'); do
  umount -l "$mp" 2>/dev/null || true
done
echo "✓ 挂载点已卸载"

# =====================================
# 步骤 4: 删除 systemd 服务及二进制文件
# =====================================
echo "[4/6] 删除 systemd 服务及二进制文件..."
rm -f /etc/systemd/system/k3s.service
systemctl daemon-reload
rm -f /usr/local/bin/k3s
echo "✓ 服务文件和二进制已删除"

# =====================================
# 步骤 5: 清理 k3s 数据目录（含 etcd 数据）
# =====================================
echo "[5/6] 清理 k3s 数据目录（含 etcd 数据）..."

# k3s server 数据（含 etcd db、证书、token 等）
rm -rf /var/lib/rancher/k3s
rm -rf /etc/rancher/k3s
rm -rf /run/k3s

# kubelet / CNI
rm -rf /var/lib/kubelet
rm -rf /var/lib/cni
rm -rf /opt/cni/bin
rm -rf /etc/cni/net.d

# 日志
rm -f /var/log/k3s-controller-install.log

echo "✓ 数据目录已清理"

# =====================================
# 步骤 6: 清理 CNI 网络接口和命名空间
# =====================================
echo "[6/6] 清理 CNI 网络接口和命名空间..."
for iface in cni0 flannel.1 kube-ipvs0; do
  if ip link show "$iface" &>/dev/null; then
    ip link set "$iface" down 2>/dev/null || true
    ip link delete "$iface" 2>/dev/null || true
  fi
done

ip netns list 2>/dev/null | grep -E '^(cni|k3s)' | while read -r ns _; do
  ip netns delete "$ns" 2>/dev/null || true
done
echo "✓ 网络接口和命名空间已清理"

# =====================================
# 清理完成
# =====================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "=== 本节点 k3s server 已彻底卸载 ==="
echo ""
echo "⚠️  如未提前在其他节点执行 kubectl delete node，请现在补充执行："
echo ""
echo "━━━ 在其他控制节点执行（节点名: ${NODE_NAME}）━━━"
echo ""
echo "  # 删除 Kubernetes 节点对象"
echo "  kubectl delete node ${NODE_NAME} 2>/dev/null || true"
echo ""
echo "  # 删除节点密码 Secret（避免重装时 'Node authorization rejected'）"
echo "  kubectl delete secret -n kube-system ${NODE_NAME}.node-password.k3s 2>/dev/null || true"
echo ""
echo "  # 删除 k3s 本地节点密码记录（关键，kubectl 删不到）"
echo "  sed -i '/${NODE_NAME}/d' /var/lib/rancher/k3s/server/cred/node-passwd"
echo ""
echo "━━━ 验证集群健康 ━━━"
echo ""
echo "  kubectl get nodes"
echo "  # 确认剩余节点均为 Ready 状态"
echo ""
echo "  # 如部署了3个控制节点，移除1个后集群仍可正常运行（etcd 2/2 quorum）"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
