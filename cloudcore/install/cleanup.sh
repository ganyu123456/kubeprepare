#!/usr/bin/env bash
set -euo pipefail

# CloudCore HA 清理脚本
# 用途：从 K3s 集群中卸载 CloudCore 及相关组件
# 说明：不会影响 K3s 集群本身，仅清理 KubeEdge 相关资源

if [ "$EUID" -ne 0 ]; then
  echo "错误：请使用 root 或 sudo 运行此脚本"
  exit 1
fi

FORCE="${1:-}"
KUBECTL="/usr/local/bin/k3s kubectl"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "=== CloudCore HA 清理脚本 ==="
echo ""
echo "  ⚠️  此操作将清理所有 KubeEdge 组件："
echo "     - CloudCore Deployment"
echo "     - KubeEdge Controller Manager"
echo "     - kubeedge 命名空间所有资源"
echo "     - KubeEdge CRDs"
echo "     - keadm 二进制文件"
echo ""

if [ "$FORCE" != "--force" ]; then
  read -p "确认继续？(y/N): " -n 1 -r || true
  echo ""
  if [[ ! ${REPLY:-} =~ ^[Yy]$ ]]; then
    echo "❌ 用户取消"
    exit 0
  fi
fi

echo ""

# 1. 优雅删除 K8s 资源
echo "[1/6] 优雅删除 KubeEdge K8s 资源..."
if $KUBECTL cluster-info &>/dev/null 2>&1; then
  # 卸载 EdgeMesh
  if command -v helm &>/dev/null && helm status edgemesh -n kubeedge &>/dev/null 2>&1; then
    helm uninstall edgemesh -n kubeedge --timeout=60s 2>/dev/null || true
    echo "  ✓ EdgeMesh 已卸载"
  fi

  # 删除 Controller Manager
  $KUBECTL delete deployment kubeedge-controller-manager -n kubeedge --timeout=30s 2>/dev/null || true
  $KUBECTL delete clusterrolebinding kubeedge-controller-manager 2>/dev/null || true
  $KUBECTL delete clusterrole kubeedge-controller-manager 2>/dev/null || true
  $KUBECTL delete serviceaccount kubeedge-controller-manager -n kubeedge 2>/dev/null || true
  echo "  ✓ Controller Manager 已删除"

  # 删除 CloudCore
  $KUBECTL delete deployment cloudcore -n kubeedge --timeout=30s 2>/dev/null || true
  $KUBECTL delete service cloudcore -n kubeedge 2>/dev/null || true
  $KUBECTL delete configmap cloudcore -n kubeedge 2>/dev/null || true
  $KUBECTL delete secret cloudcore -n kubeedge 2>/dev/null || true
  echo "  ✓ CloudCore 资源已删除"

  # 删除 Istio CRDs
  $KUBECTL delete crd virtualservices.networking.istio.io 2>/dev/null || true
  $KUBECTL delete crd destinationrules.networking.istio.io 2>/dev/null || true
  $KUBECTL delete crd gateways.networking.istio.io 2>/dev/null || true

  # 删除 kubeedge 命名空间
  $KUBECTL delete namespace kubeedge --timeout=60s 2>/dev/null || true
  echo "  ✓ kubeedge 命名空间已删除"
else
  echo "  ⚠️  K3s API 不可访问，跳过资源清理"
fi

# 2. 删除二进制文件
echo "[2/6] 删除 KubeEdge 二进制文件..."
rm -f /usr/local/bin/keadm
rm -f /usr/local/bin/cloudcore
echo "  ✓ 二进制文件已删除"

# 3. 删除证书和配置目录
echo "[3/6] 删除 KubeEdge 证书和配置..."
rm -rf /etc/kubeedge
rm -rf /var/lib/kubeedge
rm -rf /var/log/kubeedge
echo "  ✓ 证书和配置已删除"

# 4. 清理 iptables 规则（CloudStream NAT）
echo "[4/6] 清理 iptables 规则..."
iptables -t nat -D OUTPUT -p tcp --dport 10350 \
  -j DNAT --to-destination 127.0.0.1:10003 2>/dev/null || true
echo "  ✓ iptables 规则已清理"

# 5. 停止并删除 keepalived（仅 CloudCore 用途的）
echo "[5/6] 处理 keepalived..."
if systemctl is-active --quiet keepalived 2>/dev/null; then
  echo "  ⚠️  keepalived 正在运行，如果是专用于 CloudCore VIP，请手动停止:"
  echo "     systemctl stop keepalived && systemctl disable keepalived"
fi
echo "  ✓ keepalived 处理完成"

# 6. 清理日志
echo "[6/6] 清理日志..."
rm -f /var/log/cloudcore-ha-install.log
rm -f /var/log/cloudcore-install.log
echo "  ✓ 日志已清理"

systemctl daemon-reload

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✓ CloudCore HA 清理完成"
echo ""
echo "K3s 集群本身未受影响，可重新运行 install.sh 安装 CloudCore HA。"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
