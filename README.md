# adguardhome-deploy

把 [AdguardTeam/AdGuardHome](https://github.com/AdguardTeam/AdGuardHome) 的**官方 release 可执行文件**重新打包成镜像，
推到国内可直接拉取的阿里云 ACR。解决的是国内 NAS 直连 `registry-1.docker.io` 超时、拉不动 `adguard/adguardhome` 的问题。

## 和 danmu-api-deploy 的区别

`danmu-api-deploy` 要 clone 上游源码、`npm install` 再 QEMU 交叉编译 armv7（15–30 分钟）。
AdGuard Home 不用这样：

| | danmu-api-deploy | 本仓库 |
| --- | --- | --- |
| 上游变更单位 | `main` 分支的 commit SHA | **Release tag**（AGH 按版本发版） |
| 构建内容 | clone 源码 + `npm install` + node 基础镜像 | **下载官方二进制 + 校验 sha256 + 重新打包** |
| 需要 Go / Node | 需要 Node | **不需要** |
| 需要 QEMU | 需要（armv7 在 x86 runner 上） | **不需要**（目标 amd64） |
| 构建耗时 | 首次 15–30 分钟 | **1–2 分钟** |
| 产物 | 源码重编，不可复现 | 官方产物 + `checksums.txt` 校验，可逐字节比对 |

## 产出镜像

| 通道 | 地址 | 说明 |
| --- | --- | --- |
| 阿里云 ACR（唯一主通道） | `<ALIYUN_REGISTRY>/<ALIYUN_NAMESPACE>/adguardhome-deploy` | 国内直连可拉，部署只认这条 |
| Docker Hub（可选） | `<DOCKERHUB_USERNAME>/adguardhome-deploy` | 仅配了 `DOCKERHUB_*` secrets 才会推 |

不推 GHCR：国内直连 `ghcr.io` / `registry-1.docker.io` 都不是可靠来源，多推一路只会拉长构建时间。

标签规则（三通道一致）：

- `latest`：stable 通道最新正式版（beta 通道推 `beta`）
- `<上游 tag>`：如 `v0.107.80`，**生产部署建议用它钉版本**
- `amd64`：架构标签

平台：`linux/amd64` 单架构。

## 首次启用

1. 仓库 → **Settings → Secrets and variables → Actions** 添加：

   | Secret | 值 |
   | --- | --- |
   | `ALIYUN_USERNAME` | 阿里云账号全名（或 ACR 用户名） |
   | `ALIYUN_PASSWORD` | ACR「访问凭证」里设置的**固定密码**，不是登录密码 |
   | `ALIYUN_REGISTRY` | ACR 实例域名，形如 `<实例前缀>.cn-guangzhou.personal.cr.aliyuncs.com` |
   | `ALIYUN_NAMESPACE` | ACR 命名空间 |

   可选 Docker Hub：`DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN`。

   ⚠️ ACR **不会自动建仓库**，必须先在控制台建好命名空间和 `adguardhome-deploy` 仓库，否则推送报 `name unknown`。
   四个 `ALIYUN_*` 缺任何一个，工作流直接失败（ACR 是唯一主通道，不允许"静默跳过"）。

2. **Actions** → `Sync & Build AdGuard Home (linux/amd64)` → **Run workflow**，勾 `force`。

3. 确认镜像架构与内容：

   ```bash
   docker buildx imagetools inspect <ALIYUN_REGISTRY>/<ALIYUN_NAMESPACE>/adguardhome-deploy:<tag>
   docker pull <ALIYUN_REGISTRY>/<ALIYUN_NAMESPACE>/adguardhome-deploy:<tag>
   docker image inspect <ALIYUN_REGISTRY>/<ALIYUN_NAMESPACE>/adguardhome-deploy:<tag> --format '{{.Architecture}}'
   # 期望 amd64
   ```

## 触发方式

- **定时**：每天 UTC 18:00（北京 02:00）检查上游 Release
- **手动**：Actions → Run workflow
  - `force`：上游 tag 未变化也强制重建（首次启用、补推某个 registry 时用）
  - `channel`：`stable`（默认）或 `beta`（推 `beta` 标签，不进 `latest`）

指纹 = `tag + BUILD_REV + 通道状态 + 架构 + 通道标签`，写入 `last-build.txt`，无变化就跳过构建。
配好/更换 ACR 凭据后指纹会变化，会自动再构建一次并补推，不需要手动勾 `force`。

无上游更新时，工作流每 5 天提交一次 `last-check.txt` 心跳，避免 GitHub「60 天无提交停用定时任务」。

## NAS 端部署

```yaml
services:
  adguardhome:
    image: <ALIYUN_REGISTRY>/<ALIYUN_NAMESPACE>/adguardhome-deploy:v0.107.80
    container_name: adguardhome
    restart: unless-stopped
    network_mode: host            # DNS 要看真实客户端 IP，必须 host
    command:
      - --no-check-update
      - -c
      - /opt/adguardhome/conf/AdGuardHome.yaml
      - -w
      - /opt/adguardhome/work
      - --web-addr
      - 0.0.0.0:3001              # 宿主 80/443/3000 可能已被占用
    volumes:
      - ./conf:/opt/adguardhome/conf
      - ./work:/opt/adguardhome/work
    logging:
      options:
        max-size: "10m"
        max-file: "3"
```

ACR 仓库若设为**公开**（本次部署用的是公开仓库），拉取不需要登录；设为私有才需要：

```bash
# 私有仓库才需要
docker login <ALIYUN_REGISTRY>
docker compose pull && docker compose up -d
```

首次访问 `http://<NAS-IP>:3001` 走向导设置管理员账号。

## 更新流程

上游发新版 → 定时任务自动构建并覆盖 `latest` → NAS 执行：

```bash
docker compose pull && docker compose up -d
```

生产建议钉版本标签，升级时手动改 tag。

## 扩展到多架构

当前只发 amd64。要加 arm64 / armv7 时，`ARCH_NAME` 单值不够用，改成矩阵构建并在 workflow 内下载对应 tarball
（文件名规律：`AdGuardHome_linux_${arch}${variant}.tar.gz`，例如 `linux/arm/v7` → `AdGuardHome_linux_armv7.tar.gz`），
各架构分别 build+push 后再用 `docker buildx imagetools create` 合成多架构 manifest，最后推 `latest`。
注意 `provenance: false` 必须保留。

## 修改管理员密码

AdGuard Home（v0.107 旧 UI 与 v1.0 新 UI **都是**）没有"修改密码"界面：语言包里只有
`password_login_error` / `install_auth_password` / `forgot_password`，接口里也没有 `/control/users`。
而且 `users: []` 不是"进入安装向导"，而是**关闭鉴权**（`internal/home/auth.go` 的 `isUserless`）。

真正的 first-run 只由**配置文件是否存在**决定（`internal/home/web.go` 的 `conf.firstRun`），所以改密码要这样：

```bash
cd /vol1/1000/Docker/adguardhome
sudo docker compose stop
cp -p conf/AdGuardHome.yaml conf/AdGuardHome.yaml.full-settings   # 留作之后合并
mv conf/AdGuardHome.yaml conf/AdGuardHome.yaml.wizard-off
sudo docker compose start
# 浏览器打开 :3001 走完向导：设新用户名/密码，Web 端口 3001、DNS 端口 53
```

⚠️ 向导**只设端口、不设上游 DNS**，走完必须把 `upstream_dns` / `bootstrap_dns` 改成
`223.5.5.5`、`119.29.29.29`（默认是 Quad9，国内不通），否则解析会全挂。
过滤规则（AdGuard DNS filter）向导会自动启用，不用手动加。

## 已知限制

| 限制 | 说明 |
| --- | --- |
| 不编译源码 | 二进制来自上游 release，本项目不做安全审计；如需完全自编译，参见上游 `make build-docker`（需 Go 1.27.4 + 两套前端 npm 构建，30–60 分钟） |
| 只发 stable 会滞后 | 上游 beta（`v1.0.0-b.x`）有新 UI，但默认不进 `latest` |
| 容器内不自动升级 | 镜像 CMD 带 `--no-check-update`，升级只能 `docker compose pull` |
| ACR 登录失败直接失败 | ACR 是唯一主通道，登录失败会把整次运行标红，不会出现"CI 全绿但拉不到镜像" |
| 基础镜像 `alpine:3.23` | 上游 `docker/build.Dockerfile` 同款；上游升级基镜像时本仓库需手动跟进 |
