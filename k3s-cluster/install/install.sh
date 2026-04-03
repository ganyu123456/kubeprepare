#!/usr/bin/env bash
set -euo pipefail

# K3s 集群离线安装脚本（三合一：首节点 / 扩容控制节点 / Worker）
# 支持系统: Ubuntu 20.04/22.04, 银河麒麟V10（桌面版/服务器版）
#
# 用法:
#   模式1 首节点（建集群）:
#     sudo ./install.sh --init <NODE_IP> [NODE_NAME] [--vip <VIP_IP>[/PREFIX]]
#
#   模式2 扩容控制节点（HA 第2/3台 server）:
#     sudo ./install.sh --server <FIRST_SERVER_IP:PORT> <TOKEN> <THIS_NODE_IP> [NODE_NAME] [--vip <VIP_IP>[/PREFIX]]
#
#   模式3 Worker 节点:
#     sudo ./install.sh --agent <SERVER_IP:PORT> <TOKEN> [NODE_NAME]
#
# 可选命名参数（--init / --server 模式有效，可放在命令行任意位置）:
#   --vip <IP[/PREFIX]>      K3s API Server VIP 地址（如 192.168.1.100 或 192.168.1.100/24）
#                            指定后自动配置 keepalived 并启动；不指定时仅安装 keepalived 并生成配置模板
#   --vip-prefix <PREFIX>    子网掩码位数（默认 24），当 --vip 未含 /PREFIX 时使用
#   --skip-keepalived        跳过 keepalived 安装（Worker 节点以外若不需要 VIP 可使用）
#
# 示例:
#   # 首节点，同时配置 keepalived VIP
#   sudo ./install.sh --init 192.168.1.10 k3s-server-01 --vip 192.168.1.100/24
#
#   # 扩容第2台控制节点，同时配置 keepalived BACKUP
#   sudo ./install.sh --server 192.168.1.10:6443 K10xxx...::server:xxx 192.168.1.11 k3s-server-02 --vip 192.168.1.100/24
#
#   # Worker 节点（不需要 keepalived）
#   sudo ./install.sh --agent 192.168.1.10:6443 K10xxx...::server:xxx k3s-worker-01

# =====================================
# 权限检查
# =====================================
if [ "$EUID" -ne 0 ]; then
  echo "错误：此脚本需要使用 root 或 sudo 运行"
  exit 1
fi

# =====================================
# 全局命名参数预扫描
# （--vip / --vip-prefix / --skip-keepalived 可出现在命令行任意位置）
# =====================================
KEEPALIVED_VIP=""
KEEPALIVED_VIP_PREFIX="24"
SKIP_KEEPALIVED=false

_POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --vip)
      _VIP_VAL="${2:-}"
      if [[ "$_VIP_VAL" == */* ]]; then
        KEEPALIVED_VIP="${_VIP_VAL%%/*}"
        KEEPALIVED_VIP_PREFIX="${_VIP_VAL##*/}"
      else
        KEEPALIVED_VIP="$_VIP_VAL"
      fi
      shift 2
      ;;
    --vip-prefix)
      KEEPALIVED_VIP_PREFIX="${2:-24}"
      shift 2
      ;;
    --skip-keepalived)
      SKIP_KEEPALIVED=true
      shift
      ;;
    *)
      _POSITIONAL+=("$1")
      shift
      ;;
  esac
done
if [ "${#_POSITIONAL[@]}" -gt 0 ]; then
  set -- "${_POSITIONAL[@]}"
else
  set --
fi

# =====================================
# 参数解析
# =====================================
MODE="${1:-}"

if [ -z "$MODE" ]; then
  echo "错误：必须指定运行模式 --init / --server / --agent"
  echo ""
  echo "用法:"
  echo "  sudo ./install.sh --init   <NODE_IP> [NODE_NAME]"
  echo "  sudo ./install.sh --server <FIRST_SERVER_IP:PORT> <TOKEN> <THIS_NODE_IP> [NODE_NAME]"
  echo "  sudo ./install.sh --agent  <SERVER_IP:PORT> <TOKEN> [NODE_NAME]"
  exit 1
fi

case "$MODE" in
  --init)
    NODE_IP="${2:-}"
    NODE_NAME="${3:-k3s-server-$(hostname -s)}"
    if [ -z "$NODE_IP" ]; then
      echo "错误：--init 模式必须指定 <NODE_IP>"
      exit 1
    fi
    ;;
  --server)
    FIRST_SERVER_ADDR_PORT="${2:-}"
    NODE_TOKEN="${3:-}"
    NODE_IP="${4:-}"
    NODE_NAME="${5:-k3s-server-$(hostname -s)}"
    if [ -z "$FIRST_SERVER_ADDR_PORT" ] || [ -z "$NODE_TOKEN" ] || [ -z "$NODE_IP" ]; then
      echo "错误：--server 模式必须指定 <FIRST_SERVER_IP:PORT> <TOKEN> <THIS_NODE_IP>"
      echo "用法: sudo ./install.sh --server 192.168.1.10:6443 K10xxx...::server:xxx 192.168.1.11 [node-name]"
      exit 1
    fi
    # 解析 FIRST_SERVER_ADDR 和 PORT
    if [[ "$FIRST_SERVER_ADDR_PORT" == *:* ]]; then
      FIRST_SERVER_ADDR="${FIRST_SERVER_ADDR_PORT%%:*}"
      FIRST_SERVER_PORT="${FIRST_SERVER_ADDR_PORT##*:}"
      if ! [[ "$FIRST_SERVER_PORT" =~ ^[0-9]+$ ]]; then
        FIRST_SERVER_ADDR="$FIRST_SERVER_ADDR_PORT"
        FIRST_SERVER_PORT="6443"
      fi
    else
      FIRST_SERVER_ADDR="$FIRST_SERVER_ADDR_PORT"
      FIRST_SERVER_PORT="6443"
    fi
    ;;
  --agent)
    SERVER_ADDR_PORT="${2:-}"
    NODE_TOKEN="${3:-}"
    NODE_NAME="${4:-k3s-worker-$(hostname -s)}"
    if [ -z "$SERVER_ADDR_PORT" ] || [ -z "$NODE_TOKEN" ]; then
      echo "错误：--agent 模式必须指定 <SERVER_IP:PORT> <TOKEN>"
      echo "用法: sudo ./install.sh --agent 192.168.1.10:6443 K10xxx...::server:xxx [node-name]"
      exit 1
    fi
    if [[ "$SERVER_ADDR_PORT" == *:* ]]; then
      SERVER_ADDR="${SERVER_ADDR_PORT%%:*}"
      SERVER_PORT="${SERVER_ADDR_PORT##*:}"
      if ! [[ "$SERVER_PORT" =~ ^[0-9]+$ ]]; then
        SERVER_ADDR="$SERVER_ADDR_PORT"
        SERVER_PORT="6443"
      fi
    else
      SERVER_ADDR="$SERVER_ADDR_PORT"
      SERVER_PORT="6443"
    fi
    ;;
  *)
    echo "错误：未知模式 '$MODE'，必须是 --init / --server / --agent"
    exit 1
    ;;
esac

# =====================================
# 公共变量
# =====================================
K3S_VERSION="v1.34.2+k3s1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_LOG="/var/log/k3s-cluster-install.log"

# 检测系统架构
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  ARCH="amd64" ;;
  aarch64) ARCH="arm64" ;;
  *)
    echo "错误：不支持的架构: $ARCH"
    exit 1
    ;;
esac

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee "$INSTALL_LOG"
echo "=== K3s 集群离线安装脚本 ===" | tee -a "$INSTALL_LOG"
echo "模式:     $MODE" | tee -a "$INSTALL_LOG"
echo "架构:     $ARCH" | tee -a "$INSTALL_LOG"
echo "K3s版本:  $K3S_VERSION" | tee -a "$INSTALL_LOG"
echo "节点名称: $NODE_NAME" | tee -a "$INSTALL_LOG"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee -a "$INSTALL_LOG"

# =====================================
# 公共函数
# =====================================

# 安装 K3s 二进制文件
install_k3s_binary() {
  echo "[公共] 安装 K3s 二进制文件..." | tee -a "$INSTALL_LOG"
  K3S_BIN=$(find "$SCRIPT_DIR" -name "k3s-${ARCH}" -type f 2>/dev/null | head -1)
  if [ -z "$K3S_BIN" ]; then
    echo "错误：未找到 k3s-${ARCH} 二进制文件，路径: $SCRIPT_DIR" | tee -a "$INSTALL_LOG"
    exit 1
  fi
  cp "$K3S_BIN" /usr/local/bin/k3s
  chmod +x /usr/local/bin/k3s
  ln -sf /usr/local/bin/k3s /usr/local/bin/kubectl
  echo "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml" > /etc/profile.d/k3s-kubectl.sh
  chmod +x /etc/profile.d/k3s-kubectl.sh
  echo "  ✓ K3s 二进制已安装，kubectl 软链接已创建" | tee -a "$INSTALL_LOG"
}

# 安装 Helm
install_helm() {
  if command -v helm &>/dev/null; then
    echo "  ✓ helm 已在 PATH: $(helm version --short 2>/dev/null)" | tee -a "$INSTALL_LOG"
    return 0
  fi
  HELM_BIN=$(find "$SCRIPT_DIR" -maxdepth 2 -name "helm" -type f 2>/dev/null | head -1)
  if [ -z "$HELM_BIN" ]; then
    echo "  ⚠️  未在离线包中找到 helm，跳过安装" | tee -a "$INSTALL_LOG"
    return 0
  fi
  cp "$HELM_BIN" /usr/local/bin/helm
  chmod +x /usr/local/bin/helm
  echo "  ✓ helm 安装成功: $(helm version --short 2>/dev/null)" | tee -a "$INSTALL_LOG"
}

# 安装 nfs-common（离线 deb 包）
install_nfs_common() {
  NFS_DIR=$(find "$SCRIPT_DIR" -type d -name "nfs" 2>/dev/null | head -1)
  if [ -z "$NFS_DIR" ] || ! ls "$NFS_DIR"/*.deb &>/dev/null 2>&1; then
    echo "  ⚠️  未找到 nfs-common 离线包，跳过" | tee -a "$INSTALL_LOG"
    return 0
  fi
  DEB_COUNT=$(ls "$NFS_DIR"/*.deb | wc -l)
  echo "  安装 nfs-common 离线包 ($DEB_COUNT 个 deb)..." | tee -a "$INSTALL_LOG"
  dpkg -i "$NFS_DIR"/*.deb >> "$INSTALL_LOG" 2>&1 || true
  echo "  ✓ nfs-common 安装完成" | tee -a "$INSTALL_LOG"
}

# 等待 K3s API 就绪
wait_for_k3s_api() {
  local max_wait="${1:-120}"
  echo "  等待 K3s API 就绪（最多 ${max_wait}s）..." | tee -a "$INSTALL_LOG"
  for i in $(seq 1 $((max_wait / 2))); do
    if [ -f /etc/rancher/k3s/k3s.yaml ] && /usr/local/bin/k3s kubectl cluster-info &>/dev/null 2>&1; then
      echo "  ✓ K3s API 已就绪 (等待 $((i*2))s)" | tee -a "$INSTALL_LOG"
      return 0
    fi
    sleep 2
  done
  echo "  ✗ K3s API 启动超时" | tee -a "$INSTALL_LOG"
  return 1
}

# 加载镜像（支持 .tar 和 .tar.zst）
load_images() {
  local mode="$1"
  local IMAGES_DIR
  IMAGES_DIR=$(find "$SCRIPT_DIR" -type d -name "images" 2>/dev/null | head -1)

  if [ -z "$IMAGES_DIR" ] || [ ! -d "$IMAGES_DIR" ]; then
    echo "  ⚠️  未找到 images 目录，跳过镜像加载" | tee -a "$INSTALL_LOG"
    return 0
  fi

  echo "  镜像目录: $IMAGES_DIR" | tee -a "$INSTALL_LOG"

  # 处理 K3s airgap .tar.zst 包（直接放入 K3s 自动加载目录）
  if ls "$IMAGES_DIR"/*.tar.zst &>/dev/null 2>&1; then
    echo "  检测到 K3s airgap 镜像包，放入自动加载目录..." | tee -a "$INSTALL_LOG"
    mkdir -p /var/lib/rancher/k3s/agent/images
    for f in "$IMAGES_DIR"/*.tar.zst; do
      cp "$f" /var/lib/rancher/k3s/agent/images/
      echo "  ✓ $(basename "$f") 已放入 K3s airgap 目录" | tee -a "$INSTALL_LOG"
    done
  fi

  # 处理普通 .tar 镜像（等待 containerd 就绪后 import）
  TAR_COUNT=$(find "$IMAGES_DIR" -maxdepth 1 -name "*.tar" -type f 2>/dev/null | wc -l)
  if [ "$TAR_COUNT" -eq 0 ]; then
    return 0
  fi

  echo "  等待 containerd 就绪..." | tee -a "$INSTALL_LOG"
  for i in $(seq 1 30); do
    if k3s ctr images ls >/dev/null 2>&1; then
      break
    fi
    [ "$i" -eq 30 ] && echo "  ⚠️  containerd 未就绪，跳过 .tar 镜像导入" | tee -a "$INSTALL_LOG" && return 0
    sleep 2
  done

  LOADED=0; FAILED=0
  for image_tar in "$IMAGES_DIR"/*.tar; do
    [ -f "$image_tar" ] || continue
    if k3s ctr images import "$image_tar" >> "$INSTALL_LOG" 2>&1; then
      LOADED=$((LOADED + 1))
      echo "  ✓ $(basename "$image_tar")" | tee -a "$INSTALL_LOG"
    else
      FAILED=$((FAILED + 1))
      echo "  ✗ $(basename "$image_tar")（失败）" | tee -a "$INSTALL_LOG"
    fi
  done
  echo "  镜像导入完成: ${LOADED} 成功, ${FAILED} 失败" | tee -a "$INSTALL_LOG"
}

# 配置 K3s 系统组件排除边缘节点
patch_system_daemonsets() {
  local KUBECTL="/usr/local/bin/k3s kubectl"
  echo "  配置系统 DaemonSet 排除边缘节点..." | tee -a "$INSTALL_LOG"

  # patch metrics-server
  if $KUBECTL get deployment metrics-server -n kube-system &>/dev/null; then
    $KUBECTL patch deployment metrics-server -n kube-system --type=strategic -p \
      '{"spec":{"template":{"spec":{"hostNetwork":true,"tolerations":[{"key":"node-role.kubernetes.io/control-plane","effect":"NoSchedule"},{"key":"node-role.kubernetes.io/master","effect":"NoSchedule"}],"affinity":{"nodeAffinity":{"requiredDuringSchedulingIgnoredDuringExecution":{"nodeSelectorTerms":[{"matchExpressions":[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists"}]},{"matchExpressions":[{"key":"node-role.kubernetes.io/master","operator":"Exists"}]}]}}}}}}}' \
      >> "$INSTALL_LOG" 2>&1 || true
    $KUBECTL patch deployment metrics-server -n kube-system --type=json \
      -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"},{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-preferred-address-types=InternalIP,Hostname,InternalDNS,ExternalDNS,ExternalIP"}]' \
      >> "$INSTALL_LOG" 2>&1 || true
    echo "  ✓ metrics-server 已配置" | tee -a "$INSTALL_LOG"
  fi

  # patch svclb DaemonSets
  $KUBECTL get daemonset -n kube-system -l svccontroller.k3s.cattle.io/svcname -o name 2>/dev/null | while read -r ds; do
    $KUBECTL patch "$ds" -n kube-system --type=strategic \
      -p='{"spec":{"template":{"spec":{"affinity":{"nodeAffinity":{"requiredDuringSchedulingIgnoredDuringExecution":{"nodeSelectorTerms":[{"matchExpressions":[{"key":"node-role.kubernetes.io/edge","operator":"DoesNotExist"}]}]}}}}}}}' \
      >> "$INSTALL_LOG" 2>&1 || true
    echo "  ✓ $(basename "$ds") 已排除边缘节点" | tee -a "$INSTALL_LOG"
  done
}

# =====================================
# install_keepalived(): 安装并配置 keepalived（K3s API Server VIP）
#
# 参数:
#   $1  node_ip    - 当前节点 IP（用于自动检测网卡）
#   $2  ka_state   - MASTER 或 BACKUP
#   $3  ka_priority - VRRP 优先级（MASTER=100, BACKUP=90）
#
# 全局变量:
#   KEEPALIVED_VIP         - VIP IP（空=仅安装，生成配置模板）
#   KEEPALIVED_VIP_PREFIX  - 子网掩码位数（默认 24）
#   SKIP_KEEPALIVED        - true=跳过本函数
#   SCRIPT_DIR             - 离线包根目录
# =====================================
install_keepalived() {
  local node_ip="$1"
  local ka_state="$2"
  local ka_priority="$3"

  if [ "$SKIP_KEEPALIVED" = "true" ]; then
    echo "  跳过 keepalived 安装（--skip-keepalived）" | tee -a "$INSTALL_LOG"
    return 0
  fi

  echo "" | tee -a "$INSTALL_LOG"
  echo "=== [keepalived] 安装 K3s API Server VIP 组件 ===" | tee -a "$INSTALL_LOG"
  echo "  角色:  $ka_state（优先级 $ka_priority）" | tee -a "$INSTALL_LOG"
  if [ -n "$KEEPALIVED_VIP" ]; then
    echo "  VIP:   ${KEEPALIVED_VIP}/${KEEPALIVED_VIP_PREFIX}" | tee -a "$INSTALL_LOG"
  else
    echo "  VIP:   未指定（仅安装，生成配置模板）" | tee -a "$INSTALL_LOG"
  fi

  # ── 1. 检测包管理器与 OS ────────────────────────────────────────────────
  local pkg_mgr=""
  if command -v dpkg &>/dev/null && command -v apt-get &>/dev/null; then
    pkg_mgr="deb"
  elif command -v dnf &>/dev/null; then
    pkg_mgr="dnf"
  elif command -v yum &>/dev/null; then
    pkg_mgr="yum"
  else
    echo "  ⚠️  无法识别包管理器，keepalived 安装已跳过" | tee -a "$INSTALL_LOG"
    return 1
  fi
  local os_name=""
  [ -f /etc/os-release ] && os_name=$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-${ID:-unknown}}")
  echo "  系统: ${os_name:-unknown}   包管理: $pkg_mgr" | tee -a "$INSTALL_LOG"

  # ── 2. 安装 keepalived ──────────────────────────────────────────────────
  echo "  [1/4] 安装 keepalived..." | tee -a "$INSTALL_LOG"
  local KA_DIR
  KA_DIR=$(find "$SCRIPT_DIR" -maxdepth 2 -type d -name "keepalived" 2>/dev/null | head -1)
  local ka_installed=false

  if [ "$pkg_mgr" = "deb" ]; then
    # deb 体系：Ubuntu 20.04/22.04, 麒麟V10 桌面版
    if [ -n "$KA_DIR" ] && ls "$KA_DIR"/*.deb &>/dev/null 2>&1; then
      local deb_count
      deb_count=$(ls "$KA_DIR"/*.deb | wc -l)
      echo "    发现离线 deb 包 ${deb_count} 个，离线安装..." | tee -a "$INSTALL_LOG"
      DEBIAN_FRONTEND=noninteractive dpkg -i "$KA_DIR"/*.deb >> "$INSTALL_LOG" 2>&1 \
        && ka_installed=true \
        || {
          # dpkg 依赖问题时用 apt-get -f 仅修复已下载的包（不联网拉取新包）
          echo "    dpkg 有依赖缺失，尝试 apt-get -f install 修复（不联网）..." | tee -a "$INSTALL_LOG"
          DEBIAN_FRONTEND=noninteractive apt-get install -f -y --no-download --fix-broken >> "$INSTALL_LOG" 2>&1 \
            && ka_installed=true || true
        }
    else
      echo "  ✗ 未在离线包中找到 keepalived .deb 文件" | tee -a "$INSTALL_LOG"
      echo "    期望路径: ${KA_DIR:-${SCRIPT_DIR}/keepalived}/*.deb" | tee -a "$INSTALL_LOG"
      echo "    请重新下载包含 keepalived 离线包的安装压缩包" | tee -a "$INSTALL_LOG"
    fi
  else
    # rpm 体系：麒麟V10 服务器版 / CentOS / OpenEuler
    if [ -n "$KA_DIR" ] && ls "$KA_DIR"/*.rpm &>/dev/null 2>&1; then
      local rpm_count
      rpm_count=$(ls "$KA_DIR"/*.rpm | wc -l)
      echo "    发现离线 rpm 包 ${rpm_count} 个，离线安装..." | tee -a "$INSTALL_LOG"
      rpm -Uvh --nosignature "$KA_DIR"/*.rpm >> "$INSTALL_LOG" 2>&1 && ka_installed=true || true
    else
      echo "  ✗ 未在离线包中找到 keepalived .rpm 文件" | tee -a "$INSTALL_LOG"
      echo "    期望路径: ${KA_DIR:-${SCRIPT_DIR}/keepalived}/*.rpm" | tee -a "$INSTALL_LOG"
      echo "    请重新下载包含 keepalived 离线包的安装压缩包" | tee -a "$INSTALL_LOG"
    fi
  fi

  if ! command -v keepalived &>/dev/null; then
    echo "  ✗ keepalived 安装失败，请手动安装" | tee -a "$INSTALL_LOG"
    [ -n "$KA_DIR" ] && echo "    配置模板目录: $KA_DIR" | tee -a "$INSTALL_LOG"
    return 1
  fi
  echo "  ✓ keepalived 已安装: $(keepalived --version 2>&1 | head -1)" | tee -a "$INSTALL_LOG"

  # ── 3. 自动检测网卡 ────────────────────────────────────────────────────
  echo "  [2/4] 自动检测与节点 IP ${node_ip} 绑定的网卡..." | tee -a "$INSTALL_LOG"
  local iface=""
  # 方法1: 精确匹配该 IP 所在网卡（ip addr 输出第 4 列格式为 IP/PREFIX）
  iface=$(ip -o addr show 2>/dev/null \
    | awk -v ip="${node_ip}" '$4 ~ ("^" ip "/") {print $2; exit}')
  # 方法2: 默认路由出口网卡
  if [ -z "$iface" ]; then
    iface=$(ip route 2>/dev/null | awk '/^default/ {print $5; exit}')
    [ -n "$iface" ] && echo "    IP 未精确匹配，使用默认路由网卡: $iface" | tee -a "$INSTALL_LOG"
  fi
  # 方法3: 第一块非 lo 网卡（兜底）
  if [ -z "$iface" ]; then
    iface=$(ip -o link show 2>/dev/null | awk -F': ' 'NR>1 && $2 != "lo" {print $2; exit}')
    [ -n "$iface" ] && echo "    使用第一块非 lo 网卡: $iface" | tee -a "$INSTALL_LOG"
  fi
  if [ -z "$iface" ]; then
    iface="INTERFACE_NAME"
    echo "  ⚠️  网卡自动检测失败，请手动替换配置中的 INTERFACE_NAME" | tee -a "$INSTALL_LOG"
  else
    echo "  ✓ 检测到网卡: ${iface}" | tee -a "$INSTALL_LOG"
  fi

  # ── 4. 安装健康检查脚本 ────────────────────────────────────────────────
  echo "  [3/4] 安装 check_apiserver.sh..." | tee -a "$INSTALL_LOG"
  mkdir -p /etc/keepalived
  if [ -n "$KA_DIR" ] && [ -f "$KA_DIR/check_apiserver.sh" ]; then
    cp "$KA_DIR/check_apiserver.sh" /etc/keepalived/check_apiserver.sh
  else
    cat > /etc/keepalived/check_apiserver.sh << 'CHKEOF'
#!/usr/bin/env bash
HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" \
  --max-time 3 https://127.0.0.1:6443/readyz 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "401" ]; then
  exit 0
else
  exit 1
fi
CHKEOF
  fi
  chmod +x /etc/keepalived/check_apiserver.sh
  echo "  ✓ check_apiserver.sh 已就位" | tee -a "$INSTALL_LOG"

  # ── 5. 生成 keepalived.conf ────────────────────────────────────────────
  echo "  [4/4] 生成 keepalived 配置..." | tee -a "$INSTALL_LOG"

  if [ -n "$KEEPALIVED_VIP" ]; then
    # 有 VIP：写入完整配置并启动服务
    cat > /etc/keepalived/keepalived.conf << KAEOF
global_defs {
  router_id k3s-apiserver-$(hostname -s)
  vrrp_mcast_group4 224.0.0.18
  script_user root
  enable_script_security
}

vrrp_script check_k3s_apiserver {
  script "/etc/keepalived/check_apiserver.sh"
  interval 3
  weight   -20
  fall     2
  rise     2
}

vrrp_instance K3S_APISERVER {
  state             ${ka_state}
  interface         ${iface}
  virtual_router_id 51
  priority          ${ka_priority}
  advert_int        1

  authentication {
    auth_type PASS
    auth_pass k3svip01
  }

  virtual_ipaddress {
    ${KEEPALIVED_VIP}/${KEEPALIVED_VIP_PREFIX}
  }

  track_script {
    check_k3s_apiserver
  }
}
KAEOF
    echo "  ✓ keepalived.conf 生成完毕（VIP: ${KEEPALIVED_VIP}/${KEEPALIVED_VIP_PREFIX}）" | tee -a "$INSTALL_LOG"
    systemctl enable keepalived >> "$INSTALL_LOG" 2>&1
    if systemctl restart keepalived >> "$INSTALL_LOG" 2>&1; then
      sleep 2
      if systemctl is-active keepalived &>/dev/null; then
        echo "  ✓ keepalived 服务已启动并运行正常（角色: ${ka_state}）" | tee -a "$INSTALL_LOG"
      else
        echo "  ⚠️  keepalived 进程异常，请检查: journalctl -u keepalived -n 50" | tee -a "$INSTALL_LOG"
      fi
    else
      echo "  ⚠️  keepalived 启动失败，请检查: journalctl -u keepalived -n 50" | tee -a "$INSTALL_LOG"
    fi

  else
    # 无 VIP：生成已预填网卡的配置模板，等待用户填写 VIP 后手动启动
    local tpl_src=""
    if [ -n "$KA_DIR" ]; then
      [ "$ka_state" = "MASTER" ] \
        && tpl_src="$KA_DIR/keepalived-master.conf.tpl" \
        || tpl_src="$KA_DIR/keepalived-backup.conf.tpl"
    fi
    if [ -n "$tpl_src" ] && [ -f "$tpl_src" ]; then
      sed "s/INTERFACE_NAME/${iface}/g" "$tpl_src" > /etc/keepalived/keepalived.conf.tpl
    else
      cat > /etc/keepalived/keepalived.conf.tpl << TPLEOF
global_defs {
  router_id k3s-apiserver-$(hostname -s)
  vrrp_mcast_group4 224.0.0.18
  script_user root
  enable_script_security
}

vrrp_script check_k3s_apiserver {
  script "/etc/keepalived/check_apiserver.sh"
  interval 3
  weight   -20
  fall     2
  rise     2
}

vrrp_instance K3S_APISERVER {
  state             ${ka_state}
  interface         ${iface}
  virtual_router_id 51
  priority          ${ka_priority}
  advert_int        1

  authentication {
    auth_type PASS
    auth_pass VIP_AUTH_PASSWORD
  }

  virtual_ipaddress {
    VIP_ADDRESS/VIP_PREFIX
  }

  track_script {
    check_k3s_apiserver
  }
}
TPLEOF
    fi
    systemctl enable keepalived >> "$INSTALL_LOG" 2>&1 || true
    echo "  ✓ keepalived 已安装，网卡已预填: ${iface}" | tee -a "$INSTALL_LOG"
    echo "" | tee -a "$INSTALL_LOG"
    echo "  ⚠️  未指定 VIP，keepalived 尚未启动。请完成以下步骤后手动启动：" | tee -a "$INSTALL_LOG"
    echo "  1. 编辑模板（填写 VIP_ADDRESS / VIP_PREFIX / VIP_AUTH_PASSWORD）：" | tee -a "$INSTALL_LOG"
    echo "       vim /etc/keepalived/keepalived.conf.tpl" | tee -a "$INSTALL_LOG"
    echo "  2. 应用配置并启动：" | tee -a "$INSTALL_LOG"
    echo "       cp /etc/keepalived/keepalived.conf.tpl /etc/keepalived/keepalived.conf" | tee -a "$INSTALL_LOG"
    echo "       systemctl start keepalived && systemctl status keepalived" | tee -a "$INSTALL_LOG"
  fi
}

# =====================================
# 模式1: --init 首节点安装
# =====================================
install_init() {
  echo "" | tee -a "$INSTALL_LOG"
  echo "=== 模式: 首节点（--init）===" | tee -a "$INSTALL_LOG"
  echo "节点 IP:   $NODE_IP" | tee -a "$INSTALL_LOG"
  echo "节点名称:  $NODE_NAME" | tee -a "$INSTALL_LOG"
  [ -n "$KEEPALIVED_VIP" ] && echo "VIP:       ${KEEPALIVED_VIP}/${KEEPALIVED_VIP_PREFIX}（keepalived MASTER）" | tee -a "$INSTALL_LOG"

  # 1. 安装 K3s 二进制
  echo "[1/7] 安装 K3s 二进制..." | tee -a "$INSTALL_LOG"
  install_k3s_binary

  # 2. 安装 Helm
  echo "[2/7] 安装 Helm..." | tee -a "$INSTALL_LOG"
  install_helm

  # 3. 安装 nfs-common
  echo "[3/7] 安装 nfs-common..." | tee -a "$INSTALL_LOG"
  install_nfs_common

  # 4. 配置并启动 K3s server（首节点，内置 etcd --cluster-init）
  echo "[4/7] 配置 K3s server 服务..." | tee -a "$INSTALL_LOG"

  # 若指定了 VIP，追加额外的 tls-san（证书覆盖 VIP 地址）
  _TLS_SAN_EXTRA=""
  if [ -n "$KEEPALIVED_VIP" ]; then
    _TLS_SAN_EXTRA=$'\n'"  --tls-san=${KEEPALIVED_VIP} \\"
  fi

  # 停止旧服务
  systemctl stop k3s 2>/dev/null || true
  systemctl disable k3s 2>/dev/null || true
  rm -f /etc/systemd/system/k3s.service

  cat > /etc/systemd/system/k3s.service << EOF
[Unit]
Description=Lightweight Kubernetes (K3s Server - Init)
Documentation=https://k3s.io
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/local/bin/k3s server \\
  --cluster-init \\
  --egress-selector-mode=disabled \\
  --advertise-address=${NODE_IP} \\
  --node-name=${NODE_NAME} \\
  --tls-san=${NODE_IP} \\${_TLS_SAN_EXTRA}
  --bind-address=0.0.0.0 \\
  --cluster-cidr=10.42.0.0/16 \\
  --service-cidr=10.43.0.0/16 \\
  --cluster-dns=10.43.0.10 \\
  --kube-apiserver-arg=bind-address=0.0.0.0 \\
  --kube-apiserver-arg=advertise-address=${NODE_IP} \\
  --kube-controller-manager-arg=bind-address=0.0.0.0 \\
  --kube-controller-manager-arg=node-cidr-mask-size=24 \\
  --kube-scheduler-arg=bind-address=0.0.0.0
KillMode=process
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=k3s
LimitNOFILE=1048576
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

  chmod 644 /etc/systemd/system/k3s.service
  systemctl daemon-reload
  systemctl enable k3s
  systemctl start k3s
  echo "  ✓ K3s server 服务已启动" | tee -a "$INSTALL_LOG"

  # 5. 等待 API 就绪 + 加载镜像
  echo "[5/7] 等待 API 就绪并加载镜像..." | tee -a "$INSTALL_LOG"
  wait_for_k3s_api 120
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  chmod 644 /etc/rancher/k3s/k3s.yaml

  load_images "init"

  # 等待核心组件 Pod 就绪
  for i in $(seq 1 30); do
    if /usr/local/bin/k3s kubectl get pod -n kube-system -l k8s-app=kube-dns 2>/dev/null | grep -q Running; then
      echo "  ✓ CoreDNS 已就绪" | tee -a "$INSTALL_LOG"
      break
    fi
    sleep 4
  done

  # 6. 配置系统组件
  echo "[6/7] 配置系统组件排除边缘节点..." | tee -a "$INSTALL_LOG"
  sleep 10
  patch_system_daemonsets

  # 7. 安装 keepalived（MASTER 角色，优先级 100）
  echo "[7/7] 安装 keepalived（K3s API Server VIP）..." | tee -a "$INSTALL_LOG"
  install_keepalived "$NODE_IP" "MASTER" "100"

  # 输出完成信息
  K3S_TOKEN=$(cat /var/lib/rancher/k3s/server/token 2>/dev/null || echo "<未就绪>")
  local _VIP_HINT=""
  [ -n "$KEEPALIVED_VIP" ] && _VIP_HINT=" --vip ${KEEPALIVED_VIP}/${KEEPALIVED_VIP_PREFIX}"
  echo "" | tee -a "$INSTALL_LOG"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee -a "$INSTALL_LOG"
  echo "=== K3s 首节点安装完成 ===" | tee -a "$INSTALL_LOG"
  echo "节点 IP:   $NODE_IP" | tee -a "$INSTALL_LOG"
  echo "节点名称:  $NODE_NAME" | tee -a "$INSTALL_LOG"
  [ -n "$KEEPALIVED_VIP" ] && echo "VIP:       ${KEEPALIVED_VIP}/${KEEPALIVED_VIP_PREFIX}（keepalived MASTER）" | tee -a "$INSTALL_LOG"
  echo "" | tee -a "$INSTALL_LOG"
  echo "【K3s 扩容控制节点命令（请同时传入相同 VIP）】" | tee -a "$INSTALL_LOG"
  echo "  sudo ./install.sh --server ${NODE_IP}:6443 ${K3S_TOKEN} <新节点IP> [节点名]${_VIP_HINT}" | tee -a "$INSTALL_LOG"
  echo "" | tee -a "$INSTALL_LOG"
  echo "【K3s Worker 节点加入命令】" | tee -a "$INSTALL_LOG"
  echo "  sudo ./install.sh --agent ${NODE_IP}:6443 ${K3S_TOKEN} [节点名]" | tee -a "$INSTALL_LOG"
  echo "" | tee -a "$INSTALL_LOG"
  echo "【下一步：安装 CloudCore HA】" | tee -a "$INSTALL_LOG"
  echo "  解压 cloudcore-ha-*.tar.gz 后运行：" | tee -a "$INSTALL_LOG"
  echo "  sudo ./install/install.sh --vip <VIP_IP> --nodes \"${NODE_IP}\"" | tee -a "$INSTALL_LOG"
  echo "" | tee -a "$INSTALL_LOG"
  echo "KUBECONFIG: /etc/rancher/k3s/k3s.yaml" | tee -a "$INSTALL_LOG"
  echo "K3S_TOKEN:  $K3S_TOKEN" | tee -a "$INSTALL_LOG"
  echo "安装日志:   $INSTALL_LOG" | tee -a "$INSTALL_LOG"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee -a "$INSTALL_LOG"

  # 打印 token 到 stdout
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "K3s 节点 Token（用于扩容 server/worker）:"
  echo "$K3S_TOKEN"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# =====================================
# 模式2: --server 扩容控制节点
# =====================================
install_server() {
  echo "" | tee -a "$INSTALL_LOG"
  echo "=== 模式: 扩容控制节点（--server）===" | tee -a "$INSTALL_LOG"
  echo "首节点地址: ${FIRST_SERVER_ADDR}:${FIRST_SERVER_PORT}" | tee -a "$INSTALL_LOG"
  echo "本节点 IP:  $NODE_IP" | tee -a "$INSTALL_LOG"
  echo "节点名称:   $NODE_NAME" | tee -a "$INSTALL_LOG"
  [ -n "$KEEPALIVED_VIP" ] && echo "VIP:        ${KEEPALIVED_VIP}/${KEEPALIVED_VIP_PREFIX}（keepalived BACKUP）" | tee -a "$INSTALL_LOG"

  # 1. 检查网络连通性
  echo "[1/7] 检查首节点连通性..." | tee -a "$INSTALL_LOG"
  if ! timeout 5 bash -c "exec 3<>/dev/tcp/${FIRST_SERVER_ADDR}/${FIRST_SERVER_PORT}" 2>/dev/null; then
    echo "  ⚠️  无法连接 ${FIRST_SERVER_ADDR}:${FIRST_SERVER_PORT}，请确认首节点运行正常" | tee -a "$INSTALL_LOG"
  else
    echo "  ✓ 首节点连通性正常" | tee -a "$INSTALL_LOG"
  fi

  # 2. 安装 K3s 二进制
  echo "[2/7] 安装 K3s 二进制..." | tee -a "$INSTALL_LOG"
  install_k3s_binary

  # 3. 安装 Helm
  echo "[3/7] 安装 Helm..." | tee -a "$INSTALL_LOG"
  install_helm

  # 4. 安装 nfs-common
  echo "[4/7] 安装 nfs-common..." | tee -a "$INSTALL_LOG"
  install_nfs_common

  # 5. 配置并启动 K3s server（加入模式）
  echo "[5/7] 配置 K3s server 服务（加入集群）..." | tee -a "$INSTALL_LOG"

  # 若指定了 VIP，追加额外的 tls-san（证书覆盖 VIP 地址）
  _TLS_SAN_EXTRA=""
  if [ -n "$KEEPALIVED_VIP" ]; then
    _TLS_SAN_EXTRA=$'\n'"  --tls-san=${KEEPALIVED_VIP} \\"
  fi

  systemctl stop k3s 2>/dev/null || true
  systemctl disable k3s 2>/dev/null || true
  rm -f /etc/systemd/system/k3s.service

  cat > /etc/systemd/system/k3s.service << EOF
[Unit]
Description=Lightweight Kubernetes (K3s Server - Join)
Documentation=https://k3s.io
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/local/bin/k3s server \\
  --server=https://${FIRST_SERVER_ADDR}:${FIRST_SERVER_PORT} \\
  --token=${NODE_TOKEN} \\
  --egress-selector-mode=disabled \\
  --advertise-address=${NODE_IP} \\
  --node-name=${NODE_NAME} \\
  --tls-san=${NODE_IP} \\${_TLS_SAN_EXTRA}
  --bind-address=0.0.0.0 \\
  --kube-apiserver-arg=bind-address=0.0.0.0 \\
  --kube-apiserver-arg=advertise-address=${NODE_IP} \\
  --kube-controller-manager-arg=bind-address=0.0.0.0 \\
  --kube-scheduler-arg=bind-address=0.0.0.0
KillMode=process
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=k3s
LimitNOFILE=1048576
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

  chmod 644 /etc/systemd/system/k3s.service
  systemctl daemon-reload
  systemctl enable k3s
  systemctl start k3s
  echo "  ✓ K3s server 服务已启动（正在加入集群）" | tee -a "$INSTALL_LOG"

  # 6. 等待就绪 + 加载镜像 + 验证
  echo "[6/7] 等待节点就绪并加载镜像..." | tee -a "$INSTALL_LOG"
  wait_for_k3s_api 120
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  chmod 644 /etc/rancher/k3s/k3s.yaml

  load_images "server"

  sleep 5
  /usr/local/bin/k3s kubectl get nodes 2>/dev/null | tee -a "$INSTALL_LOG" || true

  # 7. 安装 keepalived（BACKUP 角色，优先级 90）
  echo "[7/7] 安装 keepalived（K3s API Server VIP）..." | tee -a "$INSTALL_LOG"
  install_keepalived "$NODE_IP" "BACKUP" "90"

  echo "" | tee -a "$INSTALL_LOG"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee -a "$INSTALL_LOG"
  echo "=== K3s 控制节点扩容完成 ===" | tee -a "$INSTALL_LOG"
  echo "节点 IP:    $NODE_IP" | tee -a "$INSTALL_LOG"
  echo "节点名称:   $NODE_NAME" | tee -a "$INSTALL_LOG"
  echo "首节点地址: ${FIRST_SERVER_ADDR}:${FIRST_SERVER_PORT}" | tee -a "$INSTALL_LOG"
  [ -n "$KEEPALIVED_VIP" ] && echo "VIP:        ${KEEPALIVED_VIP}/${KEEPALIVED_VIP_PREFIX}（keepalived BACKUP）" | tee -a "$INSTALL_LOG"
  echo "" | tee -a "$INSTALL_LOG"
  echo "验证命令（在任意控制节点执行）:" | tee -a "$INSTALL_LOG"
  echo "  kubectl get nodes" | tee -a "$INSTALL_LOG"
  echo "  # HA 集群建议 3 个控制节点（保证 etcd quorum）" | tee -a "$INSTALL_LOG"
  echo "安装日志: $INSTALL_LOG" | tee -a "$INSTALL_LOG"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee -a "$INSTALL_LOG"
}

# =====================================
# 模式3: --agent Worker 节点
# =====================================
install_agent() {
  echo "" | tee -a "$INSTALL_LOG"
  echo "=== 模式: Worker 节点（--agent）===" | tee -a "$INSTALL_LOG"
  echo "Server 地址: ${SERVER_ADDR}:${SERVER_PORT}" | tee -a "$INSTALL_LOG"
  echo "节点名称:    $NODE_NAME" | tee -a "$INSTALL_LOG"

  # 校验 token 格式
  if [[ ! "$NODE_TOKEN" =~ ^K10.* ]]; then
    echo "  ⚠️  TOKEN 格式可能不正确（期望以 K10 开头）: ${NODE_TOKEN:0:20}..." | tee -a "$INSTALL_LOG"
  fi

  # 1. 检查网络连通性
  echo "[1/5] 检查 Server 节点连通性..." | tee -a "$INSTALL_LOG"
  if ! timeout 5 bash -c "exec 3<>/dev/tcp/${SERVER_ADDR}/${SERVER_PORT}" 2>/dev/null; then
    echo "  ⚠️  无法连接 ${SERVER_ADDR}:${SERVER_PORT}，请确认 Server 正在运行" | tee -a "$INSTALL_LOG"
  else
    echo "  ✓ Server 节点连通性正常" | tee -a "$INSTALL_LOG"
  fi

  # 2. 安装 K3s 二进制
  echo "[2/5] 安装 K3s 二进制..." | tee -a "$INSTALL_LOG"
  install_k3s_binary

  # 3. 安装 Helm + nfs-common
  echo "[2.5/5] 安装 Helm..." | tee -a "$INSTALL_LOG"
  install_helm
  echo "[2.6/5] 安装 nfs-common..." | tee -a "$INSTALL_LOG"
  install_nfs_common

  # 4. 放置 airgap 镜像（在 K3s 启动前放好，K3s 启动时自动加载）
  echo "[3/5] 准备 airgap 镜像..." | tee -a "$INSTALL_LOG"
  IMAGES_DIR=$(find "$SCRIPT_DIR" -type d -name "images" 2>/dev/null | head -1)
  if [ -n "$IMAGES_DIR" ] && ls "$IMAGES_DIR"/*.tar.zst &>/dev/null 2>&1; then
    mkdir -p /var/lib/rancher/k3s/agent/images
    for f in "$IMAGES_DIR"/*.tar.zst; do
      cp "$f" /var/lib/rancher/k3s/agent/images/
      echo "  ✓ $(basename "$f") 已放入 K3s airgap 目录" | tee -a "$INSTALL_LOG"
    done
  fi

  # 5. 配置并启动 K3s agent
  echo "[4/5] 配置 K3s agent 服务..." | tee -a "$INSTALL_LOG"
  systemctl stop k3s-agent 2>/dev/null || true
  systemctl disable k3s-agent 2>/dev/null || true
  rm -f /etc/systemd/system/k3s-agent.service

  cat > /etc/systemd/system/k3s-agent.service << EOF
[Unit]
Description=Lightweight Kubernetes Agent (K3s Worker)
Documentation=https://k3s.io
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/local/bin/k3s agent \\
  --server=https://${SERVER_ADDR}:${SERVER_PORT} \\
  --token=${NODE_TOKEN} \\
  --node-name=${NODE_NAME} \\
  --data-dir=/var/lib/rancher/k3s/agent \\
  --kubelet-arg=cloud-provider=external \\
  --kubelet-arg=provider-id=k3s://${NODE_NAME}
KillMode=process
Delegate=yes
LimitNOFILE=1048576
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
TimeoutStartSec=0
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

  chmod 644 /etc/systemd/system/k3s-agent.service
  systemctl daemon-reload
  systemctl enable k3s-agent
  systemctl start k3s-agent

  # 等待 k3s-agent 启动
  echo "[5/5] 等待 K3s agent 启动..." | tee -a "$INSTALL_LOG"
  for i in $(seq 1 60); do
    STATUS=$(systemctl is-active k3s-agent 2>/dev/null || echo "unknown")
    if [ "$STATUS" = "active" ]; then
      echo "  ✓ k3s-agent 服务已就绪 (等待 ${i}s)" | tee -a "$INSTALL_LOG"
      break
    fi
    if [ "$STATUS" = "failed" ]; then
      echo "  ✗ k3s-agent 服务启动失败" | tee -a "$INSTALL_LOG"
      systemctl status k3s-agent --no-pager | tee -a "$INSTALL_LOG"
      exit 1
    fi
    [ "$i" -eq 60 ] && echo "  ⚠️  k3s-agent 启动超时，请手动检查: systemctl status k3s-agent" | tee -a "$INSTALL_LOG"
    sleep 1
  done

  # 等待 containerd 就绪后导入附加镜像（非 airgap 的独立 tar）
  if [ -n "$IMAGES_DIR" ]; then
    for i in $(seq 1 30); do
      if k3s ctr images ls >/dev/null 2>&1; then
        break
      fi
      sleep 2
    done
    LOADED=0
    for image_tar in "$IMAGES_DIR"/*.tar; do
      [ -f "$image_tar" ] || continue
      if k3s ctr images import "$image_tar" >> "$INSTALL_LOG" 2>&1; then
        LOADED=$((LOADED + 1))
        echo "  ✓ $(basename "$image_tar")" | tee -a "$INSTALL_LOG"
      fi
    done
    [ "$LOADED" -gt 0 ] && echo "  已导入 ${LOADED} 个附加镜像" | tee -a "$INSTALL_LOG"
  fi

  # 打标签（标记为 worker 角色）
  echo "  节点将在加入集群后自动标记为 worker..." | tee -a "$INSTALL_LOG"

  echo "" | tee -a "$INSTALL_LOG"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee -a "$INSTALL_LOG"
  echo "=== K3s Worker 节点安装完成 ===" | tee -a "$INSTALL_LOG"
  echo "节点名称:    $NODE_NAME" | tee -a "$INSTALL_LOG"
  echo "Server 地址: ${SERVER_ADDR}:${SERVER_PORT}" | tee -a "$INSTALL_LOG"
  echo "" | tee -a "$INSTALL_LOG"
  echo "验证命令（在 Server 节点执行）:" | tee -a "$INSTALL_LOG"
  echo "  kubectl get nodes" | tee -a "$INSTALL_LOG"
  echo "  kubectl label node ${NODE_NAME} node-role.kubernetes.io/worker=true" | tee -a "$INSTALL_LOG"
  echo "故障排查:" | tee -a "$INSTALL_LOG"
  echo "  systemctl status k3s-agent" | tee -a "$INSTALL_LOG"
  echo "  journalctl -u k3s-agent -f" | tee -a "$INSTALL_LOG"
  echo "安装日志: $INSTALL_LOG" | tee -a "$INSTALL_LOG"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee -a "$INSTALL_LOG"
}

# =====================================
# 主程序入口
# =====================================
case "$MODE" in
  --init)   install_init   ;;
  --server) install_server ;;
  --agent)  install_agent  ;;
esac
