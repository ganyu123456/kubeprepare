# keepalived 配置 - K3s API Server VIP（备节点）
# 与主节点配置相同，区别: state=BACKUP, priority=90（或 80）
#
# 使用方法:
#   同 keepalived-master.conf.tpl，但:
#   - state 改为 BACKUP
#   - priority 改为 90（第二备节点设为 80）

global_defs {
  router_id k3s-apiserver-backup
  vrrp_mcast_group4 224.0.0.18
  script_user root
  enable_script_security
}

vrrp_script check_k3s_apiserver {
  script "/etc/keepalived/check_apiserver.sh"
  interval 3
  weight -20
  fall   2
  rise   2
}

vrrp_instance K3S_APISERVER {
  state  BACKUP                    # ← 备节点为 BACKUP
  interface INTERFACE_NAME         # ← 修改为实际网卡名
  virtual_router_id 51             # 与主节点保持一致
  priority 90                      # ← 备节点优先级低于主节点（80/90/100）
  advert_int 1

  authentication {
    auth_type PASS
    auth_pass AUTH_PASSWORD        # ← 与主节点相同密码
  }

  virtual_ipaddress {
    VIP_ADDRESS/VIP_PREFIX         # ← 与主节点相同 VIP
  }

  track_script {
    check_k3s_apiserver
  }
}
