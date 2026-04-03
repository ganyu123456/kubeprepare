# K3s API Server VIP 配置（keepalived）

keepalived 为 K3s 多控制节点集群提供稳定的 API Server VIP，确保 kubectl 和 CloudCore 始终能连接到可用的 API Server。

## 快速配置

### 1. 安装 keepalived

```bash
# Ubuntu/Debian
apt-get install -y keepalived

# CentOS/RHEL
yum install -y keepalived
```

### 2. 规划 VIP 和节点优先级

| 节点 | 角色 | priority | state |
|------|------|----------|-------|
| k3s-server-01 | MASTER | 100 | MASTER |
| k3s-server-02 | BACKUP | 90 | BACKUP |
| k3s-server-03 | BACKUP | 80 | BACKUP |

### 3. 配置主节点

```bash
# 复制主节点配置（在 k3s-server-01 执行）
cp keepalived-master.conf.tpl /etc/keepalived/keepalived.conf
cp check_apiserver.sh /etc/keepalived/check_apiserver.sh
chmod +x /etc/keepalived/check_apiserver.sh

# 编辑配置，替换以下占位符
# INTERFACE_NAME → 执行 ip route | grep default | awk '{print $5}' 获取网卡名
# VIP_ADDRESS    → 如 192.168.1.100
# VIP_PREFIX     → 如 24
# AUTH_PASSWORD  → 自定义密码（所有节点一致）
vi /etc/keepalived/keepalived.conf
```

### 4. 配置备节点

```bash
# 在 k3s-server-02 执行（priority=90），k3s-server-03 执行（priority=80）
cp keepalived-backup.conf.tpl /etc/keepalived/keepalived.conf
cp check_apiserver.sh /etc/keepalived/check_apiserver.sh
chmod +x /etc/keepalived/check_apiserver.sh
# 修改 INTERFACE_NAME、VIP_ADDRESS、VIP_PREFIX、AUTH_PASSWORD
vi /etc/keepalived/keepalived.conf
```

### 5. 启动 keepalived

```bash
systemctl enable keepalived
systemctl start keepalived
systemctl status keepalived
```

### 6. 验证 VIP

```bash
# 主节点应看到 VIP 绑定到网卡
ip addr show | grep VIP_ADDRESS

# 验证通过 VIP 访问 API Server
curl -sk https://VIP_ADDRESS:6443/readyz
```

## 故障切换测试

```bash
# 在主节点停止 keepalived，观察 VIP 是否漂移到备节点
systemctl stop keepalived

# 在备节点检查
ip addr show | grep VIP_ADDRESS  # 备节点应看到 VIP
```

## 注意事项

- VIP 必须与控制节点在同一子网
- 所有控制节点的 `virtual_router_id` 必须相同
- keepalived 使用 VRRP 组播（224.0.0.18），确保网络设备不拦截
- K3s 安装时 `--tls-san` 需包含 VIP 地址（`--server` 模式脚本已自动添加）
