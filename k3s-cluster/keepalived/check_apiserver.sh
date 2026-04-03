#!/usr/bin/env bash
# K3s API Server 健康检查脚本（用于 keepalived track_script）
#
# 检查逻辑: 访问本地 K3s API Server /readyz 端点
# 返回 0 = 健康（keepalived 保持/获取 VIP）
# 返回 1 = 异常（keepalived 降低优先级或释放 VIP）

HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" \
  --max-time 3 \
  https://127.0.0.1:6443/readyz 2>/dev/null || echo "000")

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "401" ]; then
  # 200 = 正常就绪; 401 = 未认证但 API Server 在线（也认为健康）
  exit 0
else
  exit 1
fi
