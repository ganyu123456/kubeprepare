# keepalived 配置 - CloudCore VIP（备节点）
# 与主节点相同，区别: state=BACKUP, priority=99（第三节点设为 98）

global_defs {
  router_id cloudcore-backup
  vrrp_mcast_group4 224.0.0.19
  script_user root
  enable_script_security
}

vrrp_script check_cloudcore {
  script "/etc/keepalived/check_cloudcore.sh"
  interval 2
  weight  2
  fall    2
  rise    2
}

vrrp_instance CLOUDCORE {
  state  BACKUP                    # ← 备节点为 BACKUP
  interface INTERFACE_NAME         # ← 修改为实际网卡名
  virtual_router_id 167            # 与主节点一致
  priority 99                      # ← 备节点优先级低于主节点（第三节点设为 98）
  advert_int 1

  authentication {
    auth_type PASS
    auth_pass AUTH_PASSWORD        # ← 与主节点一致
  }

  virtual_ipaddress {
    VIP_ADDRESS/VIP_PREFIX         # ← 与主节点相同 VIP
  }

  track_script {
    check_cloudcore
  }
}
