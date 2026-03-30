# redis/values 目录说明

此目录用于存放自定义 Helm values 文件，在安装时会自动合并覆盖 `values-offline.yaml.tpl` 中的默认配置。

## 使用方式

将自定义的 values yaml 文件放入此目录，例如：

```
redis/values/
  custom-values.yaml      ← 自定义配置（如持久化大小、密码、副本数等）
```

## 常用自定义配置示例

```yaml
# custom-values.yaml

# 认证配置
auth:
  enabled: true
  password: "your-redis-password"

# 架构模式（standalone / replication / sentinel）
architecture: standalone

# 主节点持久化
master:
  persistence:
    enabled: true
    size: 8Gi
    storageClass: ""   # 留空使用默认 StorageClass

# 副本节点（仅 replication 模式生效）
replica:
  replicaCount: 1
  persistence:
    enabled: true
    size: 8Gi

# 资源限制
master:
  resources:
    requests:
      memory: 256Mi
      cpu: 100m
    limits:
      memory: 512Mi
      cpu: 500m
```

## 注意事项

- 镜像地址（`image.registry` / `image.repository` / `image.tag`）由 `install.sh` 自动替换，无需手动配置
- 此目录下的 yaml 文件会在 `install.sh` 执行时通过 `-f` 参数叠加到离线 values 之后
