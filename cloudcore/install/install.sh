#!/usr/bin/env bash
set -euo pipefail

# CloudCore HA 离线安装脚本
#
# 用法:
#   sudo ./install.sh --vip <VIP_IP> --nodes "<NODE1_IP>,<NODE2_IP>,<NODE3_IP>" \
#     [--replicas 3] [--kubeedge-version 1.22.0] [--skip-keepalived] [--skip-edgemesh]
#
# 示例:
#   # 单节点（无 HA）
#   sudo ./install.sh --vip 192.168.1.10 --nodes "192.168.1.10"
#
#   # 三节点 HA
#   sudo ./install.sh --vip 192.168.1.100 --nodes "192.168.1.10,192.168.1.11,192.168.1.12" --replicas 3
#
# 前置条件:
#   - K3s 集群已部署完成（k3s-cluster 安装包）
#   - 本机是 K3s 控制节点，/etc/rancher/k3s/k3s.yaml 存在
#   - keepalived VIP 已规划（--skip-keepalived 可跳过安装）

# =====================================
# 权限检查
# =====================================
if [ "$EUID" -ne 0 ]; then
  echo "错误：此脚本需要使用 root 或 sudo 运行"
  exit 1
fi

# =====================================
# 参数解析
# =====================================
CLOUDCORE_VIP=""
CLOUDCORE_NODES=""
REPLICAS=1
KUBEEDGE_VERSION="1.22.0"
SKIP_KEEPALIVED=false
SKIP_EDGEMESH=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vip)              CLOUDCORE_VIP="$2"; shift 2 ;;
    --nodes)            CLOUDCORE_NODES="$2"; shift 2 ;;
    --replicas)         REPLICAS="$2"; shift 2 ;;
    --kubeedge-version) KUBEEDGE_VERSION="$2"; shift 2 ;;
    --skip-keepalived)  SKIP_KEEPALIVED=true; shift ;;
    --skip-edgemesh)    SKIP_EDGEMESH=true; shift ;;
    --help|-h)
      echo "用法: sudo ./install.sh --vip <VIP> --nodes \"<IP1>,<IP2>\" [选项]"
      echo ""
      echo "必填参数:"
      echo "  --vip <IP>            CloudCore VIP（edge 节点接入地址）"
      echo "  --nodes \"<IP1,IP2>\"   部署 CloudCore 的 K3s 控制节点 IP 列表"
      echo ""
      echo "可选参数:"
      echo "  --replicas <N>        CloudCore 副本数（默认 1，建议 3 实现 HA）"
      echo "  --kubeedge-version V  KubeEdge 版本（默认 1.22.0）"
      echo "  --skip-keepalived     跳过 keepalived 安装（已手动配置时使用）"
      echo "  --skip-edgemesh       跳过 EdgeMesh 安装"
      exit 0
      ;;
    *)
      echo "未知参数: $1，使用 --help 查看用法"
      exit 1
      ;;
  esac
done

if [ -z "$CLOUDCORE_VIP" ] || [ -z "$CLOUDCORE_NODES" ]; then
  echo "错误：必须指定 --vip 和 --nodes 参数"
  echo "用法: sudo ./install.sh --vip <VIP_IP> --nodes \"<NODE1>,<NODE2>\""
  exit 1
fi

if ! [[ "$CLOUDCORE_VIP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
  echo "错误：无效的 VIP 地址: $CLOUDCORE_VIP"
  exit 1
fi

# =====================================
# 公共变量
# =====================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_LOG="/var/log/cloudcore-ha-install.log"
KUBECTL="/usr/local/bin/k3s kubectl"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

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

# 将 CLOUDCORE_NODES 转换为数组
IFS=',' read -ra NODE_LIST <<< "$CLOUDCORE_NODES"
NODE_COUNT="${#NODE_LIST[@]}"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee "$INSTALL_LOG"
echo "=== CloudCore HA 离线安装脚本 ===" | tee -a "$INSTALL_LOG"
echo "CloudCore VIP:    $CLOUDCORE_VIP" | tee -a "$INSTALL_LOG"
echo "CloudCore 节点:   $CLOUDCORE_NODES" | tee -a "$INSTALL_LOG"
echo "副本数:           $REPLICAS" | tee -a "$INSTALL_LOG"
echo "KubeEdge 版本:    v$KUBEEDGE_VERSION" | tee -a "$INSTALL_LOG"
echo "跳过 keepalived:  $SKIP_KEEPALIVED" | tee -a "$INSTALL_LOG"
echo "脚本目录:         $SCRIPT_DIR" | tee -a "$INSTALL_LOG"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee -a "$INSTALL_LOG"

# =====================================
# 步骤 1: 前置条件检查
# =====================================
echo "" | tee -a "$INSTALL_LOG"
echo "[1/10] 检查前置条件..." | tee -a "$INSTALL_LOG"

if ! systemctl is-active k3s >/dev/null 2>&1; then
  echo "  ❌ K3s 服务未运行，请先安装 K3s 集群" | tee -a "$INSTALL_LOG"
  exit 1
fi
echo "  ✓ K3s 服务正常运行" | tee -a "$INSTALL_LOG"

if [ ! -f /etc/rancher/k3s/k3s.yaml ]; then
  echo "  ❌ 未找到 kubeconfig: /etc/rancher/k3s/k3s.yaml" | tee -a "$INSTALL_LOG"
  exit 1
fi
echo "  ✓ kubeconfig 已就绪" | tee -a "$INSTALL_LOG"

if ! $KUBECTL cluster-info &>/dev/null; then
  echo "  ❌ Kubernetes API 不可访问" | tee -a "$INSTALL_LOG"
  exit 1
fi
echo "  ✓ Kubernetes API 可访问" | tee -a "$INSTALL_LOG"

# 查找 keadm 二进制
KEADM_BIN=$(find "$SCRIPT_DIR" -name "keadm" -type f 2>/dev/null | head -1)
if [ -z "$KEADM_BIN" ] && [ -f /usr/local/bin/keadm ]; then
  KEADM_BIN="/usr/local/bin/keadm"
fi
if [ -z "$KEADM_BIN" ]; then
  echo "  ❌ 未找到 keadm 二进制文件" | tee -a "$INSTALL_LOG"
  exit 1
fi
echo "  ✓ keadm: $KEADM_BIN" | tee -a "$INSTALL_LOG"

# 查找 cloudcore 二进制
CLOUDCORE_BIN=$(find "$SCRIPT_DIR" -name "cloudcore" -type f 2>/dev/null | head -1)
echo "  ✓ cloudcore: ${CLOUDCORE_BIN:-（将从镜像中使用）}" | tee -a "$INSTALL_LOG"

# =====================================
# 步骤 2: 安装 keepalived（CloudCore VIP）
# =====================================
echo "" | tee -a "$INSTALL_LOG"
echo "[2/10] 安装 keepalived（CloudCore VIP）..." | tee -a "$INSTALL_LOG"

if [ "$SKIP_KEEPALIVED" = "true" ]; then
  echo "  ⏭  跳过 keepalived 安装（--skip-keepalived）" | tee -a "$INSTALL_LOG"
else
  # 离线包中 keepalived deb 包存放于 keepalived-deb/ 目录（与 keepalived/ 配置模板目录区分）
  KA_DEB_DIR=$(find "$SCRIPT_DIR" -type d -name "keepalived-deb" 2>/dev/null | head -1)
  if [ -n "$KA_DEB_DIR" ] && ls "$KA_DEB_DIR"/*.deb &>/dev/null 2>&1; then
    echo "  安装 keepalived 离线包..." | tee -a "$INSTALL_LOG"
    dpkg -i "$KA_DEB_DIR"/*.deb >> "$INSTALL_LOG" 2>&1 || true
    echo "  ✓ keepalived 已安装" | tee -a "$INSTALL_LOG"
  elif command -v apt-get &>/dev/null; then
    echo "  在线安装 keepalived..." | tee -a "$INSTALL_LOG"
    apt-get install -y keepalived >> "$INSTALL_LOG" 2>&1 || true
    echo "  ✓ keepalived 已安装" | tee -a "$INSTALL_LOG"
  else
    echo "  ⚠️  未找到 keepalived 离线包，跳过安装（请手动安装 keepalived）" | tee -a "$INSTALL_LOG"
    echo "  参考配置模板: $SCRIPT_DIR/keepalived/" | tee -a "$INSTALL_LOG"
    SKIP_KEEPALIVED=true
  fi

  if [ "$SKIP_KEEPALIVED" = "false" ] && command -v keepalived &>/dev/null; then
    KA_CONF_DIR=$(find "$SCRIPT_DIR" -type d -name "keepalived" 2>/dev/null | head -1)
    if [ -n "$KA_CONF_DIR" ] && [ -f "$KA_CONF_DIR/check_cloudcore.sh" ]; then
      mkdir -p /etc/keepalived
      cp "$KA_CONF_DIR/check_cloudcore.sh" /etc/keepalived/check_cloudcore.sh
      chmod +x /etc/keepalived/check_cloudcore.sh
      echo "  ✓ keepalived 健康检查脚本已安装" | tee -a "$INSTALL_LOG"
      echo "" | tee -a "$INSTALL_LOG"
      echo "  ⚠️  请手动配置 keepalived VIP（/etc/keepalived/keepalived.conf）" | tee -a "$INSTALL_LOG"
      echo "  参考配置模板: $KA_CONF_DIR/keepalived-master.conf.tpl" | tee -a "$INSTALL_LOG"
    fi
  fi
fi

# =====================================
# 步骤 3: 加载 KubeEdge 镜像
# =====================================
echo "" | tee -a "$INSTALL_LOG"
echo "[3/10] 加载 KubeEdge 镜像..." | tee -a "$INSTALL_LOG"

IMAGES_DIR=$(find "$SCRIPT_DIR" -type d -name "images" 2>/dev/null | head -1)
if [ -n "$IMAGES_DIR" ] && [ -d "$IMAGES_DIR" ]; then
  for i in $(seq 1 15); do
    if k3s ctr images ls >/dev/null 2>&1; then break; fi
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
  echo "  镜像加载: $LOADED 成功, $FAILED 失败" | tee -a "$INSTALL_LOG"
else
  echo "  ⚠️  未找到 images 目录，跳过镜像加载" | tee -a "$INSTALL_LOG"
fi

# =====================================
# 步骤 4: 安装 Helm
# =====================================
echo "" | tee -a "$INSTALL_LOG"
echo "[4/10] 安装 Helm..." | tee -a "$INSTALL_LOG"
if ! command -v helm &>/dev/null; then
  HELM_BIN=$(find "$SCRIPT_DIR" -maxdepth 2 -name "helm" -type f 2>/dev/null | head -1)
  if [ -n "$HELM_BIN" ]; then
    cp "$HELM_BIN" /usr/local/bin/helm
    chmod +x /usr/local/bin/helm
    echo "  ✓ helm 安装成功" | tee -a "$INSTALL_LOG"
  else
    echo "  ⚠️  未找到 helm，EdgeMesh 安装将跳过" | tee -a "$INSTALL_LOG"
  fi
else
  echo "  ✓ helm 已在 PATH" | tee -a "$INSTALL_LOG"
fi

# =====================================
# 步骤 5: 安装 keadm + 生成证书
# =====================================
echo "" | tee -a "$INSTALL_LOG"
echo "[5/10] 初始化 CloudCore 证书（keadm init）..." | tee -a "$INSTALL_LOG"

cp "$KEADM_BIN" /usr/local/bin/keadm
chmod +x /usr/local/bin/keadm

# 清理旧的 CloudCore（如果存在）
if $KUBECTL get deployment cloudcore -n kubeedge &>/dev/null 2>&1; then
  echo "  检测到已有 CloudCore，先清理..." | tee -a "$INSTALL_LOG"
  $KUBECTL delete deployment cloudcore -n kubeedge --timeout=60s >> "$INSTALL_LOG" 2>&1 || true
  $KUBECTL delete service cloudcore -n kubeedge >> "$INSTALL_LOG" 2>&1 || true
fi

# 创建命名空间
$KUBECTL create namespace kubeedge 2>/dev/null || echo "  kubeedge 命名空间已存在" | tee -a "$INSTALL_LOG"

# 使用 keadm init 生成证书和 Secret（使用 VIP 作为 advertise-address）
mkdir -p /etc/kubeedge
echo "  执行 keadm init 生成证书..." | tee -a "$INSTALL_LOG"
if keadm init \
  --advertise-address="$CLOUDCORE_VIP" \
  --kubeedge-version=v"$KUBEEDGE_VERSION" \
  --kube-config=/etc/rancher/k3s/k3s.yaml \
  --set cloudCore.modules.cloudHub.nodeLimit=1000 \
  >> "$INSTALL_LOG" 2>&1; then
  echo "  ✓ keadm init 成功，证书已生成" | tee -a "$INSTALL_LOG"
else
  echo "  ⚠️  keadm init 返回非零，检查是否有残留..." | tee -a "$INSTALL_LOG"
fi

# 等待 keadm 初始化完成（Secret 就绪）
echo "  等待 cloudcore Secret 就绪..." | tee -a "$INSTALL_LOG"
for i in $(seq 1 30); do
  if $KUBECTL get secret cloudcore -n kubeedge &>/dev/null 2>&1; then
    echo "  ✓ cloudcore Secret 已就绪" | tee -a "$INSTALL_LOG"
    break
  fi
  [ "$i" -eq 30 ] && echo "  ⚠️  Secret 等待超时" | tee -a "$INSTALL_LOG"
  sleep 3
done

# 删除 keadm 自动创建的 cloudcore Deployment（我们用 HA Deployment 替换）
$KUBECTL delete deployment cloudcore -n kubeedge --timeout=30s >> "$INSTALL_LOG" 2>&1 || true
echo "  ✓ 已删除 keadm 自动创建的单副本 Deployment，准备部署 HA 版本" | tee -a "$INSTALL_LOG"

# =====================================
# 步骤 6: 为 CloudCore 节点打标签
# =====================================
echo "" | tee -a "$INSTALL_LOG"
echo "[6/10] 为 CloudCore 节点打标签..." | tee -a "$INSTALL_LOG"

for node_ip in "${NODE_LIST[@]}"; do
  node_ip=$(echo "$node_ip" | tr -d ' ')
  # 通过 InternalIP 查找节点名
  NODE_NAME=$($KUBECTL get nodes -o json 2>/dev/null | \
    python3 -c "
import sys, json
data = json.load(sys.stdin)
for node in data['items']:
  addrs = node.get('status', {}).get('addresses', [])
  for addr in addrs:
    if addr.get('type') == 'InternalIP' and addr.get('address') == '$node_ip':
      print(node['metadata']['name'])
      break
" 2>/dev/null || echo "")

  if [ -n "$NODE_NAME" ]; then
    $KUBECTL label node "$NODE_NAME" cloudcore=ha-node --overwrite >> "$INSTALL_LOG" 2>&1 || true
    echo "  ✓ 节点 $NODE_NAME ($node_ip) 已标记 cloudcore=ha-node" | tee -a "$INSTALL_LOG"
  else
    echo "  ⚠️  未找到 IP=$node_ip 对应的节点，跳过标签（请手动执行: kubectl label node <name> cloudcore=ha-node）" | tee -a "$INSTALL_LOG"
  fi
done

# =====================================
# 步骤 7: 应用 HA 配置（YAML 资源）
# =====================================
echo "" | tee -a "$INSTALL_LOG"
echo "[7/10] 应用 CloudCore HA 配置..." | tee -a "$INSTALL_LOG"

MANIFESTS_DIR="$SCRIPT_DIR/manifests"
if [ ! -d "$MANIFESTS_DIR" ]; then
  echo "  ❌ 未找到 manifests 目录: $MANIFESTS_DIR" | tee -a "$INSTALL_LOG"
  exit 1
fi

# 7.1 应用 RBAC、CRD 等准备资源
echo "  应用 01-ha-prepare.yaml（RBAC + CRDs）..." | tee -a "$INSTALL_LOG"
if $KUBECTL apply -f "$MANIFESTS_DIR/01-ha-prepare.yaml" >> "$INSTALL_LOG" 2>&1; then
  echo "  ✓ RBAC 和 CRDs 已创建" | tee -a "$INSTALL_LOG"
else
  echo "  ⚠️  部分 RBAC/CRD 应用失败，可能已存在，继续..." | tee -a "$INSTALL_LOG"
fi

# 7.2 渲染并应用 ConfigMap（注入 VIP）
echo "  渲染 02-ha-configmap.yaml（VIP: $CLOUDCORE_VIP）..." | tee -a "$INSTALL_LOG"
sed "s/__CLOUDCORE_VIP__/${CLOUDCORE_VIP}/g" \
  "$MANIFESTS_DIR/02-ha-configmap.yaml" > /tmp/cloudcore-ha-configmap.yaml
if $KUBECTL apply -f /tmp/cloudcore-ha-configmap.yaml >> "$INSTALL_LOG" 2>&1; then
  echo "  ✓ ConfigMap 已应用（advertiseAddress: $CLOUDCORE_VIP）" | tee -a "$INSTALL_LOG"
else
  echo "  ✗ ConfigMap 应用失败" | tee -a "$INSTALL_LOG"
  exit 1
fi
rm -f /tmp/cloudcore-ha-configmap.yaml

# 7.3 渲染并应用 Deployment（注入副本数）
echo "  渲染 03-ha-deployment.yaml（replicas: $REPLICAS）..." | tee -a "$INSTALL_LOG"
sed "s/replicas: 3/replicas: ${REPLICAS}/g" \
  "$MANIFESTS_DIR/03-ha-deployment.yaml" > /tmp/cloudcore-ha-deployment.yaml
if $KUBECTL apply -f /tmp/cloudcore-ha-deployment.yaml >> "$INSTALL_LOG" 2>&1; then
  echo "  ✓ CloudCore HA Deployment 已应用（副本数: $REPLICAS）" | tee -a "$INSTALL_LOG"
else
  echo "  ✗ CloudCore HA Deployment 应用失败" | tee -a "$INSTALL_LOG"
  exit 1
fi
rm -f /tmp/cloudcore-ha-deployment.yaml

# 7.4 应用 Service
echo "  应用 08-service.yaml..." | tee -a "$INSTALL_LOG"
if $KUBECTL apply -f "$MANIFESTS_DIR/08-service.yaml" >> "$INSTALL_LOG" 2>&1; then
  echo "  ✓ CloudCore Service 已应用" | tee -a "$INSTALL_LOG"
fi

# =====================================
# 步骤 8: 部署 KubeEdge 附加组件
# =====================================
echo "" | tee -a "$INSTALL_LOG"
echo "[8/10] 部署 KubeEdge 附加组件..." | tee -a "$INSTALL_LOG"

# 8.1 部署 Controller Manager（RBAC 结构与已验证的 cloud/install/install.sh 保持一致）
cat > /tmp/kubeedge-controller-manager.yaml << EOF
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kubeedge-controller-manager
  namespace: kubeedge
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kubeedge-controller-manager
rules:
  - apiGroups: [""]
    resources: ["nodes", "pods", "configmaps", "secrets", "services",
                "endpoints", "namespaces", "serviceaccounts", "events"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["apps"]
    resources: ["deployments", "daemonsets", "replicasets", "statefulsets",
                "deployments/status", "daemonsets/status"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["apps.kubeedge.io"]
    resources: ["edgeapplications", "edgeapplications/status",
                "nodegroups", "nodegroups/status"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["policy"]
    resources: ["poddisruptionbudgets"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["coordination.k8s.io"]
    resources: ["leases"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["authentication.k8s.io"]
    resources: ["tokenreviews"]
    verbs: ["create"]
  - apiGroups: ["authorization.k8s.io"]
    resources: ["subjectaccessreviews"]
    verbs: ["create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kubeedge-controller-manager
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: kubeedge-controller-manager
subjects:
  - kind: ServiceAccount
    name: kubeedge-controller-manager
    namespace: kubeedge
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kubeedge-controller-manager-node-task
  labels:
    kubeedge: controller-manager
rules:
  - apiGroups: ["operations.kubeedge.io"]
    resources:
      - nodeupgradejobs
      - imageprepulljobs
      - configupdatejobs
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["operations.kubeedge.io"]
    resources:
      - nodeupgradejobs/status
      - imageprepulljobs/status
      - configupdatejobs/status
    verbs: ["get", "update", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kubeedge-controller-manager-node-task
subjects:
  - kind: ServiceAccount
    name: kubeedge-controller-manager
    namespace: kubeedge
roleRef:
  kind: ClusterRole
  name: kubeedge-controller-manager-node-task
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kubeedge-controller-manager
  namespace: kubeedge
  labels:
    kubeedge: controller-manager
spec:
  replicas: 1
  selector:
    matchLabels:
      kubeedge: controller-manager
  template:
    metadata:
      labels:
        kubeedge: controller-manager
    spec:
      serviceAccountName: kubeedge-controller-manager
      hostNetwork: true
      containers:
        - name: controller-manager
          image: kubeedge/controller-manager:v${KUBEEDGE_VERSION}
          imagePullPolicy: IfNotPresent
          command:
            - /usr/local/bin/controllermanager
          env:
            - name: NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 512Mi
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: node-role.kubernetes.io/control-plane
                    operator: Exists
              - matchExpressions:
                  - key: node-role.kubernetes.io/master
                    operator: Exists
      tolerations:
        - key: node-role.kubernetes.io/control-plane
          effect: NoSchedule
        - key: node-role.kubernetes.io/master
          effect: NoSchedule
EOF

$KUBECTL apply -f /tmp/kubeedge-controller-manager.yaml >> "$INSTALL_LOG" 2>&1 && \
  echo "  ✓ KubeEdge Controller Manager 已部署" | tee -a "$INSTALL_LOG" || \
  echo "  ⚠️  Controller Manager 部署失败" | tee -a "$INSTALL_LOG"
rm -f /tmp/kubeedge-controller-manager.yaml

# 8.2 安装 Istio CRDs（EdgeMesh 依赖）
# 离线包打包路径为 istio-crds/（build-release-cloudcore-ha.yml 中 mkdir -p istio-crds）
CRDS_DIR=$(find "$SCRIPT_DIR" -maxdepth 2 -type d -name "istio-crds" 2>/dev/null | head -1)
if [ -z "$CRDS_DIR" ]; then
  # 兼容旧路径 crds/istio
  CRDS_DIR=$(find "$SCRIPT_DIR" -maxdepth 3 -type d -name "istio" 2>/dev/null | head -1)
fi
if [ -n "$CRDS_DIR" ] && [ -n "$(ls -A "$CRDS_DIR" 2>/dev/null)" ]; then
  echo "  安装 Istio CRDs（$CRDS_DIR）..." | tee -a "$INSTALL_LOG"
  CRD_COUNT=0
  for crd_file in "$CRDS_DIR"/*.yaml; do
    [ -f "$crd_file" ] || continue
    $KUBECTL apply -f "$crd_file" >> "$INSTALL_LOG" 2>&1 && CRD_COUNT=$((CRD_COUNT + 1)) || true
  done
  echo "  ✓ 已安装 $CRD_COUNT 个 Istio CRDs" | tee -a "$INSTALL_LOG"
else
  echo "  ⚠️  未找到 Istio CRDs 目录，EdgeMesh 可能无法正常工作" | tee -a "$INSTALL_LOG"
fi

# =====================================
# 步骤 9: 配置 iptables NAT（CloudStream tunnel）
# =====================================
echo "" | tee -a "$INSTALL_LOG"
echo "[9/10] 配置 iptables NAT（kubectl logs/exec 支持）..." | tee -a "$INSTALL_LOG"

# 在本机及各 CloudCore 节点配置 iptables 规则
for node_ip in "${NODE_LIST[@]}"; do
  node_ip=$(echo "$node_ip" | tr -d ' ')
  echo "  配置节点 $node_ip 的 iptables 规则..." | tee -a "$INSTALL_LOG"
done

# 本机直接配置
iptables -t nat -A OUTPUT -p tcp --dport 10350 \
  -j DNAT --to-destination "${NODE_LIST[0]}":10003 >> "$INSTALL_LOG" 2>&1 || true
echo "  ✓ iptables NAT 规则已配置（CloudStream tunnel: 10350 → 10003）" | tee -a "$INSTALL_LOG"

# =====================================
# 等待 CloudCore 就绪
# =====================================
echo "" | tee -a "$INSTALL_LOG"
echo "  等待 CloudCore Pod 就绪（最多 120s）..." | tee -a "$INSTALL_LOG"
for i in $(seq 1 60); do
  READY_COUNT=$($KUBECTL -n kubeedge get pod -l kubeedge=cloudcore \
    --no-headers 2>/dev/null | grep -c "Running" || echo "0")
  if [ "$READY_COUNT" -ge 1 ]; then
    echo "  ✓ CloudCore Pod 就绪（$READY_COUNT/$REPLICAS 运行中）" | tee -a "$INSTALL_LOG"
    break
  fi
  [ "$i" -eq 60 ] && echo "  ⚠️  CloudCore 等待超时，请手动检查: kubectl get pods -n kubeedge" | tee -a "$INSTALL_LOG"
  sleep 2
done

# =====================================
# 可选: 安装 EdgeMesh
# =====================================
if [ "$SKIP_EDGEMESH" = "false" ]; then
  HELM_CHART_DIR="$SCRIPT_DIR/helm-charts"
  if [ -d "$HELM_CHART_DIR" ] && [ -f "$HELM_CHART_DIR/edgemesh.tgz" ] && command -v helm &>/dev/null; then
    echo "" | tee -a "$INSTALL_LOG"
    echo "[可选] 安装 EdgeMesh..." | tee -a "$INSTALL_LOG"

    EDGEMESH_PSK=$(openssl rand -base64 32)
    MASTER_NODE=$($KUBECTL get nodes --selector='node-role.kubernetes.io/control-plane' \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || \
      $KUBECTL get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    if helm status edgemesh -n kubeedge &>/dev/null 2>&1; then
      helm uninstall edgemesh -n kubeedge >> "$INSTALL_LOG" 2>&1 || true
      sleep 3
    fi

    if helm install edgemesh "$HELM_CHART_DIR/edgemesh.tgz" \
      --namespace kubeedge \
      --set agent.image=kubeedge/edgemesh-agent:v1.17.0 \
      --set agent.psk="$EDGEMESH_PSK" \
      --set agent.relayNodes[0].nodeName="$MASTER_NODE" \
      --set "agent.relayNodes[0].advertiseAddress={$CLOUDCORE_VIP}" \
      >> "$INSTALL_LOG" 2>&1; then
      echo "$EDGEMESH_PSK" > "$SCRIPT_DIR/edgemesh-psk.txt"
      echo "  ✓ EdgeMesh 安装成功，PSK 已保存至: $SCRIPT_DIR/edgemesh-psk.txt" | tee -a "$INSTALL_LOG"
    else
      echo "  ⚠️  EdgeMesh 安装失败，请查看日志: $INSTALL_LOG" | tee -a "$INSTALL_LOG"
    fi
  fi
fi

# =====================================
# 步骤 10: 获取并保存 Edge Token
# =====================================
echo "" | tee -a "$INSTALL_LOG"
echo "[10/10] 获取 Edge 接入 Token..." | tee -a "$INSTALL_LOG"

EDGE_TOKEN=""
TOKEN_DIR="/etc/kubeedge/tokens"
mkdir -p "$TOKEN_DIR"

for i in $(seq 1 30); do
  if $KUBECTL get secret -n kubeedge tokensecret &>/dev/null 2>&1; then
    EDGE_TOKEN=$($KUBECTL get secret -n kubeedge tokensecret \
      -o jsonpath='{.data.tokendata}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
    [ -n "$EDGE_TOKEN" ] && break
  fi
  sleep 3
done

if [ -z "$EDGE_TOKEN" ]; then
  EDGE_TOKEN=$(keadm gettoken \
    --kubeedge-version=v"$KUBEEDGE_VERSION" \
    --kube-config=/etc/rancher/k3s/k3s.yaml 2>/dev/null || echo "")
fi

TOKEN_FILE="$TOKEN_DIR/edge-token.txt"
if [ -n "$EDGE_TOKEN" ]; then
  cat > "$TOKEN_FILE" << EOF
{
  "cloudVIP": "${CLOUDCORE_VIP}",
  "cloudPort": 10000,
  "token": "${EDGE_TOKEN}",
  "generatedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "edgeConnectCommand": "sudo ./install.sh ${CLOUDCORE_VIP}:10000 ${EDGE_TOKEN} <edge-node-name>"
}
EOF
  chmod 600 "$TOKEN_FILE"
  echo "  ✓ Edge Token 已保存至: $TOKEN_FILE" | tee -a "$INSTALL_LOG"
else
  echo "  ⚠️  未能获取 Token，请稍后执行: keadm gettoken" | tee -a "$INSTALL_LOG"
fi

# =====================================
# 安装完成汇总
# =====================================
echo "" | tee -a "$INSTALL_LOG"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee -a "$INSTALL_LOG"
echo "=== CloudCore HA 安装完成 ===" | tee -a "$INSTALL_LOG"
echo "" | tee -a "$INSTALL_LOG"
echo "CloudCore VIP:  $CLOUDCORE_VIP" | tee -a "$INSTALL_LOG"
echo "副本数:         $REPLICAS" | tee -a "$INSTALL_LOG"
echo "KubeEdge 版本:  v$KUBEEDGE_VERSION" | tee -a "$INSTALL_LOG"
echo "" | tee -a "$INSTALL_LOG"
echo "Pod 状态:" | tee -a "$INSTALL_LOG"
$KUBECTL get pods -n kubeedge -o wide 2>/dev/null | tee -a "$INSTALL_LOG"
echo "" | tee -a "$INSTALL_LOG"
echo "【keepalived 提醒】" | tee -a "$INSTALL_LOG"
if [ "$SKIP_KEEPALIVED" = "true" ]; then
  echo "  请在各 CloudCore 节点配置 keepalived（参考 $SCRIPT_DIR/keepalived/）" | tee -a "$INSTALL_LOG"
fi
echo "" | tee -a "$INSTALL_LOG"
echo "【边缘节点接入命令】" | tee -a "$INSTALL_LOG"
if [ -n "$EDGE_TOKEN" ]; then
  echo "  sudo ./install.sh ${CLOUDCORE_VIP}:10000 '${EDGE_TOKEN}' <edge-node-name>" | tee -a "$INSTALL_LOG"
fi
echo "" | tee -a "$INSTALL_LOG"
echo "验证命令:" | tee -a "$INSTALL_LOG"
echo "  kubectl get pods -n kubeedge          # CloudCore / EdgeMesh 状态" | tee -a "$INSTALL_LOG"
echo "  kubectl get nodes                     # 所有节点（含边缘节点加入后）" | tee -a "$INSTALL_LOG"
echo "  helm list -n kubeedge                 # EdgeMesh Helm 状态" | tee -a "$INSTALL_LOG"
echo "安装日志: $INSTALL_LOG" | tee -a "$INSTALL_LOG"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee -a "$INSTALL_LOG"

# 打印 token 到 stdout
if [ -n "$EDGE_TOKEN" ]; then
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "边缘节点接入 Token（保存用于 edgecore 安装）:"
  echo "CloudCore VIP: $CLOUDCORE_VIP:10000"
  echo "Token: $EDGE_TOKEN"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
fi
