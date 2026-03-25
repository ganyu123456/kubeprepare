#!/usr/bin/env bash
# CloudCore 独立卸载脚本
#
# 用途：从 K3s 集群中完全卸载 KubeEdge CloudCore
# 用法：sudo ./uninstall-cloudcore.sh
#
# 注意：此脚本只卸载 CloudCore（云端组件），不影响：
#   - K3s 集群本身
#   - Worker 节点
#   - Edge 节点（edgecore 需单独卸载）

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "错误：此脚本需要使用 root 或 sudo 运行"
  exit 1
fi

KUBECTL="/usr/local/bin/k3s kubectl"
KUBEEDGE_VERSION="${1:-1.22.0}"
UNINSTALL_LOG="/var/log/cloudcore-uninstall.log"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee "$UNINSTALL_LOG"
echo "=== CloudCore 卸载脚本 ===" | tee -a "$UNINSTALL_LOG"
echo "时间: $(date)" | tee -a "$UNINSTALL_LOG"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee -a "$UNINSTALL_LOG"
echo "" | tee -a "$UNINSTALL_LOG"

# ⚠️  安全确认
echo "⚠️  警告：此操作将删除以下内容：" | tee -a "$UNINSTALL_LOG"
echo "   - kubeedge 命名空间及其中所有资源（CloudCore、tokensecret 等）" | tee -a "$UNINSTALL_LOG"
echo "   - KubeEdge CRD（devices、devicemodels 等）" | tee -a "$UNINSTALL_LOG"
echo "   - 本地文件：/etc/kubeedge/" | tee -a "$UNINSTALL_LOG"
echo "" | tee -a "$UNINSTALL_LOG"
echo "不受影响：" | tee -a "$UNINSTALL_LOG"
echo "   - K3s 集群、Worker 节点" | tee -a "$UNINSTALL_LOG"
echo "   - Edge 节点上的 edgecore（需单独卸载）" | tee -a "$UNINSTALL_LOG"
echo "" | tee -a "$UNINSTALL_LOG"

read -p "确认卸载 CloudCore？(y/N): " -n 1 -r REPLY || true
echo ""
if [[ ! "${REPLY:-}" =~ ^[Yy]$ ]]; then
  echo "取消卸载" | tee -a "$UNINSTALL_LOG"
  exit 0
fi

echo "" | tee -a "$UNINSTALL_LOG"

# =====================================
# 步骤 1: 检查 K3s & kubeconfig
# =====================================
echo "[1/5] 检查环境..." | tee -a "$UNINSTALL_LOG"

K3S_RUNNING=false
if systemctl is-active k3s >/dev/null 2>&1; then
  K3S_RUNNING=true
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  echo "  ✓ K3s 正在运行，将通过 kubectl 清理资源" | tee -a "$UNINSTALL_LOG"
else
  echo "  ⚠️  K3s 未运行，将跳过 kubectl 清理步骤，只清理本地文件" | tee -a "$UNINSTALL_LOG"
fi

# =====================================
# 步骤 2: 使用 keadm reset（优先）
# =====================================
echo "" | tee -a "$UNINSTALL_LOG"
echo "[2/5] 通过 keadm reset 卸载..." | tee -a "$UNINSTALL_LOG"

if [ "$K3S_RUNNING" = true ] && command -v keadm &>/dev/null; then
  if keadm reset \
    --kubeedge-version=v"$KUBEEDGE_VERSION" \
    --kube-config=/etc/rancher/k3s/k3s.yaml >> "$UNINSTALL_LOG" 2>&1; then
    echo "  ✓ keadm reset 完成" | tee -a "$UNINSTALL_LOG"
  else
    echo "  ⚠️  keadm reset 失败，继续手动清理..." | tee -a "$UNINSTALL_LOG"
  fi
else
  echo "  keadm 未安装或 K3s 未运行，跳过此步骤" | tee -a "$UNINSTALL_LOG"
fi

# =====================================
# 步骤 3: 手动清理 Kubernetes 资源
# =====================================
echo "" | tee -a "$UNINSTALL_LOG"
echo "[3/5] 清理 Kubernetes 资源..." | tee -a "$UNINSTALL_LOG"

if [ "$K3S_RUNNING" = true ] && $KUBECTL cluster-info &>/dev/null 2>&1; then

  # 删除 CloudCore Deployment 和 Pod（先优雅停止）
  if $KUBECTL -n kubeedge get deployment cloudcore &>/dev/null 2>&1; then
    $KUBECTL -n kubeedge scale deployment cloudcore --replicas=0 >> "$UNINSTALL_LOG" 2>&1 || true
    sleep 3
    $KUBECTL -n kubeedge delete deployment cloudcore --grace-period=10 >> "$UNINSTALL_LOG" 2>&1 || true
    echo "  ✓ CloudCore Deployment 已删除" | tee -a "$UNINSTALL_LOG"
  fi

  # 删除 cloud-iptables-manager DaemonSet
  if $KUBECTL -n kubeedge get daemonset cloud-iptables-manager &>/dev/null 2>&1; then
    $KUBECTL -n kubeedge delete daemonset cloud-iptables-manager --grace-period=10 >> "$UNINSTALL_LOG" 2>&1 || true
    echo "  ✓ cloud-iptables-manager DaemonSet 已删除" | tee -a "$UNINSTALL_LOG"
  fi

  # 等待 Pod 完全终止
  echo "  等待 Pod 终止..." | tee -a "$UNINSTALL_LOG"
  for i in $(seq 1 15); do
    if ! $KUBECTL -n kubeedge get pods 2>/dev/null | grep -qE "cloudcore|iptables-manager"; then
      echo "  ✓ 所有 Pod 已终止" | tee -a "$UNINSTALL_LOG"
      break
    fi
    [ "$i" -eq 15 ] && echo "  ⚠️  等待超时，强制删除..." | tee -a "$UNINSTALL_LOG" && \
      $KUBECTL -n kubeedge delete pods --all --grace-period=0 --force >> "$UNINSTALL_LOG" 2>&1 || true
    sleep 2
  done

  # 删除 kubeedge 命名空间（包含 tokensecret、configmap 等所有资源）
  if $KUBECTL get namespace kubeedge &>/dev/null 2>&1; then
    $KUBECTL delete namespace kubeedge --grace-period=10 >> "$UNINSTALL_LOG" 2>&1 || true
    echo "  ✓ kubeedge 命名空间已删除" | tee -a "$UNINSTALL_LOG"
  else
    echo "  kubeedge 命名空间不存在，跳过" | tee -a "$UNINSTALL_LOG"
  fi

  # 删除 KubeEdge CRDs
  echo "  清理 KubeEdge CRDs..." | tee -a "$UNINSTALL_LOG"
  CRD_PATTERNS=(
    "devices.devices.kubeedge.io"
    "devicemodels.devices.kubeedge.io"
    "clusterobjectsyncs.reliablesyncs.kubeedge.io"
    "objectsyncs.reliablesyncs.kubeedge.io"
    "nodeupgradejobs.operations.kubeedge.io"
    "imageprepulljobs.operations.kubeedge.io"
  )
  for crd in "${CRD_PATTERNS[@]}"; do
    if $KUBECTL get crd "$crd" &>/dev/null 2>&1; then
      $KUBECTL delete crd "$crd" >> "$UNINSTALL_LOG" 2>&1 || true
      echo "  ✓ CRD 已删除: $crd" | tee -a "$UNINSTALL_LOG"
    fi
  done

  # 删除 ClusterRoleBinding / ClusterRole
  for res in cloudcore cloud-iptables-manager; do
    $KUBECTL delete clusterrolebinding "$res" >> "$UNINSTALL_LOG" 2>&1 || true
    $KUBECTL delete clusterrole "$res" >> "$UNINSTALL_LOG" 2>&1 || true
  done
  echo "  ✓ ClusterRole/ClusterRoleBinding 已清理" | tee -a "$UNINSTALL_LOG"

else
  echo "  K3s 不可用，跳过 kubectl 清理步骤" | tee -a "$UNINSTALL_LOG"
fi

# =====================================
# 步骤 4: 清理本地文件
# =====================================
echo "" | tee -a "$UNINSTALL_LOG"
echo "[4/5] 清理本地文件..." | tee -a "$UNINSTALL_LOG"

# /etc/kubeedge（配置、token、证书）
if [ -d /etc/kubeedge ]; then
  rm -rf /etc/kubeedge
  echo "  ✓ /etc/kubeedge 已删除" | tee -a "$UNINSTALL_LOG"
fi

# keadm 二进制（可选，注释掉则保留以便重装）
if [ -f /usr/local/bin/keadm ]; then
  rm -f /usr/local/bin/keadm
  echo "  ✓ /usr/local/bin/keadm 已删除" | tee -a "$UNINSTALL_LOG"
fi

# 临时文件清理
rm -f /tmp/cloudcore-patch.yaml 2>/dev/null || true

echo "  ✓ 本地文件清理完成" | tee -a "$UNINSTALL_LOG"

# =====================================
# 步骤 5: 验证
# =====================================
echo "" | tee -a "$UNINSTALL_LOG"
echo "[5/5] 验证卸载结果..." | tee -a "$UNINSTALL_LOG"

if [ "$K3S_RUNNING" = true ]; then
  KUBEEDGE_NS=$($KUBECTL get namespace kubeedge 2>/dev/null || echo "")
  KUBEEDGE_PODS=$($KUBECTL get pods -n kubeedge 2>/dev/null || echo "")

  if [ -z "$KUBEEDGE_NS" ] && [ -z "$KUBEEDGE_PODS" ]; then
    echo "  ✓ kubeedge 命名空间已完全清理" | tee -a "$UNINSTALL_LOG"
  else
    echo "  ⚠️  仍有残留资源，请检查:" | tee -a "$UNINSTALL_LOG"
    $KUBECTL get all -n kubeedge 2>/dev/null | tee -a "$UNINSTALL_LOG" || true
  fi
fi

if [ ! -d /etc/kubeedge ]; then
  echo "  ✓ 本地文件已清理" | tee -a "$UNINSTALL_LOG"
fi

echo "" | tee -a "$UNINSTALL_LOG"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee -a "$UNINSTALL_LOG"
echo "=== CloudCore 卸载完成 ===" | tee -a "$UNINSTALL_LOG"
echo "" | tee -a "$UNINSTALL_LOG"
echo "如需重新安装，执行：" | tee -a "$UNINSTALL_LOG"
echo "  sudo ./install-cloudcore.sh <IP> [版本]" | tee -a "$UNINSTALL_LOG"
echo "卸载日志：$UNINSTALL_LOG" | tee -a "$UNINSTALL_LOG"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee -a "$UNINSTALL_LOG"
