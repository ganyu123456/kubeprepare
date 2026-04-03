#!/usr/bin/env bash
# CloudCore 健康检查脚本（用于 keepalived track_script）
#
# 检查本机 CloudCore 的 /readyz 端点
# 返回 0 = 健康，1 = 异常

HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" \
  --max-time 3 \
  https://127.0.0.1:10002/readyz 2>/dev/null || echo "000")

if [ "$HTTP_CODE" = "200" ]; then
  exit 0
else
  exit 1
fi
