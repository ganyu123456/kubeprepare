#!/usr/bin/env bash
set -euo pipefail

# Redis 离线安装脚本
# ────────────────────────────────────────────────────────────
# 用途:
#   在纯离线环境中一键安装 Redis：
#     1. 将容器镜像推送到私有 Harbor（library 项目）
#     2. 将 Helm chart 推送到 Harbor OCI 仓库（charts 项目）
#        （或直接使用本地 chart tgz，无需推送）
#     3. 通过 Helm 安装 Redis
#
# 用法:
#   sudo ./install.sh <harbor-addr> [chart-repo-addr] [namespace] [release-name]
#
# 参数:
#   harbor-addr       Harbor 镜像仓库地址（必填）
#                     镜像将推送至: harbor-addr/library/<image-name>:<tag>
#   chart-repo-addr   Chart 仓库地址（选填，默认与 harbor-addr 相同）
#                     Chart 将推送至: oci://chart-repo-addr/charts
#   namespace         Kubernetes 命名空间（选填，默认: redis）
#   release-name      Helm release 名称（选填，默认: redis）
#
# 示例:
#   sudo ./install.sh harbor.example.com
#   sudo ./install.sh harbor.example.com harbor.example.com redis my-redis
#
# 支持两种安装模式（由脚本自动选择）:
#   模式A（推荐）: 推送 chart → Harbor OCI，helm install 从 Harbor 拉取
#   模式B（备用）: 直接 helm install 本地 charts/ 目录中的 tgz
# ────────────────────────────────────────────────────────────

if [ "$EUID" -ne 0 ]; then
  echo "错误：此脚本需要 root 权限运行（sudo ./install.sh ...）"
  exit 1
fi

HARBOR_ADDR="${1:-}"
CHART_REPO_ADDR="${2:-${1:-}}"
NAMESPACE="${3:-redis}"
RELEASE_NAME="${4:-redis}"
CHART_VERSION="23.1.1"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_LOG="/var/log/redis-install.log"

# ─────────────────────────────────────────────
# 工具函数
# ─────────────────────────────────────────────
log()  { echo "$*" | tee -a "$INSTALL_LOG"; }
info() { echo "  $*" | tee -a "$INSTALL_LOG"; }
ok()   { echo "  ✓ $*" | tee -a "$INSTALL_LOG"; }
warn() { echo "  ⚠️  $*" | tee -a "$INSTALL_LOG"; }
fail() { echo "  ❌ $*" | tee -a "$INSTALL_LOG"; exit 1; }

# ─────────────────────────────────────────────
# 参数校验
# ─────────────────────────────────────────────
if [ -z "$HARBOR_ADDR" ]; then
  echo "错误：缺少 Harbor 地址参数"
  echo ""
  echo "用法: $0 <harbor-addr> [chart-repo-addr] [namespace] [release-name]"
  echo ""
  echo "示例: $0 harbor.example.com harbor.example.com redis redis"
  exit 1
fi

# ─────────────────────────────────────────────
# 打印安装信息
# ─────────────────────────────────────────────
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "=== Redis 离线安装 ==="
log "时间:           $(date)"
log "Harbor 地址:    ${HARBOR_ADDR}"
log "Chart 仓库:     ${CHART_REPO_ADDR}"
log "命名空间:       ${NAMESPACE}"
log "Release 名称:   ${RELEASE_NAME}"
log "Chart 版本:     ${CHART_VERSION}"
log "脚本目录:       ${SCRIPT_DIR}"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log ""

# ─────────────────────────────────────────────
# 步骤 1: 检查前置条件
# ─────────────────────────────────────────────
log "[1/5] 检查前置条件..."

# 确定 helm 命令（优先用包内 helm，其次系统 helm）
HELM_BIN=""
if [ -f "$SCRIPT_DIR/helm" ]; then
  HELM_BIN="$SCRIPT_DIR/helm"
  ok "使用离线包内 helm: $HELM_BIN ($(${HELM_BIN} version --short 2>/dev/null))"
elif command -v helm &>/dev/null; then
  HELM_BIN="helm"
  ok "使用系统 helm: $(command -v helm) ($(helm version --short 2>/dev/null))"
else
  fail "未找到 helm，离线包应内含 helm 二进制，请检查包完整性"
fi

# 确定 kubectl 命令
KUBECTL_BIN=""
if command -v kubectl &>/dev/null; then
  KUBECTL_BIN="kubectl"
  ok "kubectl: $(command -v kubectl)"
elif command -v k3s &>/dev/null; then
  KUBECTL_BIN="k3s kubectl"
  ok "kubectl (k3s): k3s kubectl"
else
  warn "未找到 kubectl，后续验证步骤将跳过"
fi

# 确定容器运行时（用于镜像导入和 Harbor 推送）
RUNTIME=""
if command -v docker &>/dev/null; then
  RUNTIME="docker"
  ok "容器运行时: docker ($(docker --version 2>/dev/null))"
elif command -v nerdctl &>/dev/null; then
  RUNTIME="nerdctl"
  ok "容器运行时: nerdctl"
else
  warn "未找到 docker 或 nerdctl，将跳过镜像推送步骤（仅安装 chart）"
fi

# 检查必要目录/文件
for item in "charts" "images" "images/manifest.jsonl" "values-offline.yaml.tpl"; do
  if [ ! -e "$SCRIPT_DIR/$item" ]; then
    fail "离线包文件不完整，缺少: $SCRIPT_DIR/$item"
  fi
done
ok "离线包文件完整性检查通过"

# 检查 chart 文件
CHART_TGZ=$(ls "$SCRIPT_DIR/charts/redis-${CHART_VERSION}.tgz" 2>/dev/null | head -1 || \
            ls "$SCRIPT_DIR/charts/"*.tgz 2>/dev/null | head -1)
if [ -z "$CHART_TGZ" ]; then
  fail "未找到 chart tgz 文件: $SCRIPT_DIR/charts/"
fi
ok "chart 文件: $(basename "$CHART_TGZ")"

# ─────────────────────────────────────────────
# 步骤 2: Harbor 登录
# ─────────────────────────────────────────────
log ""
log "[2/5] 配置 Harbor 访问..."

HARBOR_USER="admin"
HARBOR_PASSWORD=""

# 支持环境变量传入（适合自动化场景）
if [ -n "${HARBOR_USERNAME:-}" ]; then
  HARBOR_USER="$HARBOR_USERNAME"
fi
if [ -n "${HARBOR_PASS:-}" ]; then
  HARBOR_PASSWORD="$HARBOR_PASS"
fi

# 交互式输入（如未从环境变量获取）
if [ -z "$HARBOR_PASSWORD" ]; then
  echo ""
  info "请输入 Harbor 登录凭据（按 Enter 使用默认值，Ctrl+C 跳过登录）:"
  read -p "  Harbor 用户名 (默认: admin): " INPUT_USER || true
  [ -n "${INPUT_USER:-}" ] && HARBOR_USER="$INPUT_USER"
  read -s -p "  Harbor 密码: " HARBOR_PASSWORD || true
  echo ""
fi

if [ -n "$HARBOR_PASSWORD" ] && [ -n "$RUNTIME" ]; then
  info "登录 Docker registry: ${HARBOR_ADDR}"
  echo "$HARBOR_PASSWORD" | $RUNTIME login "$HARBOR_ADDR" \
    -u "$HARBOR_USER" --password-stdin 2>&1 | sed 's/^/    /' \
    && ok "Docker 登录成功" \
    || warn "Docker 登录失败（将尝试继续，如 Harbor 允许匿名 pull 可忽略）"

  info "登录 Helm OCI registry: ${CHART_REPO_ADDR}"
  $HELM_BIN registry login "$CHART_REPO_ADDR" \
    -u "$HARBOR_USER" -p "$HARBOR_PASSWORD" 2>&1 | sed 's/^/    /' \
    && ok "Helm registry 登录成功" \
    || warn "Helm registry 登录失败（chart 推送步骤可能失败）"
else
  warn "未输入 Harbor 密码或无可用容器运行时，跳过登录"
fi

# ─────────────────────────────────────────────
# 步骤 3: 加载镜像并推送到 Harbor
# ─────────────────────────────────────────────
log ""
log "[3/5] 加载镜像并推送到 Harbor..."

if [ -z "$RUNTIME" ]; then
  warn "无可用容器运行时，跳过镜像推送，请手动推送镜像到 Harbor"
else
  LOAD_SCRIPT="$SCRIPT_DIR/load-images.sh"
  if [ ! -f "$LOAD_SCRIPT" ]; then
    warn "未找到 load-images.sh，尝试内联执行镜像加载..."
    # 内联镜像加载逻辑（兜底）
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      TAR=$(echo "$line" | python3 -c "import sys,json;d=json.loads(sys.stdin.read());print(d['tar'])")
      SRC=$(echo "$line" | python3 -c "import sys,json;d=json.loads(sys.stdin.read());print(d['source'])")
      HARBOR_PATH=$(echo "$line" | python3 -c "import sys,json;d=json.loads(sys.stdin.read());print(d['harbor_path'])")
      TAR_FILE="$SCRIPT_DIR/images/$TAR"
      [ -f "$TAR_FILE" ] || continue
      $RUNTIME load -i "$TAR_FILE" 2>/dev/null || continue
      $RUNTIME tag "$SRC" "${HARBOR_ADDR}/${HARBOR_PATH}" 2>/dev/null || continue
      $RUNTIME push "${HARBOR_ADDR}/${HARBOR_PATH}" 2>/dev/null \
        && ok "推送成功: ${HARBOR_ADDR}/${HARBOR_PATH}" \
        || warn "推送失败: ${HARBOR_ADDR}/${HARBOR_PATH}"
    done < "$SCRIPT_DIR/images/manifest.jsonl"
  else
    bash "$LOAD_SCRIPT" "$HARBOR_ADDR" "$HARBOR_USER" "$HARBOR_PASSWORD" 2>&1 \
      | sed 's/^/  /' | tee -a "$INSTALL_LOG"
    ok "镜像加载/推送完成"
  fi
fi

# ─────────────────────────────────────────────
# 步骤 4: 推送 Chart 到 Harbor OCI 仓库
# ─────────────────────────────────────────────
log ""
log "[4/5] 推送 Chart 到 Harbor OCI 仓库 (oci://${CHART_REPO_ADDR}/charts)..."

CHART_PUSH_SUCCESS=false
for chart_tgz in "$SCRIPT_DIR/charts/"*.tgz; do
  chart_basename=$(basename "$chart_tgz")
  info "推送: ${chart_basename} → oci://${CHART_REPO_ADDR}/charts"
  if $HELM_BIN push "$chart_tgz" "oci://${CHART_REPO_ADDR}/charts" 2>&1 | sed 's/^/    /'; then
    ok "推送成功: ${chart_basename}"
    CHART_PUSH_SUCCESS=true
  else
    warn "推送失败: ${chart_basename}（可能已存在，将使用本地 tgz 安装）"
  fi
done

# ─────────────────────────────────────────────
# 步骤 5: 安装 Redis
# ─────────────────────────────────────────────
log ""
log "[5/5] 安装 Redis..."

# 生成 values-offline.yaml（替换 HARBOR_ADDR 占位符）
VALUES_TPL="$SCRIPT_DIR/values-offline.yaml.tpl"
VALUES_FINAL="/tmp/redis-values-offline-$(date +%s).yaml"

if [ -f "$VALUES_TPL" ]; then
  sed "s|HARBOR_ADDR|${HARBOR_ADDR}|g" "$VALUES_TPL" > "$VALUES_FINAL"
  ok "生成 values-offline.yaml（Harbor: ${HARBOR_ADDR}）"
else
  # 兜底：生成最简 values
  warn "未找到 values-offline.yaml.tpl，使用最简 values"
  cat > "$VALUES_FINAL" << EOF
image:
  registry: ${HARBOR_ADDR}
  repository: library/redis
  pullPolicy: IfNotPresent
sentinel:
  image:
    registry: ${HARBOR_ADDR}
    repository: library/redis-sentinel
    pullPolicy: IfNotPresent
volumePermissions:
  image:
    registry: ${HARBOR_ADDR}
    repository: library/os-shell
    pullPolicy: IfNotPresent
metrics:
  image:
    registry: ${HARBOR_ADDR}
    repository: library/redis-exporter
    pullPolicy: IfNotPresent
master:
  persistence:
    enabled: true
    size: 8Gi
EOF
fi

# 叠加自定义 values（如果 values/ 目录下有自定义文件）
EXTRA_VALUES_ARGS=""
VALUES_DIR="$SCRIPT_DIR/values"
if [ -d "$VALUES_DIR" ]; then
  for vf in "$VALUES_DIR"/*.yaml "$VALUES_DIR"/*.yml; do
    [ -f "$vf" ] || continue
    EXTRA_VALUES_ARGS="$EXTRA_VALUES_ARGS -f $vf"
    info "叠加自定义 values: $(basename "$vf")"
  done
fi

# 创建命名空间
if [ -n "$KUBECTL_BIN" ]; then
  $KUBECTL_BIN create namespace "$NAMESPACE" 2>/dev/null \
    && info "命名空间 ${NAMESPACE} 已创建" \
    || info "命名空间 ${NAMESPACE} 已存在"
fi

# ── 安装：优先从 Harbor OCI，回退到本地 tgz ──────────────
INSTALL_SUCCESS=false

if [ "$CHART_PUSH_SUCCESS" = true ]; then
  info "模式A：从 Harbor OCI 仓库安装 (oci://${CHART_REPO_ADDR}/charts/redis)"
  # shellcheck disable=SC2086
  if $HELM_BIN install "$RELEASE_NAME" \
      "oci://${CHART_REPO_ADDR}/charts/redis" \
      --version "${CHART_VERSION}" \
      --namespace "$NAMESPACE" \
      --create-namespace \
      -f "$VALUES_FINAL" \
      $EXTRA_VALUES_ARGS \
      --wait --timeout 10m \
      2>&1 | sed 's/^/  /'; then
    INSTALL_SUCCESS=true
  else
    warn "从 Harbor OCI 安装失败，尝试模式B（本地 chart tgz）"
  fi
fi

if [ "$INSTALL_SUCCESS" = false ]; then
  info "模式B：从本地 chart tgz 安装"
  MAIN_CHART=$(ls -S "$SCRIPT_DIR/charts/redis-"*.tgz 2>/dev/null | head -1)
  if [ -z "$MAIN_CHART" ]; then
    MAIN_CHART=$(ls "$SCRIPT_DIR/charts/"*.tgz 2>/dev/null | head -1)
  fi
  [ -z "$MAIN_CHART" ] && fail "未找到可用的 chart 文件"

  info "使用 chart: $(basename "$MAIN_CHART")"
  # shellcheck disable=SC2086
  if $HELM_BIN install "$RELEASE_NAME" "$MAIN_CHART" \
      --namespace "$NAMESPACE" \
      --create-namespace \
      -f "$VALUES_FINAL" \
      $EXTRA_VALUES_ARGS \
      --wait --timeout 10m \
      2>&1 | sed 's/^/  /'; then
    INSTALL_SUCCESS=true
  else
    fail "Redis 安装失败，请检查以上错误日志"
  fi
fi

# ─────────────────────────────────────────────
# 安装完成
# ─────────────────────────────────────────────
log ""
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "=== Redis 安装完成 ==="
log "命名空间:  ${NAMESPACE}"
log "Release:   ${RELEASE_NAME}"
log "版本:      ${CHART_VERSION}"
log ""
log "=== 常用命令 ==="
if [ -n "$KUBECTL_BIN" ]; then
  log "查看 Pod 状态:"
  log "  ${KUBECTL_BIN} get pods -n ${NAMESPACE}"
  log ""
  log "查看服务:"
  log "  ${KUBECTL_BIN} get svc -n ${NAMESPACE}"
  log ""
  log "获取 Redis 密码:"
  log "  ${KUBECTL_BIN} get secret -n ${NAMESPACE} ${RELEASE_NAME} \\"
  log "    -o jsonpath='{.data.redis-password}' | base64 -d && echo"
  log ""
  log "连接到 Redis:"
  log "  ${KUBECTL_BIN} run -it --rm redis-cli --image=${HARBOR_ADDR}/library/redis:* \\"
  log "    -- redis-cli -h ${RELEASE_NAME}-master.${NAMESPACE}.svc"
fi
log ""
log "卸载:"
log "  ./cleanup.sh ${NAMESPACE} ${RELEASE_NAME}"
log ""
log "安装日志: ${INSTALL_LOG}"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
