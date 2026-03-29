# KubeEdge / Kubernetes 原生 API 接口文档

> **API Server 地址：** `https://<apiserver-ip>:6443`  
> **协议：** HTTPS（生产环境建议启用 TLS 校验，调试时可用 `-k` 跳过）  
> **数据格式：** JSON（Content-Type: application/json）  
> **版本：** KubeEdge v1beta1 / Kubernetes v1

---

## 目录

- [概述](#概述)
- [认证方式](#认证方式)
- [公共说明](#公共说明)
- [KubeEdge 核心资源](#kubeedge-核心资源)
  - [设备 Device](#设备-device)
  - [设备模型 DeviceModel](#设备模型-devicemodel)
  - [节点组 NodeGroup](#节点组-nodegroup)
  - [边缘应用 EdgeApplication](#边缘应用-edgeapplication)
  - [规则 Rule](#规则-rule)
  - [规则端点 RuleEndpoint](#规则端点-ruleendpoint)
- [Kubernetes 基础资源](#kubernetes-基础资源)
  - [版本信息 Version](#版本信息-version)
  - [命名空间 Namespace](#命名空间-namespace)
  - [节点 Node](#节点-node)
  - [工作负载 Deployment](#工作负载-deployment)
  - [容器组 Pod](#容器组-pod)
  - [服务 Service](#服务-service)
  - [配置字典 ConfigMap](#配置字典-configmap)
  - [密钥 Secret](#密钥-secret)
  - [自定义资源定义 CRD](#自定义资源定义-crd)
- [权限管理 RBAC](#权限管理-rbac)
  - [角色 Role](#角色-role)
  - [角色绑定 RoleBinding](#角色绑定-rolebinding)
  - [集群角色 ClusterRole](#集群角色-clusterrole)
  - [集群角色绑定 ClusterRoleBinding](#集群角色绑定-clusterrolebinding)
  - [服务账号 ServiceAccount](#服务账号-serviceaccount)
- [附录：接口一览表](#附录接口一览表)

---

## 概述

本文档描述直接调用 Kubernetes API Server 的原生 REST 接口，适用于第三方平台集成对接。

KubeEdge 扩展了 Kubernetes，其资源（Device、DeviceModel、NodeGroup 等）以 CRD 形式注册，通过标准 Kubernetes API Server 访问，格式与原生 K8s 资源完全一致。

**API 路径规则：**

| 类型 | 路径格式 |
|------|---------|
| Kubernetes 核心资源（Pod、Node 等） | `/api/v1/...` |
| Kubernetes 扩展资源（Deployment 等） | `/apis/<group>/<version>/...` |
| KubeEdge CRD 资源 | `/apis/<kubeedge-group>/<version>/...` |

---

## 认证方式

所有请求均需在 HTTP Header 中携带 Bearer Token：

```http
Authorization: Bearer <your-token>
```

**获取 Token 方法（kubectl）：**

```bash
# 方式一：获取指定 ServiceAccount 的 Token（适合 k8s >= 1.24）
kubectl create token <serviceaccount-name> -n <namespace>

# 方式二：从 Secret 中读取 Token（k8s < 1.24 或长期 Token）
kubectl -n kube-system get secret \
  $(kubectl -n kube-system get sa admin-user -o jsonpath='{.secrets[0].name}') \
  -o jsonpath='{.data.token}' | base64 -d
```

**curl 示例模板：**

```bash
curl -k \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  "https://<apiserver-ip>:6443/<path>"
```

> `-k` 参数跳过 TLS 证书校验，生产环境建议替换为 `--cacert /path/to/ca.crt`

---

## 公共说明

### 列表接口公共查询参数

所有列表（List）接口均支持以下原生 Kubernetes 查询参数：

| 参数名 | 类型 | 说明 |
|-------|------|------|
| `limit` | integer | 返回条数上限，配合 `continue` 实现分页 |
| `continue` | string | 分页游标，由上一次请求的响应中 `metadata.continue` 字段获取 |
| `labelSelector` | string | 按 Label 过滤，如 `app=my-app,zone=edge` |
| `fieldSelector` | string | 按字段过滤，如 `metadata.name=my-device` 或 `status.phase=Running` |
| `resourceVersion` | string | 指定资源版本，用于 Watch 增量更新 |
| `watch` | boolean | 设为 `true` 时开启 Watch 模式（长连接，推送变更事件） |

**分页示例：**

```bash
# 第一页，每页 20 条
curl -k -H "Authorization: Bearer <token>" \
  "https://<apiserver>:6443/apis/devices.kubeedge.io/v1beta1/namespaces/default/devices?limit=20"

# 用上一次响应中的 metadata.continue 获取下一页
curl -k -H "Authorization: Bearer <token>" \
  "https://<apiserver>:6443/apis/devices.kubeedge.io/v1beta1/namespaces/default/devices?limit=20&continue=<continue-token>"
```

### HTTP 方法语义

| 方法 | 说明 |
|------|------|
| `GET` | 查询资源（列表或单个） |
| `POST` | 创建资源 |
| `PUT` | 全量更新资源（需提供完整对象） |
| `PATCH` | 局部更新资源（推荐 `application/merge-patch+json`） |
| `DELETE` | 删除资源 |

### 状态码说明

| 状态码 | 说明 |
|-------|------|
| `200 OK` | 请求成功 |
| `201 Created` | 创建成功 |
| `204 No Content` | 删除成功，无响应体 |
| `400 Bad Request` | 请求参数错误 |
| `401 Unauthorized` | Token 无效或未提供 |
| `403 Forbidden` | 无操作权限 |
| `404 Not Found` | 资源不存在 |
| `409 Conflict` | 资源已存在（创建时重名） |
| `422 Unprocessable Entity` | 请求体校验失败 |
| `500 Internal Server Error` | 服务端错误 |

**错误响应体示例：**

```json
{
  "kind": "Status",
  "apiVersion": "v1",
  "status": "Failure",
  "message": "devices.devices.kubeedge.io \"my-device\" not found",
  "reason": "NotFound",
  "code": 404
}
```

---

## KubeEdge 核心资源

> API Group：`devices.kubeedge.io`，版本：`v1beta1`

---

### 设备 Device

设备（Device）对应 KubeEdge 管理的物理 IoT/边缘设备，支持属性读写和状态上报（数字孪生）。

**API Group / Version：** `devices.kubeedge.io/v1beta1`  
**资源名：** `devices`（复数）  
**作用域：** Namespace 级别

---

#### 获取所有命名空间的设备列表

```
GET https://<apiserver>:6443/apis/devices.kubeedge.io/v1beta1/devices
```

**请求示例：**

```bash
curl -k -H "Authorization: Bearer <token>" \
  "https://192.168.122.231:6443/apis/devices.kubeedge.io/v1beta1/devices"
```

---

#### 获取指定命名空间的设备列表

```
GET https://<apiserver>:6443/apis/devices.kubeedge.io/v1beta1/namespaces/{namespace}/devices
```

**路径参数：**

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `namespace` | string | 是 | 命名空间名称，如 `default` |

**查询参数：**

| 参数 | 说明 |
|------|------|
| `limit` | 返回数量上限 |
| `labelSelector` | 按 Label 筛选，如 `zone=factory` |
| `fieldSelector` | 按字段筛选，如 `metadata.name=sensor-01` |

**请求示例：**

```bash
curl -k -H "Authorization: Bearer <token>" \
  "https://192.168.122.231:6443/apis/devices.kubeedge.io/v1beta1/namespaces/default/devices"

# 按名称过滤
curl -k -H "Authorization: Bearer <token>" \
  "https://192.168.122.231:6443/apis/devices.kubeedge.io/v1beta1/namespaces/default/devices?fieldSelector=metadata.name=sensor-simulator-instance"
```

**响应示例：**

```json
{
  "apiVersion": "devices.kubeedge.io/v1beta1",
  "kind": "DeviceList",
  "metadata": {
    "resourceVersion": "12345",
    "continue": ""           // 分页游标，为空表示已是最后一页
  },
  "items": [
    {
      "apiVersion": "devices.kubeedge.io/v1beta1",
      "kind": "Device",
      "metadata": {
        "name": "sensor-simulator-instance",
        "namespace": "default",
        "uid": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
        "resourceVersion": "1001",
        "creationTimestamp": "2025-01-01T00:00:00Z",
        "labels": {
          "zone": "factory"
        }
      },
      "spec": {
        "deviceModelRef": {
          "name": "sensor-model"       // 关联的设备模型名称
        },
        "nodeName": "edge-node-01",    // 设备所绑定的边缘节点名称
        "properties": [
          {
            "name": "temperature",
            "desired": {
              "value": "25"            // 期望值（云端下发）
            },
            "visitors": {
              "protocolName": "modbus",
              "configData": {}
            }
          }
        ]
      },
      "status": {
        "twins": [
          {
            "propertyName": "temperature",
            "reported": {
              "value": "23.5",         // 设备实际上报值
              "metadata": {
                "timestamp": "1700000000000",
                "type": "double"
              }
            },
            "desired": {
              "value": "25",           // 云端期望值（与 spec 同步）
              "metadata": {
                "timestamp": "1700000000000"
              }
            }
          }
        ]
      }
    }
  ]
}
```

---

#### 获取指定设备详情

```
GET https://<apiserver>:6443/apis/devices.kubeedge.io/v1beta1/namespaces/{namespace}/devices/{name}
```

**路径参数：**

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `namespace` | string | 是 | 命名空间名称 |
| `name` | string | 是 | 设备名称 |

**请求示例：**

```bash
curl -k -H "Authorization: Bearer <token>" \
  "https://192.168.122.231:6443/apis/devices.kubeedge.io/v1beta1/namespaces/default/devices/sensor-simulator-instance"
```

**响应：** 返回单个 Device 完整对象（结构同列表中的 items 元素）

---

#### 创建设备

```
POST https://<apiserver>:6443/apis/devices.kubeedge.io/v1beta1/namespaces/{namespace}/devices
```

**请求体：**

```json
{
  "apiVersion": "devices.kubeedge.io/v1beta1",
  "kind": "Device",
  "metadata": {
    "name": "my-device",             // 设备名称，同命名空间内唯一
    "namespace": "default",
    "labels": {
      "zone": "factory"
    }
  },
  "spec": {
    "deviceModelRef": {
      "name": "sensor-model"         // 必须引用已存在的 DeviceModel 名称
    },
    "nodeName": "edge-node-01",      // 必须是已注册的边缘节点名称
    "properties": [
      {
        "name": "temperature",       // 属性名，需与 DeviceModel 中定义的属性名一致
        "desired": {
          "value": "25"              // 期望值
        },
        "visitors": {
          "protocolName": "modbus",  // 协议类型：modbus / opcua / bluetooth 等
          "configData": {
            "register": "0x0001"
          }
        }
      }
    ]
  }
}
```

**请求示例：**

```bash
curl -k -X POST \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{ ...上述 JSON 内容... }' \
  "https://192.168.122.231:6443/apis/devices.kubeedge.io/v1beta1/namespaces/default/devices"
```

**响应：** `201 Created`，返回创建后的 Device 完整对象。

---

#### 更新设备（全量替换）

```
PUT https://<apiserver>:6443/apis/devices.kubeedge.io/v1beta1/namespaces/{namespace}/devices/{name}
```

> **注意：** PUT 为全量替换，请求体必须包含完整对象（含 `metadata.resourceVersion`）

**请求体：** Device 完整对象（务必包含 `metadata.resourceVersion`，否则会报冲突错误）

```json
{
  "apiVersion": "devices.kubeedge.io/v1beta1",
  "kind": "Device",
  "metadata": {
    "name": "my-device",
    "namespace": "default",
    "resourceVersion": "1001"    // 必须携带，从 GET 响应中获取
  },
  "spec": {
    "deviceModelRef": { "name": "sensor-model" },
    "nodeName": "edge-node-01",
    "properties": [
      {
        "name": "temperature",
        "desired": { "value": "30" }  // 修改期望值
      }
    ]
  }
}
```

**响应：** `200 OK`，返回更新后的 Device 对象。

---

#### 局部更新设备（推荐）

```
PATCH https://<apiserver>:6443/apis/devices.kubeedge.io/v1beta1/namespaces/{namespace}/devices/{name}
```

**请求头：** `Content-Type: application/merge-patch+json`

**请求体（仅包含需要修改的字段）：**

```json
{
  "spec": {
    "properties": [
      {
        "name": "temperature",
        "desired": { "value": "30" }
      }
    ]
  }
}
```

**请求示例：**

```bash
curl -k -X PATCH \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/merge-patch+json" \
  -d '{"spec":{"properties":[{"name":"temperature","desired":{"value":"30"}}]}}' \
  "https://192.168.122.231:6443/apis/devices.kubeedge.io/v1beta1/namespaces/default/devices/my-device"
```

**响应：** `200 OK`

---

#### 删除设备

```
DELETE https://<apiserver>:6443/apis/devices.kubeedge.io/v1beta1/namespaces/{namespace}/devices/{name}
```

**请求示例：**

```bash
curl -k -X DELETE \
  -H "Authorization: Bearer <token>" \
  "https://192.168.122.231:6443/apis/devices.kubeedge.io/v1beta1/namespaces/default/devices/my-device"
```

**响应：** `200 OK`（返回删除的对象）或 `204 No Content`

---

### 设备模型 DeviceModel

设备模型（DeviceModel）定义一类设备的属性模板（属性名、类型、单位、访问权限等），设备实例必须引用某个 DeviceModel。

**API Group / Version：** `devices.kubeedge.io/v1beta1`  
**资源名：** `devicemodels`  
**作用域：** Namespace 级别

---

#### 获取设备模型列表

```
GET https://<apiserver>:6443/apis/devices.kubeedge.io/v1beta1/namespaces/{namespace}/devicemodels
```

**请求示例：**

```bash
curl -k -H "Authorization: Bearer <token>" \
  "https://192.168.122.231:6443/apis/devices.kubeedge.io/v1beta1/namespaces/default/devicemodels"
```

---

#### 获取所有命名空间的设备模型列表

```
GET https://<apiserver>:6443/apis/devices.kubeedge.io/v1beta1/devicemodels
```

---

#### 获取指定设备模型详情

```
GET https://<apiserver>:6443/apis/devices.kubeedge.io/v1beta1/namespaces/{namespace}/devicemodels/{name}
```

**请求示例：**

```bash
curl -k -H "Authorization: Bearer <token>" \
  "https://192.168.122.231:6443/apis/devices.kubeedge.io/v1beta1/namespaces/default/devicemodels/sensor-model"
```

**响应示例：**

```json
{
  "apiVersion": "devices.kubeedge.io/v1beta1",
  "kind": "DeviceModel",
  "metadata": {
    "name": "sensor-model",
    "namespace": "default",
    "creationTimestamp": "2025-01-01T00:00:00Z"
  },
  "spec": {
    "properties": [
      {
        "name": "temperature",           // 属性名称
        "description": "环境温度",
        "type": "double",                // 属性数据类型：int / double / float / string / boolean / bytes
        "accessMode": "ReadOnly",        // 访问模式：ReadOnly（只读） / ReadWrite（读写）
        "minimum": "-40",                // 最小值（数值类型）
        "maximum": "100",                // 最大值（数值类型）
        "unit": "℃"                      // 单位
      },
      {
        "name": "switch",
        "description": "控制开关",
        "type": "boolean",
        "accessMode": "ReadWrite"        // ReadWrite 表示可通过 desired 值下发控制指令
      }
    ]
  }
}
```

---

#### 创建设备模型

```
POST https://<apiserver>:6443/apis/devices.kubeedge.io/v1beta1/namespaces/{namespace}/devicemodels
```

**请求体：**

```json
{
  "apiVersion": "devices.kubeedge.io/v1beta1",
  "kind": "DeviceModel",
  "metadata": {
    "name": "sensor-model",
    "namespace": "default"
  },
  "spec": {
    "properties": [
      {
        "name": "temperature",
        "description": "环境温度",
        "type": "double",
        "accessMode": "ReadOnly",
        "unit": "℃"
      }
    ]
  }
}
```

**响应：** `201 Created`

---

#### 更新设备模型

```
PUT https://<apiserver>:6443/apis/devices.kubeedge.io/v1beta1/namespaces/{namespace}/devicemodels/{name}
```

或局部更新：

```
PATCH https://<apiserver>:6443/apis/devices.kubeedge.io/v1beta1/namespaces/{namespace}/devicemodels/{name}
```

**请求头（PATCH）：** `Content-Type: application/merge-patch+json`

---

#### 删除设备模型

```
DELETE https://<apiserver>:6443/apis/devices.kubeedge.io/v1beta1/namespaces/{namespace}/devicemodels/{name}
```

---

### 节点组 NodeGroup

节点组（NodeGroup）是集群级别资源，用于将多个边缘节点分组，方便批量部署和管理。

**API Group / Version：** `apps.kubeedge.io/v1alpha1`  
**资源名：** `nodegroups`  
**作用域：** Cluster 级别（不区分命名空间）

---

#### 获取节点组列表

```
GET https://<apiserver>:6443/apis/apps.kubeedge.io/v1alpha1/nodegroups
```

**请求示例：**

```bash
curl -k -H "Authorization: Bearer <token>" \
  "https://192.168.122.231:6443/apis/apps.kubeedge.io/v1alpha1/nodegroups"
```

**响应示例：**

```json
{
  "apiVersion": "apps.kubeedge.io/v1alpha1",
  "kind": "NodeGroupList",
  "items": [
    {
      "apiVersion": "apps.kubeedge.io/v1alpha1",
      "kind": "NodeGroup",
      "metadata": {
        "name": "factory-zone-a",
        "creationTimestamp": "2025-01-01T00:00:00Z"
      },
      "spec": {
        "nodes": ["edge-node-01", "edge-node-02"],  // 明确指定节点名称列表
        "matchLabels": {
          "zone": "factory-a"                        // 或通过 Label 自动匹配节点
        }
      },
      "status": {
        "nodeStatuses": [
          {
            "nodeName": "edge-node-01",
            "readyCondition": "True",
            "schedulableCondition": "True"
          }
        ]
      }
    }
  ]
}
```

---

#### 获取指定节点组详情

```
GET https://<apiserver>:6443/apis/apps.kubeedge.io/v1alpha1/nodegroups/{name}
```

**请求示例：**

```bash
curl -k -H "Authorization: Bearer <token>" \
  "https://192.168.122.231:6443/apis/apps.kubeedge.io/v1alpha1/nodegroups/factory-zone-a"
```

---

#### 创建节点组

```
POST https://<apiserver>:6443/apis/apps.kubeedge.io/v1alpha1/nodegroups
```

**请求体：**

```json
{
  "apiVersion": "apps.kubeedge.io/v1alpha1",
  "kind": "NodeGroup",
  "metadata": {
    "name": "factory-zone-a"
  },
  "spec": {
    "nodes": ["edge-node-01", "edge-node-02"]
  }
}
```

---

#### 更新节点组

```
PUT https://<apiserver>:6443/apis/apps.kubeedge.io/v1alpha1/nodegroups/{name}
```

```
PATCH https://<apiserver>:6443/apis/apps.kubeedge.io/v1alpha1/nodegroups/{name}
```

**请求头（PATCH）：** `Content-Type: application/merge-patch+json`

---

#### 删除节点组

```
DELETE https://<apiserver>:6443/apis/apps.kubeedge.io/v1alpha1/nodegroups/{name}
```

---

### 边缘应用 EdgeApplication

EdgeApplication 支持跨节点组的差异化应用部署，实现一次定义、多组差异化交付。

**API Group / Version：** `apps.kubeedge.io/v1alpha1`  
**资源名：** `edgeapplications`  
**作用域：** Namespace 级别

---

#### 获取边缘应用列表

```
GET https://<apiserver>:6443/apis/apps.kubeedge.io/v1alpha1/namespaces/{namespace}/edgeapplications
```

**请求示例：**

```bash
curl -k -H "Authorization: Bearer <token>" \
  "https://192.168.122.231:6443/apis/apps.kubeedge.io/v1alpha1/namespaces/default/edgeapplications"
```

---

#### 获取所有命名空间的边缘应用列表

```
GET https://<apiserver>:6443/apis/apps.kubeedge.io/v1alpha1/edgeapplications
```

---

#### 获取指定边缘应用详情

```
GET https://<apiserver>:6443/apis/apps.kubeedge.io/v1alpha1/namespaces/{namespace}/edgeapplications/{name}
```

**请求示例：**

```bash
curl -k -H "Authorization: Bearer <token>" \
  "https://192.168.122.231:6443/apis/apps.kubeedge.io/v1alpha1/namespaces/default/edgeapplications/my-edge-app"
```

**响应示例：**

```json
{
  "apiVersion": "apps.kubeedge.io/v1alpha1",
  "kind": "EdgeApplication",
  "metadata": {
    "name": "my-edge-app",
    "namespace": "default"
  },
  "spec": {
    "workloadScope": {
      "targetNodeGroups": [
        {
          "name": "factory-zone-a",      // 部署目标节点组名称
          "overrides": [                  // 差异化覆盖配置（可选）
            {
              "imageOverriders": [
                {
                  "component": "Tag",
                  "operator": "replace",
                  "value": "v1.0.1"       // 覆盖镜像 Tag
                }
              ]
            }
          ]
        }
      ]
    },
    "workloadTemplate": {
      "manifests": []                     // 工作负载模板（Deployment 等的 raw JSON）
    }
  }
}
```

---

#### 创建边缘应用

```
POST https://<apiserver>:6443/apis/apps.kubeedge.io/v1alpha1/namespaces/{namespace}/edgeapplications
```

---

#### 更新边缘应用

```
PUT https://<apiserver>:6443/apis/apps.kubeedge.io/v1alpha1/namespaces/{namespace}/edgeapplications/{name}
```

```
PATCH https://<apiserver>:6443/apis/apps.kubeedge.io/v1alpha1/namespaces/{namespace}/edgeapplications/{name}
```

**请求头（PATCH）：** `Content-Type: application/merge-patch+json`

---

#### 删除边缘应用

```
DELETE https://<apiserver>:6443/apis/apps.kubeedge.io/v1alpha1/namespaces/{namespace}/edgeapplications/{name}
```

---

### 规则 Rule

Rule 定义 KubeEdge 消息路由规则，控制云边/边边之间的消息流向，依赖 RuleEndpoint 作为端点。

**API Group / Version：** `rules.kubeedge.io/v1`  
**资源名：** `rules`  
**作用域：** Namespace 级别

---

#### 获取规则列表

```
GET https://<apiserver>:6443/apis/rules.kubeedge.io/v1/namespaces/{namespace}/rules
```

**请求示例：**

```bash
curl -k -H "Authorization: Bearer <token>" \
  "https://192.168.122.231:6443/apis/rules.kubeedge.io/v1/namespaces/default/rules"
```

---

#### 获取所有命名空间规则

```
GET https://<apiserver>:6443/apis/rules.kubeedge.io/v1/rules
```

---

#### 获取指定规则详情

```
GET https://<apiserver>:6443/apis/rules.kubeedge.io/v1/namespaces/{namespace}/rules/{name}
```

**响应示例：**

```json
{
  "apiVersion": "rules.kubeedge.io/v1",
  "kind": "Rule",
  "metadata": {
    "name": "my-rule",
    "namespace": "default"
  },
  "spec": {
    "source": "my-rest-endpoint",          // 消息来源端点名称（RuleEndpoint）
    "sourceResource": {
      "path": "/test"                       // 消息来源的资源路径（REST 模式）
    },
    "target": "my-eventbus-endpoint",      // 消息目标端点名称（RuleEndpoint）
    "targetResource": {
      "topic": "device/data/upload"        // 消息目标 MQTT Topic（EventBus 模式）
    }
  },
  "status": {
    "nodeStatus": []
  }
}
```

---

#### 创建规则

```
POST https://<apiserver>:6443/apis/rules.kubeedge.io/v1/namespaces/{namespace}/rules
```

---

#### 更新规则

```
PUT https://<apiserver>:6443/apis/rules.kubeedge.io/v1/namespaces/{namespace}/rules/{name}
```

```
PATCH https://<apiserver>:6443/apis/rules.kubeedge.io/v1/namespaces/{namespace}/rules/{name}
```

**请求头（PATCH）：** `Content-Type: application/merge-patch+json`

---

#### 删除规则

```
DELETE https://<apiserver>:6443/apis/rules.kubeedge.io/v1/namespaces/{namespace}/rules/{name}
```

---

### 规则端点 RuleEndpoint

RuleEndpoint 定义消息路由的源或目标端点，类型包括 `rest`（HTTP 服务）、`eventbus`（边缘 MQTT 总线）、`servicebus`（边缘服务总线）。

**API Group / Version：** `rules.kubeedge.io/v1`  
**资源名：** `ruleendpoints`  
**作用域：** Namespace 级别

---

#### 获取规则端点列表

```
GET https://<apiserver>:6443/apis/rules.kubeedge.io/v1/namespaces/{namespace}/ruleendpoints
```

**请求示例：**

```bash
curl -k -H "Authorization: Bearer <token>" \
  "https://192.168.122.231:6443/apis/rules.kubeedge.io/v1/namespaces/default/ruleendpoints"
```

---

#### 获取所有命名空间规则端点

```
GET https://<apiserver>:6443/apis/rules.kubeedge.io/v1/ruleendpoints
```

---

#### 获取指定规则端点详情

```
GET https://<apiserver>:6443/apis/rules.kubeedge.io/v1/namespaces/{namespace}/ruleendpoints/{name}
```

**响应示例：**

```json
{
  "apiVersion": "rules.kubeedge.io/v1",
  "kind": "RuleEndpoint",
  "metadata": {
    "name": "my-rest-endpoint",
    "namespace": "default"
  },
  "spec": {
    "ruleEndpointType": "rest",    // 端点类型：rest / eventbus / servicebus
    "properties": {
      "url": "http://my-service.default.svc.cluster.local:80"  // rest 类型的目标地址
    }
  }
}
```

---

#### 创建规则端点

```
POST https://<apiserver>:6443/apis/rules.kubeedge.io/v1/namespaces/{namespace}/ruleendpoints
```

---

#### 更新规则端点

```
PUT https://<apiserver>:6443/apis/rules.kubeedge.io/v1/namespaces/{namespace}/ruleendpoints/{name}
```

```
PATCH https://<apiserver>:6443/apis/rules.kubeedge.io/v1/namespaces/{namespace}/ruleendpoints/{name}
```

**请求头（PATCH）：** `Content-Type: application/merge-patch+json`

---

#### 删除规则端点

```
DELETE https://<apiserver>:6443/apis/rules.kubeedge.io/v1/namespaces/{namespace}/ruleendpoints/{name}
```

---

## Kubernetes 基础资源

---

### 版本信息 Version

#### 获取集群版本

```
GET https://<apiserver>:6443/version
```

**请求示例：**

```bash
curl -k -H "Authorization: Bearer <token>" \
  "https://192.168.122.231:6443/version"
```

**响应示例：**

```json
{
  "major": "1",
  "minor": "28",
  "gitVersion": "v1.28.0",
  "gitCommit": "abc123",
  "buildDate": "2024-01-01T00:00:00Z",
  "goVersion": "go1.21.0",
  "platform": "linux/amd64"
}
```

---

### 命名空间 Namespace

**API Group / Version：** `v1`（核心 API）  
**资源名：** `namespaces`  
**作用域：** Cluster 级别

---

#### 获取所有命名空间

```
GET https://<apiserver>:6443/api/v1/namespaces
```

**请求示例：**

```bash
curl -k -H "Authorization: Bearer <token>" \
  "https://192.168.122.231:6443/api/v1/namespaces"
```

**响应示例：**

```json
{
  "kind": "NamespaceList",
  "apiVersion": "v1",
  "items": [
    {
      "metadata": {
        "name": "default",
        "creationTimestamp": "2025-01-01T00:00:00Z"
      },
      "spec": {
        "finalizers": ["kubernetes"]
      },
      "status": {
        "phase": "Active"     // 命名空间状态：Active / Terminating
      }
    }
  ]
}
```

---

#### 获取指定命名空间详情

```
GET https://<apiserver>:6443/api/v1/namespaces/{name}
```

---

### 节点 Node

**API Group / Version：** `v1`（核心 API）  
**资源名：** `nodes`  
**作用域：** Cluster 级别

---

#### 获取节点列表

```
GET https://<apiserver>:6443/api/v1/nodes
```

**请求示例：**

```bash
curl -k -H "Authorization: Bearer <token>" \
  "https://192.168.122.231:6443/api/v1/nodes"

# 只查边缘节点（按 Label 过滤）
curl -k -H "Authorization: Bearer <token>" \
  "https://192.168.122.231:6443/api/v1/nodes?labelSelector=node-role.kubernetes.io/edge="
```

**响应示例（节点关键字段）：**

```json
{
  "kind": "NodeList",
  "apiVersion": "v1",
  "items": [
    {
      "metadata": {
        "name": "edge-node-01",
        "labels": {
          "kubernetes.io/hostname": "edge-node-01",
          "node-role.kubernetes.io/edge": ""      // KubeEdge 边缘节点标识
        }
      },
      "spec": {
        "taints": [
          {
            "key": "node-role.kubernetes.io/edge",
            "effect": "NoSchedule"                // 边缘节点的默认污点
          }
        ]
      },
      "status": {
        "conditions": [
          {
            "type": "Ready",
            "status": "True"                      // 节点就绪状态
          }
        ],
        "addresses": [
          {
            "type": "InternalIP",
            "address": "192.168.1.100"           // 节点内网 IP
          }
        ],
        "nodeInfo": {
          "kubeletVersion": "v1.28.0",
          "osImage": "Ubuntu 22.04",
          "architecture": "amd64"
        }
      }
    }
  ]
}
```

---

#### 获取指定节点详情

```
GET https://<apiserver>:6443/api/v1/nodes/{name}
```

**请求示例：**

```bash
curl -k -H "Authorization: Bearer <token>" \
  "https://192.168.122.231:6443/api/v1/nodes/edge-node-01"
```

---

#### 更新节点（局部更新，常用于修改 Labels/Annotations）

```
PATCH https://<apiserver>:6443/api/v1/nodes/{name}
```

**请求头：** `Content-Type: application/merge-patch+json`

**请求示例（添加标签）：**

```bash
curl -k -X PATCH \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/merge-patch+json" \
  -d '{"metadata":{"labels":{"zone":"factory-a"}}}' \
  "https://192.168.122.231:6443/api/v1/nodes/edge-node-01"
```

---

#### 删除节点

```
DELETE https://<apiserver>:6443/api/v1/nodes/{name}
```

---

### 工作负载 Deployment

**API Group / Version：** `apps/v1`  
**资源名：** `deployments`  
**作用域：** Namespace 级别

---

#### 获取所有命名空间的 Deployment 列表

```
GET https://<apiserver>:6443/apis/apps/v1/deployments
```

---

#### 获取指定命名空间的 Deployment 列表

```
GET https://<apiserver>:6443/apis/apps/v1/namespaces/{namespace}/deployments
```

**请求示例：**

```bash
curl -k -H "Authorization: Bearer <token>" \
  "https://192.168.122.231:6443/apis/apps/v1/namespaces/default/deployments"
```

---

#### 获取指定 Deployment 详情

```
GET https://<apiserver>:6443/apis/apps/v1/namespaces/{namespace}/deployments/{name}
```

**响应示例（关键字段）：**

```json
{
  "apiVersion": "apps/v1",
  "kind": "Deployment",
  "metadata": {
    "name": "my-app",
    "namespace": "default"
  },
  "spec": {
    "replicas": 2,                             // 期望副本数
    "selector": {
      "matchLabels": { "app": "my-app" }
    },
    "template": {
      "spec": {
        "containers": [
          {
            "name": "my-container",
            "image": "nginx:latest"
          }
        ],
        "nodeSelector": {
          "kubernetes.io/hostname": "edge-node-01"  // 指定部署到的节点
        }
      }
    }
  },
  "status": {
    "replicas": 2,
    "readyReplicas": 2,                        // 就绪副本数
    "availableReplicas": 2,
    "updatedReplicas": 2
  }
}
```

---

#### 创建 Deployment

```
POST https://<apiserver>:6443/apis/apps/v1/namespaces/{namespace}/deployments
```

---

#### 更新 Deployment（局部，如修改镜像）

```
PATCH https://<apiserver>:6443/apis/apps/v1/namespaces/{namespace}/deployments/{name}
```

**请求头：** `Content-Type: application/merge-patch+json`

**请求示例（仅更新镜像版本）：**

```bash
curl -k -X PATCH \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/merge-patch+json" \
  -d '{"spec":{"template":{"spec":{"containers":[{"name":"my-container","image":"nginx:1.25"}]}}}}' \
  "https://192.168.122.231:6443/apis/apps/v1/namespaces/default/deployments/my-app"
```

---

#### 删除 Deployment

```
DELETE https://<apiserver>:6443/apis/apps/v1/namespaces/{namespace}/deployments/{name}
```

---

### 容器组 Pod

**API Group / Version：** `v1`（核心 API）  
**资源名：** `pods`  
**作用域：** Namespace 级别

---

#### 获取所有命名空间的 Pod 列表

```
GET https://<apiserver>:6443/api/v1/pods
```

---

#### 获取指定命名空间的 Pod 列表

```
GET https://<apiserver>:6443/api/v1/namespaces/{namespace}/pods
```

**请求示例：**

```bash
curl -k -H "Authorization: Bearer <token>" \
  "https://192.168.122.231:6443/api/v1/namespaces/default/pods"

# 查询指定节点上的 Pod
curl -k -H "Authorization: Bearer <token>" \
  "https://192.168.122.231:6443/api/v1/namespaces/default/pods?fieldSelector=spec.nodeName=edge-node-01"

# 查询运行中的 Pod
curl -k -H "Authorization: Bearer <token>" \
  "https://192.168.122.231:6443/api/v1/namespaces/default/pods?fieldSelector=status.phase=Running"
```

**响应关键字段：**

```json
{
  "items": [
    {
      "metadata": {
        "name": "my-app-pod-abc12",
        "namespace": "default"
      },
      "spec": {
        "nodeName": "edge-node-01"     // Pod 所在节点
      },
      "status": {
        "phase": "Running",            // Pod 状态：Pending / Running / Succeeded / Failed / Unknown
        "podIP": "10.244.0.5",
        "containerStatuses": [
          {
            "name": "my-container",
            "ready": true,
            "restartCount": 0,
            "image": "nginx:latest"
          }
        ]
      }
    }
  ]
}
```

---

#### 获取指定 Pod 详情

```
GET https://<apiserver>:6443/api/v1/namespaces/{namespace}/pods/{name}
```

---

#### 获取 Pod 日志

```
GET https://<apiserver>:6443/api/v1/namespaces/{namespace}/pods/{name}/log
```

**查询参数：**

| 参数 | 说明 |
|------|------|
| `container` | 指定容器名（Pod 多容器时必填） |
| `tailLines` | 返回最后 N 行日志 |
| `follow` | 设为 `true` 实时追踪日志（长连接） |
| `previous` | 设为 `true` 查看上一次重启前的日志 |

**请求示例：**

```bash
curl -k -H "Authorization: Bearer <token>" \
  "https://192.168.122.231:6443/api/v1/namespaces/default/pods/my-pod/log?tailLines=100"
```

---

### 服务 Service

**API Group / Version：** `v1`（核心 API）  
**资源名：** `services`  
**作用域：** Namespace 级别

---

#### 获取 Service 列表

```
GET https://<apiserver>:6443/api/v1/namespaces/{namespace}/services
```

**请求示例：**

```bash
curl -k -H "Authorization: Bearer <token>" \
  "https://192.168.122.231:6443/api/v1/namespaces/default/services"
```

---

#### 获取所有命名空间的 Service 列表

```
GET https://<apiserver>:6443/api/v1/services
```

---

#### 获取指定 Service 详情

```
GET https://<apiserver>:6443/api/v1/namespaces/{namespace}/services/{name}
```

**响应示例：**

```json
{
  "apiVersion": "v1",
  "kind": "Service",
  "metadata": {
    "name": "my-service",
    "namespace": "default"
  },
  "spec": {
    "type": "ClusterIP",               // 类型：ClusterIP / NodePort / LoadBalancer
    "clusterIP": "10.96.0.1",
    "ports": [
      {
        "port": 80,
        "targetPort": 8080,
        "protocol": "TCP",
        "nodePort": 30080              // NodePort 类型时的节点端口
      }
    ],
    "selector": { "app": "my-app" }
  }
}
```

---

#### 创建 Service

```
POST https://<apiserver>:6443/api/v1/namespaces/{namespace}/services
```

---

#### 更新 Service

```
PATCH https://<apiserver>:6443/api/v1/namespaces/{namespace}/services/{name}
```

**请求头：** `Content-Type: application/merge-patch+json`

---

#### 删除 Service

```
DELETE https://<apiserver>:6443/api/v1/namespaces/{namespace}/services/{name}
```

---

### 配置字典 ConfigMap

**API Group / Version：** `v1`（核心 API）  
**资源名：** `configmaps`  
**作用域：** Namespace 级别

---

#### 获取 ConfigMap 列表

```
GET https://<apiserver>:6443/api/v1/namespaces/{namespace}/configmaps
```

---

#### 获取所有命名空间 ConfigMap 列表

```
GET https://<apiserver>:6443/api/v1/configmaps
```

---

#### 获取指定 ConfigMap 详情

```
GET https://<apiserver>:6443/api/v1/namespaces/{namespace}/configmaps/{name}
```

**响应示例：**

```json
{
  "apiVersion": "v1",
  "kind": "ConfigMap",
  "metadata": {
    "name": "my-config",
    "namespace": "default"
  },
  "data": {
    "key1": "value1",                  // 配置键值对（明文存储）
    "config.yaml": "port: 8080\nhost: 0.0.0.0\n"
  }
}
```

---

#### 创建 ConfigMap

```
POST https://<apiserver>:6443/api/v1/namespaces/{namespace}/configmaps
```

---

#### 更新 ConfigMap

```
PUT https://<apiserver>:6443/api/v1/namespaces/{namespace}/configmaps/{name}
```

```
PATCH https://<apiserver>:6443/api/v1/namespaces/{namespace}/configmaps/{name}
```

**请求头（PATCH）：** `Content-Type: application/merge-patch+json`

---

#### 删除 ConfigMap

```
DELETE https://<apiserver>:6443/api/v1/namespaces/{namespace}/configmaps/{name}
```

---

### 密钥 Secret

**API Group / Version：** `v1`（核心 API）  
**资源名：** `secrets`  
**作用域：** Namespace 级别

> **注意：** Secret 中 `data` 字段的值均为 **Base64 编码**，调用方需自行 Base64 解码获取原始内容。

---

#### 获取 Secret 列表

```
GET https://<apiserver>:6443/api/v1/namespaces/{namespace}/secrets
```

---

#### 获取所有命名空间 Secret 列表

```
GET https://<apiserver>:6443/api/v1/secrets
```

---

#### 获取指定 Secret 详情

```
GET https://<apiserver>:6443/api/v1/namespaces/{namespace}/secrets/{name}
```

**响应示例：**

```json
{
  "apiVersion": "v1",
  "kind": "Secret",
  "metadata": {
    "name": "my-secret",
    "namespace": "default"
  },
  "type": "Opaque",                    // 类型：Opaque / kubernetes.io/tls / kubernetes.io/dockerconfigjson 等
  "data": {
    "username": "YWRtaW4=",            // Base64 编码值，解码后为 "admin"
    "password": "cGFzc3dvcmQ="         // Base64 编码值，解码后为 "password"
  }
}
```

---

#### 创建 Secret

```
POST https://<apiserver>:6443/api/v1/namespaces/{namespace}/secrets
```

---

#### 更新 Secret

```
PATCH https://<apiserver>:6443/api/v1/namespaces/{namespace}/secrets/{name}
```

**请求头：** `Content-Type: application/merge-patch+json`

---

#### 删除 Secret

```
DELETE https://<apiserver>:6443/api/v1/namespaces/{namespace}/secrets/{name}
```

---

### 自定义资源定义 CRD

**API Group / Version：** `apiextensions.k8s.io/v1`  
**资源名：** `customresourcedefinitions`  
**作用域：** Cluster 级别

---

#### 获取 CRD 列表

```
GET https://<apiserver>:6443/apis/apiextensions.k8s.io/v1/customresourcedefinitions
```

**请求示例：**

```bash
curl -k -H "Authorization: Bearer <token>" \
  "https://192.168.122.231:6443/apis/apiextensions.k8s.io/v1/customresourcedefinitions"

# 只查 KubeEdge 相关 CRD
curl -k -H "Authorization: Bearer <token>" \
  "https://192.168.122.231:6443/apis/apiextensions.k8s.io/v1/customresourcedefinitions?labelSelector=app.kubernetes.io/part-of=kubeedge"
```

**响应示例：**

```json
{
  "items": [
    {
      "metadata": {
        "name": "devices.devices.kubeedge.io"    // CRD 全名格式：<plural>.<group>
      },
      "spec": {
        "group": "devices.kubeedge.io",
        "names": {
          "plural": "devices",
          "singular": "device",
          "kind": "Device"
        },
        "scope": "Namespaced",                    // Namespaced 或 Cluster
        "versions": [
          { "name": "v1beta1", "served": true, "storage": true }
        ]
      }
    }
  ]
}
```

---

#### 获取指定 CRD 详情

```
GET https://<apiserver>:6443/apis/apiextensions.k8s.io/v1/customresourcedefinitions/{name}
```

**请求示例：**

```bash
curl -k -H "Authorization: Bearer <token>" \
  "https://192.168.122.231:6443/apis/apiextensions.k8s.io/v1/customresourcedefinitions/devices.devices.kubeedge.io"
```

---

## 权限管理 RBAC

---

### 角色 Role

**API Group / Version：** `rbac.authorization.k8s.io/v1`  
**资源名：** `roles`  
**作用域：** Namespace 级别

---

#### 获取 Role 列表

```
GET https://<apiserver>:6443/apis/rbac.authorization.k8s.io/v1/namespaces/{namespace}/roles
```

**请求示例：**

```bash
curl -k -H "Authorization: Bearer <token>" \
  "https://192.168.122.231:6443/apis/rbac.authorization.k8s.io/v1/namespaces/default/roles"
```

---

#### 获取所有命名空间 Role

```
GET https://<apiserver>:6443/apis/rbac.authorization.k8s.io/v1/roles
```

---

#### 获取指定 Role 详情

```
GET https://<apiserver>:6443/apis/rbac.authorization.k8s.io/v1/namespaces/{namespace}/roles/{name}
```

**响应示例：**

```json
{
  "apiVersion": "rbac.authorization.k8s.io/v1",
  "kind": "Role",
  "metadata": {
    "name": "pod-reader",
    "namespace": "default"
  },
  "rules": [
    {
      "apiGroups": [""],                         // "" 表示核心 API 组
      "resources": ["pods", "pods/log"],         // 可操作的资源类型
      "verbs": ["get", "watch", "list"]          // 允许的操作动词
    },
    {
      "apiGroups": ["devices.kubeedge.io"],
      "resources": ["devices"],
      "verbs": ["get", "list", "update", "patch"]
    }
  ]
}
```

---

#### 创建 Role

```
POST https://<apiserver>:6443/apis/rbac.authorization.k8s.io/v1/namespaces/{namespace}/roles
```

---

#### 更新 Role

```
PATCH https://<apiserver>:6443/apis/rbac.authorization.k8s.io/v1/namespaces/{namespace}/roles/{name}
```

**请求头：** `Content-Type: application/merge-patch+json`

---

#### 删除 Role

```
DELETE https://<apiserver>:6443/apis/rbac.authorization.k8s.io/v1/namespaces/{namespace}/roles/{name}
```

---

### 角色绑定 RoleBinding

**API Group / Version：** `rbac.authorization.k8s.io/v1`  
**资源名：** `rolebindings`  
**作用域：** Namespace 级别

---

#### 获取 RoleBinding 列表

```
GET https://<apiserver>:6443/apis/rbac.authorization.k8s.io/v1/namespaces/{namespace}/rolebindings
```

---

#### 获取所有命名空间 RoleBinding

```
GET https://<apiserver>:6443/apis/rbac.authorization.k8s.io/v1/rolebindings
```

---

#### 获取指定 RoleBinding 详情

```
GET https://<apiserver>:6443/apis/rbac.authorization.k8s.io/v1/namespaces/{namespace}/rolebindings/{name}
```

**响应示例：**

```json
{
  "apiVersion": "rbac.authorization.k8s.io/v1",
  "kind": "RoleBinding",
  "metadata": {
    "name": "read-pods-binding",
    "namespace": "default"
  },
  "subjects": [
    {
      "kind": "ServiceAccount",              // 绑定对象类型：User / Group / ServiceAccount
      "name": "my-sa",
      "namespace": "default"
    }
  ],
  "roleRef": {
    "apiGroup": "rbac.authorization.k8s.io",
    "kind": "Role",                          // Role 或 ClusterRole
    "name": "pod-reader"                     // 被绑定的 Role 名称
  }
}
```

---

#### 创建 RoleBinding

```
POST https://<apiserver>:6443/apis/rbac.authorization.k8s.io/v1/namespaces/{namespace}/rolebindings
```

---

#### 删除 RoleBinding

```
DELETE https://<apiserver>:6443/apis/rbac.authorization.k8s.io/v1/namespaces/{namespace}/rolebindings/{name}
```

---

### 集群角色 ClusterRole

**API Group / Version：** `rbac.authorization.k8s.io/v1`  
**资源名：** `clusterroles`  
**作用域：** Cluster 级别

---

#### 获取 ClusterRole 列表

```
GET https://<apiserver>:6443/apis/rbac.authorization.k8s.io/v1/clusterroles
```

**请求示例：**

```bash
curl -k -H "Authorization: Bearer <token>" \
  "https://192.168.122.231:6443/apis/rbac.authorization.k8s.io/v1/clusterroles"
```

---

#### 获取指定 ClusterRole 详情

```
GET https://<apiserver>:6443/apis/rbac.authorization.k8s.io/v1/clusterroles/{name}
```

---

#### 创建 ClusterRole

```
POST https://<apiserver>:6443/apis/rbac.authorization.k8s.io/v1/clusterroles
```

---

#### 更新 ClusterRole

```
PATCH https://<apiserver>:6443/apis/rbac.authorization.k8s.io/v1/clusterroles/{name}
```

**请求头：** `Content-Type: application/merge-patch+json`

---

#### 删除 ClusterRole

```
DELETE https://<apiserver>:6443/apis/rbac.authorization.k8s.io/v1/clusterroles/{name}
```

---

### 集群角色绑定 ClusterRoleBinding

**API Group / Version：** `rbac.authorization.k8s.io/v1`  
**资源名：** `clusterrolebindings`  
**作用域：** Cluster 级别

---

#### 获取 ClusterRoleBinding 列表

```
GET https://<apiserver>:6443/apis/rbac.authorization.k8s.io/v1/clusterrolebindings
```

---

#### 获取指定 ClusterRoleBinding 详情

```
GET https://<apiserver>:6443/apis/rbac.authorization.k8s.io/v1/clusterrolebindings/{name}
```

---

#### 创建 ClusterRoleBinding

```
POST https://<apiserver>:6443/apis/rbac.authorization.k8s.io/v1/clusterrolebindings
```

---

#### 删除 ClusterRoleBinding

```
DELETE https://<apiserver>:6443/apis/rbac.authorization.k8s.io/v1/clusterrolebindings/{name}
```

---

### 服务账号 ServiceAccount

**API Group / Version：** `v1`（核心 API）  
**资源名：** `serviceaccounts`  
**作用域：** Namespace 级别

---

#### 获取 ServiceAccount 列表

```
GET https://<apiserver>:6443/api/v1/namespaces/{namespace}/serviceaccounts
```

---

#### 获取所有命名空间 ServiceAccount

```
GET https://<apiserver>:6443/api/v1/serviceaccounts
```

---

#### 获取指定 ServiceAccount 详情

```
GET https://<apiserver>:6443/api/v1/namespaces/{namespace}/serviceaccounts/{name}
```

**响应示例：**

```json
{
  "apiVersion": "v1",
  "kind": "ServiceAccount",
  "metadata": {
    "name": "my-sa",
    "namespace": "default"
  },
  "secrets": [
    {
      "name": "my-sa-token-xxxxx"    // 自动绑定的 Token Secret 名称（k8s < 1.24）
    }
  ]
}
```

---

#### 创建 ServiceAccount

```
POST https://<apiserver>:6443/api/v1/namespaces/{namespace}/serviceaccounts
```

---

#### 删除 ServiceAccount

```
DELETE https://<apiserver>:6443/api/v1/namespaces/{namespace}/serviceaccounts/{name}
```

---

## 附录：接口一览表

### KubeEdge 核心资源

| 资源 | API Group | 方法 | 路径 | 说明 |
|------|----------|------|------|------|
| Device | `devices.kubeedge.io/v1beta1` | GET | `/apis/devices.kubeedge.io/v1beta1/devices` | 所有命名空间设备列表 |
| Device | `devices.kubeedge.io/v1beta1` | GET | `/apis/devices.kubeedge.io/v1beta1/namespaces/{ns}/devices` | 指定命名空间设备列表 |
| Device | `devices.kubeedge.io/v1beta1` | GET | `/apis/devices.kubeedge.io/v1beta1/namespaces/{ns}/devices/{name}` | 设备详情 |
| Device | `devices.kubeedge.io/v1beta1` | POST | `/apis/devices.kubeedge.io/v1beta1/namespaces/{ns}/devices` | 创建设备 |
| Device | `devices.kubeedge.io/v1beta1` | PUT | `/apis/devices.kubeedge.io/v1beta1/namespaces/{ns}/devices/{name}` | 全量更新设备 |
| Device | `devices.kubeedge.io/v1beta1` | PATCH | `/apis/devices.kubeedge.io/v1beta1/namespaces/{ns}/devices/{name}` | 局部更新设备 |
| Device | `devices.kubeedge.io/v1beta1` | DELETE | `/apis/devices.kubeedge.io/v1beta1/namespaces/{ns}/devices/{name}` | 删除设备 |
| DeviceModel | `devices.kubeedge.io/v1beta1` | GET | `/apis/devices.kubeedge.io/v1beta1/devicemodels` | 所有命名空间设备模型列表 |
| DeviceModel | `devices.kubeedge.io/v1beta1` | GET | `/apis/devices.kubeedge.io/v1beta1/namespaces/{ns}/devicemodels` | 指定命名空间设备模型列表 |
| DeviceModel | `devices.kubeedge.io/v1beta1` | GET | `/apis/devices.kubeedge.io/v1beta1/namespaces/{ns}/devicemodels/{name}` | 设备模型详情 |
| DeviceModel | `devices.kubeedge.io/v1beta1` | POST | `/apis/devices.kubeedge.io/v1beta1/namespaces/{ns}/devicemodels` | 创建设备模型 |
| DeviceModel | `devices.kubeedge.io/v1beta1` | PUT | `/apis/devices.kubeedge.io/v1beta1/namespaces/{ns}/devicemodels/{name}` | 更新设备模型 |
| DeviceModel | `devices.kubeedge.io/v1beta1` | DELETE | `/apis/devices.kubeedge.io/v1beta1/namespaces/{ns}/devicemodels/{name}` | 删除设备模型 |
| NodeGroup | `apps.kubeedge.io/v1alpha1` | GET | `/apis/apps.kubeedge.io/v1alpha1/nodegroups` | 节点组列表 |
| NodeGroup | `apps.kubeedge.io/v1alpha1` | GET | `/apis/apps.kubeedge.io/v1alpha1/nodegroups/{name}` | 节点组详情 |
| NodeGroup | `apps.kubeedge.io/v1alpha1` | POST | `/apis/apps.kubeedge.io/v1alpha1/nodegroups` | 创建节点组 |
| NodeGroup | `apps.kubeedge.io/v1alpha1` | PUT | `/apis/apps.kubeedge.io/v1alpha1/nodegroups/{name}` | 更新节点组 |
| NodeGroup | `apps.kubeedge.io/v1alpha1` | DELETE | `/apis/apps.kubeedge.io/v1alpha1/nodegroups/{name}` | 删除节点组 |
| EdgeApplication | `apps.kubeedge.io/v1alpha1` | GET | `/apis/apps.kubeedge.io/v1alpha1/edgeapplications` | 所有命名空间边缘应用列表 |
| EdgeApplication | `apps.kubeedge.io/v1alpha1` | GET | `/apis/apps.kubeedge.io/v1alpha1/namespaces/{ns}/edgeapplications` | 指定命名空间边缘应用列表 |
| EdgeApplication | `apps.kubeedge.io/v1alpha1` | GET | `/apis/apps.kubeedge.io/v1alpha1/namespaces/{ns}/edgeapplications/{name}` | 边缘应用详情 |
| EdgeApplication | `apps.kubeedge.io/v1alpha1` | POST | `/apis/apps.kubeedge.io/v1alpha1/namespaces/{ns}/edgeapplications` | 创建边缘应用 |
| EdgeApplication | `apps.kubeedge.io/v1alpha1` | PUT | `/apis/apps.kubeedge.io/v1alpha1/namespaces/{ns}/edgeapplications/{name}` | 更新边缘应用 |
| EdgeApplication | `apps.kubeedge.io/v1alpha1` | DELETE | `/apis/apps.kubeedge.io/v1alpha1/namespaces/{ns}/edgeapplications/{name}` | 删除边缘应用 |
| Rule | `rules.kubeedge.io/v1` | GET | `/apis/rules.kubeedge.io/v1/namespaces/{ns}/rules` | 规则列表 |
| Rule | `rules.kubeedge.io/v1` | GET | `/apis/rules.kubeedge.io/v1/namespaces/{ns}/rules/{name}` | 规则详情 |
| Rule | `rules.kubeedge.io/v1` | POST | `/apis/rules.kubeedge.io/v1/namespaces/{ns}/rules` | 创建规则 |
| Rule | `rules.kubeedge.io/v1` | PUT | `/apis/rules.kubeedge.io/v1/namespaces/{ns}/rules/{name}` | 更新规则 |
| Rule | `rules.kubeedge.io/v1` | DELETE | `/apis/rules.kubeedge.io/v1/namespaces/{ns}/rules/{name}` | 删除规则 |
| RuleEndpoint | `rules.kubeedge.io/v1` | GET | `/apis/rules.kubeedge.io/v1/namespaces/{ns}/ruleendpoints` | 规则端点列表 |
| RuleEndpoint | `rules.kubeedge.io/v1` | GET | `/apis/rules.kubeedge.io/v1/namespaces/{ns}/ruleendpoints/{name}` | 规则端点详情 |
| RuleEndpoint | `rules.kubeedge.io/v1` | POST | `/apis/rules.kubeedge.io/v1/namespaces/{ns}/ruleendpoints` | 创建规则端点 |
| RuleEndpoint | `rules.kubeedge.io/v1` | PUT | `/apis/rules.kubeedge.io/v1/namespaces/{ns}/ruleendpoints/{name}` | 更新规则端点 |
| RuleEndpoint | `rules.kubeedge.io/v1` | DELETE | `/apis/rules.kubeedge.io/v1/namespaces/{ns}/ruleendpoints/{name}` | 删除规则端点 |

### Kubernetes 基础资源

| 资源 | API Group | 方法 | 路径 | 说明 |
|------|----------|------|------|------|
| Version | - | GET | `/version` | 集群版本 |
| Namespace | `v1` | GET | `/api/v1/namespaces` | 命名空间列表 |
| Namespace | `v1` | GET | `/api/v1/namespaces/{name}` | 命名空间详情 |
| Node | `v1` | GET | `/api/v1/nodes` | 节点列表 |
| Node | `v1` | GET | `/api/v1/nodes/{name}` | 节点详情 |
| Node | `v1` | PATCH | `/api/v1/nodes/{name}` | 更新节点 |
| Node | `v1` | DELETE | `/api/v1/nodes/{name}` | 删除节点 |
| Deployment | `apps/v1` | GET | `/apis/apps/v1/deployments` | 所有命名空间 Deployment 列表 |
| Deployment | `apps/v1` | GET | `/apis/apps/v1/namespaces/{ns}/deployments` | 指定命名空间 Deployment 列表 |
| Deployment | `apps/v1` | GET | `/apis/apps/v1/namespaces/{ns}/deployments/{name}` | Deployment 详情 |
| Deployment | `apps/v1` | POST | `/apis/apps/v1/namespaces/{ns}/deployments` | 创建 Deployment |
| Deployment | `apps/v1` | PATCH | `/apis/apps/v1/namespaces/{ns}/deployments/{name}` | 更新 Deployment |
| Deployment | `apps/v1` | DELETE | `/apis/apps/v1/namespaces/{ns}/deployments/{name}` | 删除 Deployment |
| Pod | `v1` | GET | `/api/v1/pods` | 所有命名空间 Pod 列表 |
| Pod | `v1` | GET | `/api/v1/namespaces/{ns}/pods` | 指定命名空间 Pod 列表 |
| Pod | `v1` | GET | `/api/v1/namespaces/{ns}/pods/{name}` | Pod 详情 |
| Pod | `v1` | GET | `/api/v1/namespaces/{ns}/pods/{name}/log` | Pod 日志 |
| Service | `v1` | GET | `/api/v1/services` | 所有命名空间 Service 列表 |
| Service | `v1` | GET | `/api/v1/namespaces/{ns}/services` | 指定命名空间 Service 列表 |
| Service | `v1` | GET | `/api/v1/namespaces/{ns}/services/{name}` | Service 详情 |
| Service | `v1` | POST | `/api/v1/namespaces/{ns}/services` | 创建 Service |
| Service | `v1` | PATCH | `/api/v1/namespaces/{ns}/services/{name}` | 更新 Service |
| Service | `v1` | DELETE | `/api/v1/namespaces/{ns}/services/{name}` | 删除 Service |
| ConfigMap | `v1` | GET | `/api/v1/configmaps` | 所有命名空间 ConfigMap 列表 |
| ConfigMap | `v1` | GET | `/api/v1/namespaces/{ns}/configmaps` | 指定命名空间 ConfigMap 列表 |
| ConfigMap | `v1` | GET | `/api/v1/namespaces/{ns}/configmaps/{name}` | ConfigMap 详情 |
| ConfigMap | `v1` | POST | `/api/v1/namespaces/{ns}/configmaps` | 创建 ConfigMap |
| ConfigMap | `v1` | PATCH | `/api/v1/namespaces/{ns}/configmaps/{name}` | 更新 ConfigMap |
| ConfigMap | `v1` | DELETE | `/api/v1/namespaces/{ns}/configmaps/{name}` | 删除 ConfigMap |
| Secret | `v1` | GET | `/api/v1/secrets` | 所有命名空间 Secret 列表 |
| Secret | `v1` | GET | `/api/v1/namespaces/{ns}/secrets` | 指定命名空间 Secret 列表 |
| Secret | `v1` | GET | `/api/v1/namespaces/{ns}/secrets/{name}` | Secret 详情 |
| Secret | `v1` | POST | `/api/v1/namespaces/{ns}/secrets` | 创建 Secret |
| Secret | `v1` | PATCH | `/api/v1/namespaces/{ns}/secrets/{name}` | 更新 Secret |
| Secret | `v1` | DELETE | `/api/v1/namespaces/{ns}/secrets/{name}` | 删除 Secret |
| CRD | `apiextensions.k8s.io/v1` | GET | `/apis/apiextensions.k8s.io/v1/customresourcedefinitions` | CRD 列表 |
| CRD | `apiextensions.k8s.io/v1` | GET | `/apis/apiextensions.k8s.io/v1/customresourcedefinitions/{name}` | CRD 详情 |

### 权限管理 RBAC

| 资源 | API Group | 方法 | 路径 | 说明 |
|------|----------|------|------|------|
| Role | `rbac.authorization.k8s.io/v1` | GET | `/apis/rbac.authorization.k8s.io/v1/roles` | 所有命名空间 Role 列表 |
| Role | `rbac.authorization.k8s.io/v1` | GET | `/apis/rbac.authorization.k8s.io/v1/namespaces/{ns}/roles` | 指定命名空间 Role 列表 |
| Role | `rbac.authorization.k8s.io/v1` | GET | `/apis/rbac.authorization.k8s.io/v1/namespaces/{ns}/roles/{name}` | Role 详情 |
| Role | `rbac.authorization.k8s.io/v1` | POST | `/apis/rbac.authorization.k8s.io/v1/namespaces/{ns}/roles` | 创建 Role |
| Role | `rbac.authorization.k8s.io/v1` | PATCH | `/apis/rbac.authorization.k8s.io/v1/namespaces/{ns}/roles/{name}` | 更新 Role |
| Role | `rbac.authorization.k8s.io/v1` | DELETE | `/apis/rbac.authorization.k8s.io/v1/namespaces/{ns}/roles/{name}` | 删除 Role |
| RoleBinding | `rbac.authorization.k8s.io/v1` | GET | `/apis/rbac.authorization.k8s.io/v1/rolebindings` | 所有命名空间 RoleBinding 列表 |
| RoleBinding | `rbac.authorization.k8s.io/v1` | GET | `/apis/rbac.authorization.k8s.io/v1/namespaces/{ns}/rolebindings` | 指定命名空间 RoleBinding 列表 |
| RoleBinding | `rbac.authorization.k8s.io/v1` | GET | `/apis/rbac.authorization.k8s.io/v1/namespaces/{ns}/rolebindings/{name}` | RoleBinding 详情 |
| RoleBinding | `rbac.authorization.k8s.io/v1` | POST | `/apis/rbac.authorization.k8s.io/v1/namespaces/{ns}/rolebindings` | 创建 RoleBinding |
| RoleBinding | `rbac.authorization.k8s.io/v1` | DELETE | `/apis/rbac.authorization.k8s.io/v1/namespaces/{ns}/rolebindings/{name}` | 删除 RoleBinding |
| ClusterRole | `rbac.authorization.k8s.io/v1` | GET | `/apis/rbac.authorization.k8s.io/v1/clusterroles` | ClusterRole 列表 |
| ClusterRole | `rbac.authorization.k8s.io/v1` | GET | `/apis/rbac.authorization.k8s.io/v1/clusterroles/{name}` | ClusterRole 详情 |
| ClusterRole | `rbac.authorization.k8s.io/v1` | POST | `/apis/rbac.authorization.k8s.io/v1/clusterroles` | 创建 ClusterRole |
| ClusterRole | `rbac.authorization.k8s.io/v1` | PATCH | `/apis/rbac.authorization.k8s.io/v1/clusterroles/{name}` | 更新 ClusterRole |
| ClusterRole | `rbac.authorization.k8s.io/v1` | DELETE | `/apis/rbac.authorization.k8s.io/v1/clusterroles/{name}` | 删除 ClusterRole |
| ClusterRoleBinding | `rbac.authorization.k8s.io/v1` | GET | `/apis/rbac.authorization.k8s.io/v1/clusterrolebindings` | ClusterRoleBinding 列表 |
| ClusterRoleBinding | `rbac.authorization.k8s.io/v1` | GET | `/apis/rbac.authorization.k8s.io/v1/clusterrolebindings/{name}` | ClusterRoleBinding 详情 |
| ClusterRoleBinding | `rbac.authorization.k8s.io/v1` | POST | `/apis/rbac.authorization.k8s.io/v1/clusterrolebindings` | 创建 ClusterRoleBinding |
| ClusterRoleBinding | `rbac.authorization.k8s.io/v1` | DELETE | `/apis/rbac.authorization.k8s.io/v1/clusterrolebindings/{name}` | 删除 ClusterRoleBinding |
| ServiceAccount | `v1` | GET | `/api/v1/serviceaccounts` | 所有命名空间 ServiceAccount 列表 |
| ServiceAccount | `v1` | GET | `/api/v1/namespaces/{ns}/serviceaccounts` | 指定命名空间 ServiceAccount 列表 |
| ServiceAccount | `v1` | GET | `/api/v1/namespaces/{ns}/serviceaccounts/{name}` | ServiceAccount 详情 |
| ServiceAccount | `v1` | POST | `/api/v1/namespaces/{ns}/serviceaccounts` | 创建 ServiceAccount |
| ServiceAccount | `v1` | DELETE | `/api/v1/namespaces/{ns}/serviceaccounts/{name}` | 删除 ServiceAccount |
