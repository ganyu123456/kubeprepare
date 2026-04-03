# keepalived 配置 - K3s API Server VIP（主节点）
# 用途: 为 K3s 多控制节点提供稳定的 API Server 访问入口
#
# 使用方法:
#   1. 将此文件复制到 /etc/keepalived/keepalived.conf
#   2. 将 check_apiserver.sh 复制到 /etc/keepalived/check_apiserver.sh
#   3. 修改以下占位符:
#      - INTERFACE_NAME    → 网卡名（如 eth0、ens3、bond0）
#      - VIP_ADDRESS       → 虚拟 IP 地址（如 192.168.1.100）
#      - VIP_PREFIX        → 子网掩码位数（如 24 代表 /24）
#      - AUTH_PASSWORD     → VRRP 认证密码（所有节点保持一致）
#   4. 主节点 state 为 MASTER，priority 为 100
#   5. systemctl enable keepalived && systemctl start keepalived

global_defs {
  router_id k3s-apiserver-master
  vrrp_mcast_group4 224.0.0.18
  script_user root
  enable_script_security
}

# K3s API Server 健康检查脚本
vrrp_script check_k3s_apiserver {
  script "/etc/keepalived/check_apiserver.sh"
  interval 3      # 每 3 秒检查一次
  weight -20      # 检查失败时降低优先级 20
  fall   2        # 连续失败 2 次才认为宕机
  rise   2        # 连续成功 2 次才认为恢复
}

vrrp_instance K3S_APISERVER {
  state  MASTER
  interface INTERFACE_NAME         # ← 修改为实际网卡名（如 eth0）
  virtual_router_id 51             # 同一 VIP 组内所有节点必须相同，范围 1-255
  priority 100                     # 主节点优先级最高（备节点设为 90/80）
  advert_int 1

  authentication {
    auth_type PASS
    auth_pass AUTH_PASSWORD        # ← 修改为自定义密码（所有节点一致）
  }

  virtual_ipaddress {
    VIP_ADDRESS/VIP_PREFIX         # ← 修改为实际 VIP（如 192.168.1.100/24）
  }

  track_script {
    check_k3s_apiserver
  }

  # VIP 切换时通知（可选）
  # notify_master "/etc/keepalived/notify.sh MASTER"
  # notify_backup "/etc/keepalived/notify.sh BACKUP"
  # notify_fault  "/etc/keepalived/notify.sh FAULT"
}
