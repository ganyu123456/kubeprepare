#!/usr/bin/env bash
set -euo pipefail

# PostgreSQL 卸载脚本
# ────────────────────────────────────────────────────────────
# 用途: 通过 Helm 卸载 PostgreSQL，并可选清理 PVC 和命名空间
#
# 用法:
#   ./cleanup.sh [namespace] [release-name] [--delete-pvc] [--delete-namespace]
#
# 参数:
#   namespace         命名空间（默认: postgresql）
#   release-name      Helm release 名称（默认: postgresql）
#   --delete-pvc      同时删除 PersistentVolumeClaim（数据将丢失！）
#   --delete-namespace 同时删除命名空间
#
# 示例:
#   ./cleanup.sh
#   ./cleanup.sh postgresql my-pg
#   ./cleanup.sh postgresql my-pg --delete-pvc --delete-namespace
# ────────────────────────────────────────────────────────────

NAMESPACE="${1:-postgresql}"
RELEASE_NAME="${2:-postgresql}"
DELETE_PVC=false
DELETE_NAMESPACE=false

# 解析选项
for arg in "$@"; do
  case "$arg" in
    --delete-pvc)       DELETE_PVC=true ;;
    --delete-namespace) DELETE_NAMESPACE=true ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─────────────────────────────────────────────
# 确定工具命令
# ─────────────────────────────────────────────
HELM_BIN=""
if [ -f "$SCRIPT_DIR/helm" ]; then
  HELM_BIN="$SCRIPT_DIR/helm"
elif command -v helm &>/dev/null; then
  HELM_BIN="helm"
else
  echo "❌ 错误：未找到 helm 命令"
  exit 1
fi

KUBECTL_BIN=""
if command -v kubectl &>/dev/null; then
  KUBECTL_BIN="kubectl"
elif command -v k3s &>/dev/null; then
  KUBECTL_BIN="k3s kubectl"
else
  echo "⚠️  未找到 kubectl，部分清理步骤将跳过"
fi

# ─────────────────────────────────────────────
# 确认提示
# ─────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "=== PostgreSQL 卸载 ==="
echo ""
echo "⚠️  警告：以下操作将被执行："
echo "   - 卸载 Helm release: ${RELEASE_NAME}（命名空间: ${NAMESPACE}）"
if [ "$DELETE_PVC" = true ]; then
  echo "   - ⚠️  删除所有 PVC（数据将永久丢失！）"
fi
if [ "$DELETE_NAMESPACE" = true ]; then
  echo "   - 删除命名空间: ${NAMESPACE}"
fi
echo ""

read -p "确认卸载？(y/N): " -n 1 -r REPLY || true
echo ""

if [[ ! "${REPLY:-}" =~ ^[Yy]$ ]]; then
  echo "已取消卸载"
  exit 0
fi

echo ""

# ─────────────────────────────────────────────
# 步骤 1: Helm 卸载
# ─────────────────────────────────────────────
echo "[1/3] 卸载 Helm release..."

if $HELM_BIN status "$RELEASE_NAME" -n "$NAMESPACE" &>/dev/null 2>&1; then
  $HELM_BIN uninstall "$RELEASE_NAME" -n "$NAMESPACE" --wait --timeout 5m \
    && echo "  ✓ Helm release '${RELEASE_NAME}' 已卸载" \
    || echo "  ⚠️  Helm 卸载可能未完全成功，请手动检查"
else
  echo "  ⚠️  Helm release '${RELEASE_NAME}' 不存在（命名空间: ${NAMESPACE}），跳过"
fi

# ─────────────────────────────────────────────
# 步骤 2: 删除 PVC（可选）
# ─────────────────────────────────────────────
if [ "$DELETE_PVC" = true ] && [ -n "$KUBECTL_BIN" ]; then
  echo ""
  echo "[2/3] 删除 PersistentVolumeClaim..."

  PVC_LIST=$($KUBECTL_BIN get pvc -n "$NAMESPACE" \
    -l "app.kubernetes.io/instance=${RELEASE_NAME}" \
    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)

  if [ -z "$PVC_LIST" ]; then
    # 尝试不带 label 筛选
    PVC_LIST=$($KUBECTL_BIN get pvc -n "$NAMESPACE" \
      -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
  fi

  if [ -n "$PVC_LIST" ]; then
    for pvc in $PVC_LIST; do
      $KUBECTL_BIN delete pvc "$pvc" -n "$NAMESPACE" --timeout=30s \
        && echo "  ✓ PVC 已删除: ${pvc}" \
        || echo "  ⚠️  PVC 删除失败: ${pvc}"
    done
  else
    echo "  ℹ️  命名空间 ${NAMESPACE} 中未找到 PVC"
  fi
else
  echo ""
  echo "[2/3] 跳过 PVC 删除（未指定 --delete-pvc 或未找到 kubectl）"
  if [ -n "$KUBECTL_BIN" ] && $KUBECTL_BIN get pvc -n "$NAMESPACE" &>/dev/null 2>&1; then
    PVC_COUNT=$($KUBECTL_BIN get pvc -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l)
    if [ "$PVC_COUNT" -gt 0 ]; then
      echo "  ⚠️  注意：命名空间 ${NAMESPACE} 中仍有 ${PVC_COUNT} 个 PVC（数据已保留）"
      echo "        如需删除: kubectl delete pvc -n ${NAMESPACE} --all"
    fi
  fi
fi

# ─────────────────────────────────────────────
# 步骤 3: 删除命名空间（可选）
# ─────────────────────────────────────────────
if [ "$DELETE_NAMESPACE" = true ] && [ -n "$KUBECTL_BIN" ]; then
  echo ""
  echo "[3/3] 删除命名空间: ${NAMESPACE}"
  $KUBECTL_BIN delete namespace "$NAMESPACE" --timeout=60s 2>/dev/null \
    && echo "  ✓ 命名空间 ${NAMESPACE} 已删除" \
    || echo "  ⚠️  命名空间删除失败或不存在: ${NAMESPACE}"
else
  echo ""
  echo "[3/3] 跳过命名空间删除"
fi

# ─────────────────────────────────────────────
# 完成
# ─────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "=== 卸载完成 ==="
if [ -n "$KUBECTL_BIN" ]; then
  echo ""
  echo "验证（如命名空间仍存在）:"
  echo "  ${KUBECTL_BIN} get all -n ${NAMESPACE}"
  echo ""
  echo "如需重新安装:"
  echo "  sudo ./install.sh <harbor-addr> [namespace] [release-name]"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
