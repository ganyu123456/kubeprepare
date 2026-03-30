# redis/charts 目录说明

此目录用于存放预置的 Helm chart tgz 文件。

## 使用方式

**方式一（推荐）：将 chart tgz 预置于此目录**

将 `redis-23.1.1.tgz` 放入此目录：

```bash
# 从 Bitnami OCI 仓库下载（需要网络）
helm pull oci://registry-1.docker.io/bitnamicharts/redis --version 23.1.1

# 或从 Bitnami helm repo 下载
helm repo add bitnami https://charts.bitnami.com/bitnami
helm pull bitnami/redis --version 23.1.1

# 将 tgz 复制到此目录
cp redis-23.1.1.tgz redis/charts/
```

工作流会优先使用此目录中的 chart，避免每次构建都从网络下载。

**方式二：由工作流自动下载**

不放置任何文件，工作流会自动从 Bitnami 下载指定版本。

## 目录结构（构建产物）

构建完成后，离线包中的 `charts/` 目录结构如下：

```
charts/
  redis-23.1.1.tgz    ← 自包含 chart（已内嵌 bitnami/common 依赖）
  common-x.x.x.tgz   ← bitnami/common 依赖 chart（独立推送至 Harbor 用）
```

## 版本说明

| Chart 版本 | Redis 版本 | 说明 |
|-----------|-----------|------|
| 23.1.1    | ~7.x      | 当前使用版本 |
