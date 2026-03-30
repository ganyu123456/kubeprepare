#!/usr/bin/env bash
set -euo pipefail

# Redis 镜像导入/推送脚本
# ────────────────────────────────────────────────────────────
# 用途:
#   从离线包中的 images/ 目录加载所有容器镜像，
#   重新打标签并推送到私有 Harbor 仓库。
#
# 用法:
#   ./load-images.sh <harbor-addr> [harbor-user] [harbor-password]
#
# 参数:
#   harbor-addr      Harbor 镜像仓库地址（必填），例如: harbor.example.com
#   harbor-user      Harbor 用户名（选填，默认: admin）
#   harbor-password  Harbor 密码（选填，若不填则跳过登录）
#
# 示例:
#   ./load-images.sh harbor.example.com
#   ./load-images.sh harbor.example.com admin Harbor12345
#
# 环境变量（可替代命令行参数）:
#   HARBOR_USERNAME   Harbor 用户名
#   HARBOR_PASS       Harbor 密码
#
# 说明:
#   - 自动检测容器运行时（docker 优先，其次 nerdctl）
#   - 镜像推送目标: harbor-addr/library/<image-name>:<tag>
#   - 推送规则来自 images/manifest.jsonl
#   - 镜像 tar 文件已包含完整镜像层，无需网络访问
# ────────────────────────────────────────────────────────────

HARBOR_ADDR="${1:-}"
HARBOR_USER="${2:-${HARBOR_USERNAME:-admin}}"
HARBOR_PASSWORD="${3:-${HARBOR_PASS:-}}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGES_DIR="$SCRIPT_DIR/images"
MANIFEST_FILE="$IMAGES_DIR/manifest.jsonl"
LOG_FILE="/tmp/redis-load-images-$(date +%Y%m%d%H%M%S).log"

# ─────────────────────────────────────────────
# 工具函数
# ─────────────────────────────────────────────
log()  { echo "$*" | tee -a "$LOG_FILE"; }
ok()   { echo "  ✓ $*" | tee -a "$LOG_FILE"; }
warn() { echo "  ⚠️  $*" | tee -a "$LOG_FILE"; }
fail() { echo "  ❌ $*" | tee -a "$LOG_FILE"; exit 1; }

# ─────────────────────────────────────────────
# 参数校验
# ─────────────────────────────────────────────
if [ -z "$HARBOR_ADDR" ]; then
  echo "错误：缺少 Harbor 地址"
  echo "用法: $0 <harbor-addr> [harbor-user] [harbor-password]"
  exit 1
fi

if [ ! -f "$MANIFEST_FILE" ]; then
  fail "未找到镜像 manifest 文件: $MANIFEST_FILE"
fi

# ─────────────────────────────────────────────
# 检测容器运行时
# ─────────────────────────────────────────────
RUNTIME=""
if command -v docker &>/dev/null; then
  RUNTIME="docker"
elif command -v nerdctl &>/dev/null; then
  RUNTIME="nerdctl"
else
  fail "未找到 docker 或 nerdctl，无法加载镜像"
fi

log "=== Redis 镜像导入/推送 ==="
log "Harbor 地址:    ${HARBOR_ADDR}"
log "Harbor 用户:    ${HARBOR_USER}"
log "容器运行时:     ${RUNTIME}"
log "镜像目录:       ${IMAGES_DIR}"
log "Manifest:       ${MANIFEST_FILE}"
log "日志文件:       ${LOG_FILE}"
log ""

# ─────────────────────────────────────────────
# Harbor 登录
# ─────────────────────────────────────────────
if [ -n "$HARBOR_PASSWORD" ]; then
  log "登录 Harbor: ${HARBOR_ADDR}"
  echo "$HARBOR_PASSWORD" | $RUNTIME login "$HARBOR_ADDR" \
    -u "$HARBOR_USER" --password-stdin 2>&1 | sed 's/^/  /' | tee -a "$LOG_FILE" \
    && ok "登录成功" \
    || warn "登录失败，将尝试继续（如 Harbor 已配置 insecure-registries 可忽略）"
  log ""
else
  log "  未提供 Harbor 密码，跳过登录（请确保已预先登录或 Harbor 允许匿名访问）"
  log ""
fi

# ─────────────────────────────────────────────
# 解析 manifest 并加载/推送每个镜像
# ─────────────────────────────────────────────
log "=== 开始处理镜像 ==="
log ""

TOTAL=0
LOADED=0
PUSHED=0
FAILED=0

# 先统计总数
while IFS= read -r line; do
  [ -z "${line// }" ] && continue
  TOTAL=$((TOTAL + 1))
done < "$MANIFEST_FILE"
log "共 ${TOTAL} 个镜像需要处理"
log ""

INDEX=0
while IFS= read -r line; do
  [ -z "${line// }" ] && continue

  INDEX=$((INDEX + 1))

  # 解析 JSON 字段（使用 python3 保证特殊字符安全）
  TAR=$(python3 -c "import sys,json;d=json.loads(sys.argv[1]);print(d['tar'])" "$line" 2>/dev/null) || {
    warn "无法解析 manifest 行: $line"
    FAILED=$((FAILED + 1))
    continue
  }
  SOURCE=$(python3 -c "import sys,json;d=json.loads(sys.argv[1]);print(d['source'])" "$line" 2>/dev/null)
  HARBOR_PATH=$(python3 -c "import sys,json;d=json.loads(sys.argv[1]);print(d['harbor_path'])" "$line" 2>/dev/null)

  TAR_FILE="$IMAGES_DIR/$TAR"
  HARBOR_IMAGE="${HARBOR_ADDR}/${HARBOR_PATH}"

  log "── [${INDEX}/${TOTAL}] ${SOURCE}"
  log "            → ${HARBOR_IMAGE}"

  # 检查 tar 文件是否存在
  if [ ! -f "$TAR_FILE" ]; then
    warn "tar 文件不存在，跳过: $TAR_FILE"
    FAILED=$((FAILED + 1))
    continue
  fi

  TAR_SIZE=$(du -h "$TAR_FILE" | cut -f1)
  log "   tar 文件: $TAR (${TAR_SIZE})"

  # ── 1. 加载镜像 ──────────────────────────────────
  log "   加载中..."
  if ! LOAD_OUTPUT=$($RUNTIME load -i "$TAR_FILE" 2>&1); then
    warn "镜像加载失败: $TAR"
    log "   错误: $LOAD_OUTPUT"
    FAILED=$((FAILED + 1))
    continue
  fi
  LOADED=$((LOADED + 1))
  log "   已加载: $LOAD_OUTPUT"

  # ── 2. 重新打标签 ────────────────────────────────
  if ! $RUNTIME tag "$SOURCE" "$HARBOR_IMAGE" 2>/dev/null; then
    # 尝试从 load 输出中获取实际 image 名
    LOADED_IMAGE=$(echo "$LOAD_OUTPUT" | grep -oP '(?<=Loaded image: ).*' | head -1 || true)
    if [ -n "$LOADED_IMAGE" ] && [ "$LOADED_IMAGE" != "$SOURCE" ]; then
      log "   使用 load 输出的镜像名重新标签: $LOADED_IMAGE"
      $RUNTIME tag "$LOADED_IMAGE" "$HARBOR_IMAGE" 2>/dev/null || {
        warn "重新标签失败（原: $SOURCE → Harbor: $HARBOR_IMAGE）"
        FAILED=$((FAILED + 1))
        continue
      }
    else
      warn "重新标签失败: $SOURCE → $HARBOR_IMAGE"
      FAILED=$((FAILED + 1))
      continue
    fi
  fi

  # ── 3. 推送到 Harbor ────────────────────────────
  log "   推送中..."
  if $RUNTIME push "$HARBOR_IMAGE" 2>&1 | tail -5 | sed 's/^/   /'; then
    PUSHED=$((PUSHED + 1))
    ok "推送成功: ${HARBOR_IMAGE}"
  else
    warn "推送失败: ${HARBOR_IMAGE}"
    log "   提示: 请检查 Harbor 地址是否正确，以及 library 项目是否存在"
    FAILED=$((FAILED + 1))
  fi

  log ""
done < "$MANIFEST_FILE"

# ─────────────────────────────────────────────
# 打印摘要
# ─────────────────────────────────────────────
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "=== 镜像处理完成 ==="
log "  总计:     ${TOTAL} 个"
log "  已加载:   ${LOADED} 个"
log "  已推送:   ${PUSHED} 个"
log "  失败:     ${FAILED} 个"
log ""
log "Harbor 镜像地址汇总:"
while IFS= read -r line; do
  [ -z "${line// }" ] && continue
  HARBOR_PATH=$(python3 -c "import sys,json;d=json.loads(sys.argv[1]);print(d['harbor_path'])" "$line" 2>/dev/null) || continue
  log "  ${HARBOR_ADDR}/${HARBOR_PATH}"
done < "$MANIFEST_FILE"
log ""
log "日志文件: ${LOG_FILE}"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 如果有失败，退出码为 1
[ "$FAILED" -gt 0 ] && exit 1 || exit 0
