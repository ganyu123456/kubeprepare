#!/usr/bin/env bash
# CloudCore 独立安装脚本（离线模式）
#
# 用途：在已有 K3s 集群上单独安装/重装 KubeEdge CloudCore
# 用法：sudo ./install-cloudcore.sh <CloudCore对外IP> [KubeEdge版本]
# 示例：sudo ./install-cloudcore.sh 192.168.122.231
#       sudo ./install-cloudcore.sh 192.168.122.231 1.22.0

set -euo pipefail

# =====================================
# 参数处理
# =====================================
if [ "$EUID" -ne 0 ]; then
  echo "错误：此脚本需要使用 root 或 sudo 运行"
  exit 1
fi

EXTERNAL_IP="${1:-}"
KUBEEDGE_VERSION="${2:-1.22.0}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_LOG="/var/log/cloudcore-install.log"
KUBECTL="/usr/local/bin/k3s kubectl"

if [ -z "$EXTERNAL_IP" ]; then
  echo "错误：必须指定 CloudCore 对外 IP"
  echo "用法：sudo ./install-cloudcore.sh <IP> [KubeEdge版本]"
  exit 1
fi

if ! [[ "$EXTERNAL_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
  echo "错误：无效的 IP 地址: $EXTERNAL_IP"
  exit 1
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee "$INSTALL_LOG"
echo "=== CloudCore 独立安装脚本 ===" | tee -a "$INSTALL_LOG"
echo "对外 IP:        $EXTERNAL_IP" | tee -a "$INSTALL_LOG"
echo "KubeEdge 版本:  v$KUBEEDGE_VERSION" | tee -a "$INSTALL_LOG"
echo "脚本目录:       $SCRIPT_DIR" | tee -a "$INSTALL_LOG"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee -a "$INSTALL_LOG"

# =====================================
# 步骤 1: 检查前置条件
# =====================================
echo "" | tee -a "$INSTALL_LOG"
echo "[1/6] 检查前置条件..." | tee -a "$INSTALL_LOG"

# 检查 K3s 是否运行
if ! systemctl is-active k3s >/dev/null 2>&1; then
  echo "❌ 错误：K3s 服务未运行，请先启动 K3s" | tee -a "$INSTALL_LOG"
  exit 1
fi
echo "  ✓ K3s 服务正常运行" | tee -a "$INSTALL_LOG"

# 检查 kubeconfig
if [ ! -f /etc/rancher/k3s/k3s.yaml ]; then
  echo "❌ 错误：未找到 kubeconfig (/etc/rancher/k3s/k3s.yaml)" | tee -a "$INSTALL_LOG"
  exit 1
fi
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
echo "  ✓ kubeconfig 已就绪" | tee -a "$INSTALL_LOG"

# 检查 kubectl 可用
if ! $KUBECTL cluster-info &>/dev/null; then
  echo "❌ 错误：Kubernetes API 不可访问" | tee -a "$INSTALL_LOG"
  exit 1
fi
echo "  ✓ Kubernetes API 可访问" | tee -a "$INSTALL_LOG"

# 查找 keadm 二进制（优先使用安装包里的）
KEADM_BIN=$(find "$SCRIPT_DIR" -name "keadm" -type f 2>/dev/null | head -1)
if [ -z "$KEADM_BIN" ] && [ -f /usr/local/bin/keadm ]; then
  KEADM_BIN="/usr/local/bin/keadm"
fi
if [ -z "$KEADM_BIN" ]; then
  echo "❌ 错误：未找到 keadm 二进制文件" | tee -a "$INSTALL_LOG"
  echo "   请确认安装包已解压，或 keadm 已安装到 /usr/local/bin/" | tee -a "$INSTALL_LOG"
  exit 1
fi
echo "  ✓ keadm: $KEADM_BIN" | tee -a "$INSTALL_LOG"

# =====================================
# 步骤 2: 加载 KubeEdge 镜像到 containerd
# =====================================
echo "" | tee -a "$INSTALL_LOG"
echo "[2/6] 加载 KubeEdge 镜像到 containerd..." | tee -a "$INSTALL_LOG"

IMAGES_DIR=$(find "$SCRIPT_DIR" -type d -name "images" 2>/dev/null | head -1)

if [ -n "$IMAGES_DIR" ] && [ -d "$IMAGES_DIR" ]; then
  echo "  镜像目录: $IMAGES_DIR" | tee -a "$INSTALL_LOG"
  
  # 等待 containerd 就绪
  for i in $(seq 1 15); do
    if k3s ctr images ls >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done

  LOADED=0
  FAILED=0

  # 按命名规范查找 KubeEdge 镜像 tar
  for pattern in "docker.io-kubeedge-*.tar" "*kubeedge*.tar"; do
    for image_tar in "$IMAGES_DIR"/$pattern; do
      [ -f "$image_tar" ] || continue
      # 避免重复导入（第二个 glob 可能重叠）
      image_name=$(basename "$image_tar")
      if k3s ctr images import "$image_tar" >> "$INSTALL_LOG" 2>&1; then
        LOADED=$((LOADED + 1))
        echo "  ✓ $image_name" | tee -a "$INSTALL_LOG"
      else
        FAILED=$((FAILED + 1))
        echo "  ✗ $image_name（失败）" | tee -a "$INSTALL_LOG"
      fi
    done
  done

  echo "  镜像加载完成: $LOADED 成功, $FAILED 失败" | tee -a "$INSTALL_LOG"
  echo "  当前 KubeEdge 镜像列表:" | tee -a "$INSTALL_LOG"
  k3s ctr images ls 2>/dev/null | grep -i kubeedge | tee -a "$INSTALL_LOG" || echo "  （未找到 kubeedge 镜像）" | tee -a "$INSTALL_LOG"
else
  echo "  ⚠️  未找到 images 目录，跳过镜像加载" | tee -a "$INSTALL_LOG"
  echo "  （如果 containerd 里已有镜像则无需关注）" | tee -a "$INSTALL_LOG"
fi

# =====================================
# 步骤 3: 创建命名空间 & 初始化 CloudCore
# =====================================
echo "" | tee -a "$INSTALL_LOG"
echo "[3/6] 初始化 CloudCore..." | tee -a "$INSTALL_LOG"

$KUBECTL create namespace kubeedge 2>/dev/null || echo "  kubeedge 命名空间已存在" | tee -a "$INSTALL_LOG"

# 安装 keadm 到系统路径
cp "$KEADM_BIN" /usr/local/bin/keadm
chmod +x /usr/local/bin/keadm

# 初始化 CloudCore
mkdir -p /etc/kubeedge
echo "  执行 keadm init..." | tee -a "$INSTALL_LOG"
if keadm init \
  --advertise-address="$EXTERNAL_IP" \
  --kubeedge-version=v"$KUBEEDGE_VERSION" \
  --kube-config=/etc/rancher/k3s/k3s.yaml >> "$INSTALL_LOG" 2>&1; then
  echo "  ✓ keadm init 完成" | tee -a "$INSTALL_LOG"
else
  echo "  ⚠️  keadm init 返回非零，继续等待 CloudCore Pod..." | tee -a "$INSTALL_LOG"
fi

# 等待 CloudCore Pod 就绪
echo "  等待 CloudCore Pod 就绪（最多 60s）..." | tee -a "$INSTALL_LOG"
for i in $(seq 1 30); do
  if $KUBECTL -n kubeedge get pod -l kubeedge=cloudcore 2>/dev/null | grep -q Running; then
    echo "  ✓ CloudCore Pod 已就绪" | tee -a "$INSTALL_LOG"
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "  ⚠️  等待超时，请手动检查: kubectl get pods -n kubeedge" | tee -a "$INSTALL_LOG"
  fi
  sleep 2
done

# =====================================
# 步骤 4: 启用 dynamicController & cloudStream
# =====================================
echo "" | tee -a "$INSTALL_LOG"
echo "[4/6] 应用 CloudCore 功能配置..." | tee -a "$INSTALL_LOG"

CLOUDCORE_CONFIG=$($KUBECTL -n kubeedge get cm cloudcore -o jsonpath='{.data.cloudcore\.yaml}' 2>/dev/null || echo "")

if [ -z "$CLOUDCORE_CONFIG" ]; then
  echo "  ⚠️  未找到 cloudcore ConfigMap，跳过自定义配置" | tee -a "$INSTALL_LOG"
else
  cat > /tmp/cloudcore-patch.yaml << EOF
data:
  cloudcore.yaml: |
    modules:
      cloudHub:
        advertiseAddress:
        - ${EXTERNAL_IP}
        https:
          enable: true
          port: 10002
        nodeLimit: 1000
        websocket:
          enable: true
          port: 10000
      cloudStream:
        enable: true
        streamPort: 10003
        tunnelPort: 10004
      dynamicController:
        enable: true
EOF

  if $KUBECTL -n kubeedge patch cm cloudcore --patch-file /tmp/cloudcore-patch.yaml >> "$INSTALL_LOG" 2>&1; then
    echo "  ✓ dynamicController 和 cloudStream 已启用" | tee -a "$INSTALL_LOG"
    $KUBECTL -n kubeedge delete pod -l kubeedge=cloudcore >> "$INSTALL_LOG" 2>&1 || true
    echo "  等待 CloudCore 重启..." | tee -a "$INSTALL_LOG"
    sleep 5
    for i in $(seq 1 30); do
      if $KUBECTL -n kubeedge get pod -l kubeedge=cloudcore 2>/dev/null | grep -q Running; then
        echo "  ✓ CloudCore 重启成功" | tee -a "$INSTALL_LOG"
        break
      fi
      [ "$i" -eq 30 ] && echo "  ⚠️  重启等待超时" | tee -a "$INSTALL_LOG"
      sleep 2
    done
  else
    echo "  ⚠️  ConfigMap patch 失败，CloudCore 以默认配置运行" | tee -a "$INSTALL_LOG"
  fi

  rm -f /tmp/cloudcore-patch.yaml
fi

# =====================================
# 步骤 5: 安装 Istio CRDs（EdgeMesh 依赖）
# =====================================
echo "" | tee -a "$INSTALL_LOG"
echo "[5/8] 安装 Istio CRDs（EdgeMesh 依赖）..." | tee -a "$INSTALL_LOG"

CRDS_DIR="$SCRIPT_DIR/crds/istio"
if [ -d "$CRDS_DIR" ] && [ -n "$(ls -A "$CRDS_DIR" 2>/dev/null)" ]; then
  CRD_COUNT=0
  for crd_file in "$CRDS_DIR"/*.yaml; do
    [ -f "$crd_file" ] || continue
    if $KUBECTL apply -f "$crd_file" >> "$INSTALL_LOG" 2>&1; then
      CRD_COUNT=$((CRD_COUNT + 1))
      echo "  ✓ $(basename "$crd_file")" | tee -a "$INSTALL_LOG"
    else
      echo "  ✗ $(basename "$crd_file")（失败）" | tee -a "$INSTALL_LOG"
    fi
  done
  echo "  共安装 $CRD_COUNT 个 Istio CRDs" | tee -a "$INSTALL_LOG"
else
  echo "  ⚠️  未找到 Istio CRDs 目录（$CRDS_DIR），EdgeMesh 可能无法正常工作" | tee -a "$INSTALL_LOG"
fi

# =====================================
# 步骤 6: 安装 EdgeMesh（可选，检测到 Helm Chart 时自动安装）
# =====================================
echo "" | tee -a "$INSTALL_LOG"
echo "[6/8] 安装 EdgeMesh..." | tee -a "$INSTALL_LOG"

HELM_CHART_DIR="$SCRIPT_DIR/helm-charts"
if [ -d "$HELM_CHART_DIR" ] && [ -f "$HELM_CHART_DIR/edgemesh.tgz" ]; then
  echo "  检测到 EdgeMesh Helm Chart，开始安装..." | tee -a "$INSTALL_LOG"

  # 生成 EdgeMesh PSK
  EDGEMESH_PSK=$(openssl rand -base64 32)
  echo "  生成 EdgeMesh PSK: $EDGEMESH_PSK" | tee -a "$INSTALL_LOG"

  # 获取第一个控制节点名称作为 Relay Node
  MASTER_NODE=$($KUBECTL get nodes --selector='node-role.kubernetes.io/control-plane' \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || \
    $KUBECTL get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

  if [ -z "$MASTER_NODE" ]; then
    echo "  ⚠️  无法获取控制节点名称，跳过 EdgeMesh 安装" | tee -a "$INSTALL_LOG"
  else
    echo "  Relay Node: $MASTER_NODE" | tee -a "$INSTALL_LOG"

    # 查找 helm 命令
    HELM_CMD=""
    if command -v helm &>/dev/null; then
      HELM_CMD="helm"
    elif [ -f "$SCRIPT_DIR/helm" ]; then
      HELM_CMD="$SCRIPT_DIR/helm"
    fi

    if [ -z "$HELM_CMD" ]; then
      echo "  ⚠️  未找到 helm 命令，跳过 EdgeMesh 自动安装" | tee -a "$INSTALL_LOG"
      echo "  EdgeMesh PSK 已保存到: $SCRIPT_DIR/edgemesh-psk.txt" | tee -a "$INSTALL_LOG"
      echo "$EDGEMESH_PSK" > "$SCRIPT_DIR/edgemesh-psk.txt"
    else
      # 如果 edgemesh 已安装则先卸载
      if $HELM_CMD status edgemesh -n kubeedge &>/dev/null 2>&1; then
        echo "  检测到已有 EdgeMesh 安装，先卸载..." | tee -a "$INSTALL_LOG"
        $HELM_CMD uninstall edgemesh -n kubeedge >> "$INSTALL_LOG" 2>&1 || true
        sleep 3
      fi

      if $HELM_CMD install edgemesh "$HELM_CHART_DIR/edgemesh.tgz" \
        --namespace kubeedge \
        --set agent.image=kubeedge/edgemesh-agent:v1.17.0 \
        --set agent.psk="$EDGEMESH_PSK" \
        --set agent.relayNodes[0].nodeName="$MASTER_NODE" \
        --set "agent.relayNodes[0].advertiseAddress={$EXTERNAL_IP}" \
        >> "$INSTALL_LOG" 2>&1; then
        echo "  ✓ EdgeMesh 安装成功" | tee -a "$INSTALL_LOG"
        echo "$EDGEMESH_PSK" > "$SCRIPT_DIR/edgemesh-psk.txt"
        echo "  EdgeMesh PSK 已保存到: $SCRIPT_DIR/edgemesh-psk.txt" | tee -a "$INSTALL_LOG"
      else
        echo "  ✗ EdgeMesh 安装失败，请查看日志: $INSTALL_LOG" | tee -a "$INSTALL_LOG"
      fi
    fi
  fi
else
  echo "  未检测到 EdgeMesh Helm Chart（$HELM_CHART_DIR/edgemesh.tgz），跳过安装" | tee -a "$INSTALL_LOG"
fi

# =====================================
# 步骤 7: 获取并保存 Edge Token
# =====================================
echo "" | tee -a "$INSTALL_LOG"
echo "[7/8] 获取 Edge Token..." | tee -a "$INSTALL_LOG"

TOKEN_DIR="/etc/kubeedge/tokens"
mkdir -p "$TOKEN_DIR"

EDGE_TOKEN=""
MAX_WAIT=60
for i in $(seq 1 $MAX_WAIT); do
  if ! $KUBECTL -n kubeedge get pod -l kubeedge=cloudcore 2>/dev/null | grep -q Running; then
    sleep 2
    continue
  fi
  if $KUBECTL get secret -n kubeedge tokensecret &>/dev/null; then
    EDGE_TOKEN=$($KUBECTL get secret -n kubeedge tokensecret \
      -o jsonpath='{.data.tokendata}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
    [ -n "$EDGE_TOKEN" ] && break
  fi
  [ "$i" -eq $MAX_WAIT ] && echo "  ⚠️  等待 tokensecret 超时" | tee -a "$INSTALL_LOG"
  sleep 2
done

# 备用：keadm gettoken
if [ -z "$EDGE_TOKEN" ]; then
  EDGE_TOKEN=$(keadm gettoken \
    --kubeedge-version=v"$KUBEEDGE_VERSION" \
    --kube-config=/etc/rancher/k3s/k3s.yaml 2>/dev/null || echo "")
fi

if [ -n "$EDGE_TOKEN" ]; then
  TOKEN_FILE="$TOKEN_DIR/edge-token.txt"
  cat > "$TOKEN_FILE" << EOF
{
  "cloudIP": "${EXTERNAL_IP}",
  "cloudPort": 10000,
  "token": "${EDGE_TOKEN}",
  "generatedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "edgeConnectCommand": "sudo ./install.sh ${EXTERNAL_IP}:10000 ${EDGE_TOKEN}"
}
EOF
  chmod 600 "$TOKEN_FILE"
  echo "  ✓ Edge Token 已保存到: $TOKEN_FILE" | tee -a "$INSTALL_LOG"
  echo "  Token: $EDGE_TOKEN" | tee -a "$INSTALL_LOG"
else
  echo "  ⚠️  未能获取 Edge Token，请稍后手动执行: keadm gettoken" | tee -a "$INSTALL_LOG"
fi

# =====================================
# 步骤 6: 完成验证
# =====================================
echo "" | tee -a "$INSTALL_LOG"
echo "[8/8] 安装验证..." | tee -a "$INSTALL_LOG"

echo "" | tee -a "$INSTALL_LOG"
echo "  kubeedge 命名空间 Pod 状态：" | tee -a "$INSTALL_LOG"
$KUBECTL get pods -n kubeedge -o wide 2>/dev/null | tee -a "$INSTALL_LOG"

echo "" | tee -a "$INSTALL_LOG"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee -a "$INSTALL_LOG"
echo "=== CloudCore 安装完成 ===" | tee -a "$INSTALL_LOG"
echo "CloudCore 对外 IP:  $EXTERNAL_IP" | tee -a "$INSTALL_LOG"
echo "CloudCore 版本:     v$KUBEEDGE_VERSION" | tee -a "$INSTALL_LOG"
if [ -n "$EDGE_TOKEN" ]; then
  echo "Edge Token 文件:    $TOKEN_DIR/edge-token.txt" | tee -a "$INSTALL_LOG"
fi
if [ -f "$SCRIPT_DIR/edgemesh-psk.txt" ]; then
  echo "EdgeMesh PSK 文件:  $SCRIPT_DIR/edgemesh-psk.txt" | tee -a "$INSTALL_LOG"
fi
echo "" | tee -a "$INSTALL_LOG"
echo "验证命令：" | tee -a "$INSTALL_LOG"
echo "  kubectl get pods -n kubeedge          # 查看 CloudCore/EdgeMesh 状态" | tee -a "$INSTALL_LOG"
echo "  kubectl get nodes                     # 查看所有节点" | tee -a "$INSTALL_LOG"
echo "  helm list -n kubeedge                 # 查看 EdgeMesh Helm 状态" | tee -a "$INSTALL_LOG"
echo "安装日志：$INSTALL_LOG" | tee -a "$INSTALL_LOG"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee -a "$INSTALL_LOG"
