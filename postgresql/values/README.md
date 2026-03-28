# postgresql/values 目录说明

此目录存放自定义 Helm values 文件。

## 文件说明

- `values-offline.yaml.tpl`  
  由 CI 工作流自动生成并打包进离线包，包含 `HARBOR_ADDR` 占位符。  
  **安装时**由 `install.sh` 自动替换为实际 Harbor 地址。

- 自定义覆盖值（可选）  
  如需自定义 PostgreSQL 配置（如密码、资源限制、存储大小等），  
  可在此目录创建 `values-custom.yaml`，工作流会将其一同打包。  
  安装时通过 `-f values-custom.yaml` 叠加使用。

## 常用自定义示例

```yaml
# values-custom.yaml 示例

# 设置 PostgreSQL 密码
auth:
  postgresPassword: "your-secure-password"
  username: "appuser"
  password: "your-app-password"
  database: "appdb"

# 存储配置
primary:
  persistence:
    enabled: true
    size: 50Gi
    storageClass: "local-path"   # K3s 默认存储类

# 资源限制
primary:
  resources:
    requests:
      memory: 512Mi
      cpu: 250m
    limits:
      memory: 2Gi
      cpu: 1000m

# 副本（读写分离）
readReplicas:
  replicaCount: 1
```

## 手动生成 values 文件

```bash
# 替换 HARBOR_ADDR 为实际地址
sed 's|HARBOR_ADDR|harbor.example.com|g' values-offline.yaml.tpl > values-final.yaml

# 安装时使用
helm install postgresql ./charts/postgresql-18.5.14.tgz \
  -n postgresql --create-namespace \
  -f values-final.yaml \
  -f values-custom.yaml    # 如有自定义值
```
