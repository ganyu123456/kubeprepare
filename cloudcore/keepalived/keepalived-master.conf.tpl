# keepalived 配置 - CloudCore VIP（主节点）
# 用途: 为 CloudCore 多副本提供稳定的 VIP，边缘节点始终连接此 VIP
#
# 使用方法:
#   1. 复制到 /etc/keepalived/keepalived.conf
#   2. 复制 check_cloudcore.sh 到 /etc/keepalived/check_cloudcore.sh
#   3. 替换占位符（INTERFACE_NAME、VIP_ADDRESS、VIP_PREFIX、AUTH_PASSWORD）
#   4. systemctl enable keepalived && systemctl start keepalived

global_defs {
  router_id cloudcore-master
  vrrp_mcast_group4 224.0.0.19
  script_user root
  enable_script_security
}

vrrp_script check_cloudcore {
  script "/etc/keepalived/check_cloudcore.sh"
  interval 2      # 每 2 秒检查
  weight  2
  fall    2       # 连续失败 2 次认为宕机
  rise    2       # 连续成功 2 次认为恢复
}

vrrp_instance CLOUDCORE {
  state  MASTER
  interface INTERFACE_NAME         # ← 修改为实际网卡名（如 eth0）
  virtual_router_id 167            # 同一 VIP 组内所有节点必须相同
  priority 100                     # 主节点最高
  advert_int 1

  authentication {
    auth_type PASS
    auth_pass AUTH_PASSWORD        # ← 修改（所有节点一致）
  }

  virtual_ipaddress {
    VIP_ADDRESS/VIP_PREFIX         # ← 修改为 CloudCore VIP（如 192.168.1.200/24）
  }

  track_script {
    check_cloudcore
  }
}
