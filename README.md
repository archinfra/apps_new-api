# New-API 离线 `.run` 交付包

这个仓库用于把 `QuantumNous/new-api` 构建成离线安装包。当前拆成两个包：

- `packages/compose`：Docker Compose / `docker compose` 离线部署包。
- `packages/k8s`：Kubernetes 离线部署包。

GitHub Actions 会按 `amd64`、`arm64` 两个架构构建，产物包括：

```text
new-api-compose-installer-amd64.run
new-api-compose-installer-arm64.run
new-api-k8s-installer-amd64.run
new-api-k8s-installer-arm64.run
```

每个 `.run` 旁边都会生成 `.sha256`。

## 构建方式

在 GitHub 页面执行：

`Actions` → `Build New-API Offline Run Packages` → `Run workflow`

可选输入：

- `package`：`all`、`compose`、`k8s`。
- `source_repo`：默认上游 new-api 仓库。
- `source_ref`：默认 `main`，也可以填上游 tag 或 commit。
- `image_version`：留空时自动使用 `source_ref + UTC timestamp`。

推送 `v*` tag 时，会自动把 `.run` 与 `.sha256` 发布到 GitHub Release。

## 本地构建

本地需要 Docker Buildx、Git、jq、tar、sha256sum：

```bash
cd packages/compose
bash -n build.sh install.sh
jq empty images/image.json
bash build.sh --arch amd64 --source-dir /path/to/new-api-main

cd ../k8s
bash build.sh --arch amd64 --source-dir /path/to/new-api-main
```

`--source-dir` 可以直接指向上游源码目录；不传时会从 `SOURCE_REPO` 克隆。

## Compose 现场安装

```bash
sha256sum -c new-api-compose-installer-amd64.run.sha256
chmod +x new-api-compose-installer-amd64.run

./new-api-compose-installer-amd64.run install \
  --install-dir /opt/new-api \
  --app-port 3000 \
  --postgres-password '<POSTGRES_PASSWORD>' \
  --redis-password '<REDIS_PASSWORD>' \
  --session-secret '<RANDOM_SESSION_SECRET>' \
  -y
```

如果现场要先推到内网镜像仓库，再由 Compose 使用仓库镜像：

```bash
./new-api-compose-installer-amd64.run install \
  --registry <REGISTRY_PREFIX> \
  --registry-user <REGISTRY_USER> \
  --registry-pass '<REGISTRY_PASSWORD>' \
  --install-dir /opt/new-api \
  -y
```

状态与卸载：

```bash
./new-api-compose-installer-amd64.run status --install-dir /opt/new-api
./new-api-compose-installer-amd64.run uninstall --install-dir /opt/new-api -y
```

默认卸载不删除数据。要删除 Compose volume 和 `/opt/new-api/data`、`/opt/new-api/logs`，需要显式加 `--danger-delete-data`。

## Kubernetes 现场安装

K8s 模式建议必须提供内网仓库，因为多节点集群不能依赖单机 Docker 本地镜像：

```bash
sha256sum -c new-api-k8s-installer-amd64.run.sha256
chmod +x new-api-k8s-installer-amd64.run

./new-api-k8s-installer-amd64.run install \
  --registry <REGISTRY_PREFIX> \
  --registry-user <REGISTRY_USER> \
  --registry-pass '<REGISTRY_PASSWORD>' \
  -n new-api \
  --service-type NodePort \
  --node-port 30080 \
  --postgres-password '<POSTGRES_PASSWORD>' \
  --redis-password '<REDIS_PASSWORD>' \
  --session-secret '<RANDOM_SESSION_SECRET>' \
  -y
```

验证：

```bash
./new-api-k8s-installer-amd64.run status -n new-api
kubectl get pods,svc,deploy,statefulset,pvc -n new-api
```

如目标仓库已经预置镜像：

```bash
./new-api-k8s-installer-amd64.run install \
  --registry <REGISTRY_PREFIX> \
  --skip-image-prepare \
  -n new-api \
  -y
```

卸载默认保留 PVC：

```bash
./new-api-k8s-installer-amd64.run uninstall -n new-api -y
```

删除 PVC 需要显式加：

```bash
./new-api-k8s-installer-amd64.run uninstall -n new-api --danger-delete-data -y
```

## 目录说明

```text
.github/workflows/offline-run.yml       # 多架构 CI 构建和 Release
scripts/offline_build_lib.sh            # 通用构建逻辑：拉源码、构建镜像、保存镜像、拼接 run
packages/compose/build.sh               # Compose 包构建入口
packages/compose/install.sh             # Compose 包运行时安装器
packages/compose/templates/             # Compose 模板
packages/compose/images/image.json      # Compose 镜像声明
packages/k8s/build.sh                   # K8s 包构建入口
packages/k8s/install.sh                 # K8s 包运行时安装器
packages/k8s/manifests/                 # K8s 模板
packages/k8s/images/image.json          # K8s 镜像声明
```

## 当前边界

- CI 默认从上游 `QuantumNous/new-api` 拉源码并构建业务镜像；这个仓库不复制上游完整源码。
- 默认数据库是 PostgreSQL，缓存是 Redis。
- 生产环境必须覆盖默认密码和 `SESSION_SECRET`。
- K8s 包内置的是单副本 New-API、单副本 Redis、单副本 PostgreSQL，适合作为离线交付基础版。
