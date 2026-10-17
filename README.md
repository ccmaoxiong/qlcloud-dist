# QL Cloud · 青龙面板自助开通商业化平台（发行版）

> 用户注册 → 选购套餐 / 兑换卡密 / 余额支付 → 自动创建独立青龙 Docker 容器 → 到期自动停机。
> **闭源商业软件**：发行包为单文件可执行程序（Node SEA，内置运行时与前端资源，磁盘不落地任何 JS 源码）；
> 服务端带 Ed25519 授权校验，需厂商签发的授权密钥才能启动。授权条款见 [LICENSE](LICENSE)。

- 一键安装：非交互、可重复执行（重跑即升级），支持 x86_64 / arm64，无需预装 Node.js 与 npm
- 自动化交付：支付成功自动开容器、续期 / 升级（换绑套餐、时长叠加）、到期停机、自动续费；镜像拉取失败可配加速地址、预拉取并一键重试开通
- 资源隔离：每个套餐 / 实例可配 CPU 上限（核）与内存上限（MB），开通即按 docker --cpus / --memory 下发，续费 / 升级自动同步
- 商业化闭环：易支付协议（含主动查单）、卡密系统、余额钱包、增值服务、工单、通知渠道
- 独立管理后台 `/admin-panel`：工作台 / 用户 / 实例 / 套餐 / 卡密 / 订单 / 通知 / 审计 / 系统配置

---

## 一、环境要求

| 项目 | 要求 |
|---|---|
| 系统 | Linux（x86_64 / arm64），推荐 Ubuntu 22.04+ / Debian 12+ / 主流云镜像 |
| 权限 | root（安装脚本用 `sudo sh` 运行） |
| 依赖 | `curl` 或 `wget`；授权校验需要 `openssl`、`base64`、`perl`、`awk`（发行版自带） |
| Docker | 承载青龙实例（未安装时平台可运行，但开通实例功能不可用；可用 `QL_INSTALL_DOCKER=1` 顺带安装） |
| 网络 | 可访问 GitHub Releases（国内服务器用 `install-cn.sh` 镜像加速） |

> 安装脚本**先验证授权、再下载任何文件**：未提供有效授权密钥时直接中止（`install-cn.sh` 连校验脚本也不会下载）。

## 二、一键安装（版本锁定）

以下命令均为**单行**：整行复制粘贴即可完成安装（命令与本次发行版本绑定；安装脚本内置默认版本，也可显式指定）。

```bash
# 直连（推荐：GitHub API 返回原始文件，按版本 tag 锁定）
curl --http1.1 -fsSL --retry 5 --retry-delay 2 -H "Accept: application/vnd.github.raw+json" "https://api.github.com/repos/ccmaoxiong/qlcloud-dist/contents/install.sh?ref=v1.0.0" -o /tmp/qlcloud-install.sh && sudo QL_LICENSE='QLC-你的授权密钥' sh /tmp/qlcloud-install.sh

# 直连备用（GitHub API 入口不可用时，从 Release 资产下载）
curl --http1.1 -fsSL --retry 5 --retry-delay 2 "https://github.com/ccmaoxiong/qlcloud-dist/releases/download/v1.0.0/install.sh" -o /tmp/qlcloud-install.sh && sudo QL_LICENSE='QLC-你的授权密钥' sh /tmp/qlcloud-install.sh
```

国内服务器（专用安装器：从镜像下载 `SHA256SUMS` 与 `install.sh`，与脚本内置 SHA256 指纹逐一比对，
全部一致才执行；任一镜像校验失败自动换下一个，全部失败即中止，不会运行未经验证的脚本）：

```bash
curl -4 --http1.1 -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 -o /tmp/qlcloud-install-cn.sh "https://ghfast.top/https://github.com/ccmaoxiong/qlcloud-dist/releases/download/v1.0.0/install-cn.sh" && sudo QL_LICENSE='QLC-你的授权密钥' sh /tmp/qlcloud-install-cn.sh
```

> `install-cn.sh` 与版本绑定（内置该版本 `SHA256SUMS` 与 `install.sh` 的 SHA256 指纹）：升级时请改用新版本 Release 里的 `install-cn.sh`。
> 自建/私有镜像：设置 `QL_CN_MIRROR_BASE_URL` 指向完整 Release 资产基址（空格分隔多个，`<基址>/SHA256SUMS`、`<基址>/install.sh` 可访问）。

安装完成后：

| 入口 | 地址 |
|---|---|
| 用户面板 | `http://<服务器IP>:3000` |
| 管理后台 | `http://<服务器IP>:3000/admin-panel` |

| 角色 | 默认账号 | 默认密码 |
|---|---|---|
| 平台管理员 | `admin@example.com`（或 `admin`） | `admin12345` |
| 普通用户 | `user@example.com`（或 `user`） | `user12345` |

> ⚠️ 首次登录请立即修改默认密码（管理后台 → 账号资料）。
> 生产环境请在前置反向代理上配置 HTTPS，并放行青龙实例端口段（默认 15700-15999，可在管理后台 → 系统配置调整；新实例在范围内随机分配端口，避免顺序可猜）。

## 三、安装脚本做了什么

1. 用**内嵌公钥**离线验证 `QL_LICENSE`（Ed25519 验签 + 到期校验），不通过立即退出；
2. 按 CPU 架构下载 `qlcloud-server-<版本>-linux-<arch>.tar.gz` 并校验 `SHA256SUMS`；
3. 解出单文件可执行程序 `qlcloud-server`，安装到 `/opt/qlcloud`；
4. 授权密钥写入 `/etc/qlcloud/license.key`（root 写、服务用户只读）；
5. 生成 `/etc/qlcloud/qlcloud.env`（端口 / 数据目录 / JWT 密钥），注册并启动 systemd 服务 `qlcloud`；
6. 把服务用户加入 `docker` 组（Docker 已安装时），并做一次 `http://127.0.0.1:<端口>/api/site` 健康检查。

## 四、可配置环境变量（均可选）

| 变量 | 默认 | 说明 |
|---|---|---|
| `QL_LICENSE` | （必填） | 厂商签发的授权密钥（`QLC-…`） |
| `QL_VERSION` | 发行包内置 | 指定版本（如 `v1.0.1`）；`latest` 取最新 Release |
| `QL_PORT` | `3000` | 服务端口 |
| `QL_INSTALL_DIR` | `/opt/qlcloud` | 程序目录（升级时只覆盖该目录） |
| `QL_DATA_DIR` | `/var/lib/qlcloud` | 数据目录（db.json / jwt.secret；升级保留） |
| `QL_CONFIG_DIR` | `/etc/qlcloud` | 配置目录（qlcloud.env / license.key） |
| `QL_SERVICE_USER` | `qlcloud` | 服务运行用户（自动创建） |
| `QL_JWT_SECRET` | 自动生成 | 固定 JWT 密钥（写入配置文件） |
| `QL_DOWNLOAD_BASE_URL` | 空 | 下载镜像前缀（如 `https://ghfast.top`），加速 GitHub 下载 |
| `QL_CN_MIRROR_BASE_URL` | 空 | 仅 `install-cn.sh`：自定义镜像基址（空格分隔多个，指完整 Release 资产基址） |
| `QL_UPDATE_MIRRORS` | 空 | 面板内更新的下载镜像前缀（空格/逗号分隔，如 `https://ghfast.top`），也可登录管理后台在「版本与更新」页配置 |
| `QL_RESTART_MODE` | 自动识别 | 面板重启方式：`systemd`（退出后由守护拉起）/ `self`（自拉起）；仅在自动识别不适用时手工指定 |
| `QL_LOCAL_DIR` | 空 | 离线安装：指向含 `.tar.gz` 与 `SHA256SUMS` 的本地目录 |
| `QL_INSTALL_DOCKER` | 空 | `1` = 顺带安装 Docker 并拉取青龙镜像 |
| `QL_OPEN_FIREWALL` | 空 | `1` = 用 ufw / firewalld 放行服务端口 |
| `QL_UNINSTALL` | 空 | `1` = 卸载（保留数据目录） |
| `QL_PURGE` | 空 | 配合 `QL_UNINSTALL=1`：连数据目录一起删除 |

即：把 `sudo QL_LICENSE=... sh ...` 换成 `sudo QL_LICENSE=... QL_PORT=8080 sh ...` 即可自定义。

## 五、升级 / 卸载

### 面板内一键更新（推荐）

登录管理后台 → 「版本与更新」：点「检查更新」比对最新 Release，点「立即更新」自动完成
下载 → SHA256 校验 → 备份旧程序（`.bak`）→ 替换 → 重启；更新完成后页面自动刷新。
「重启面板」按钮用于手动重启服务进程（用户实例容器不受影响）。

- 适用范围：Linux 服务端；Windows 或不可写安装目录请用下方安装命令升级。
- 国内服务器若连接 GitHub 超时，在「更新源与加速」填写 API 基址与下载镜像前缀，或直接在
  环境文件 `/etc/qlcloud/qlcloud.env` 中设置 `QL_UPDATE_MIRRORS` / `QL_UPDATE_API_BASE` 后重启服务。
- 数据、授权密钥与配置均不随更新变动；回滚可手动把 `qlcloud-server.bak` 改回 `qlcloud-server` 后重启。
- 重启策略：systemd 托管时退出进程交由 `Restart=always` 拉起；其余场景（裸进程 / nohup / pm2）自动脱离
  父进程拉起新进程，确认新进程已监听端口后才退出；新进程启动失败则不退出，旧进程继续服务并在
  「版本与更新」页给出错误。重启细节写 `<数据目录>/restart.log`（含新进程的启动输出）。

### 安装脚本升级（跨大版本 / 指定版本）

```bash
# 升级（程序覆盖、数据与授权保留）：使用新版本 Release 的安装命令（单行）重跑即可，例如
curl --http1.1 -fsSL --retry 5 -H "Accept: application/vnd.github.raw+json" "https://api.github.com/repos/ccmaoxiong/qlcloud-dist/contents/install.sh?ref=v1.0.0" -o /tmp/qlcloud-install.sh && sudo QL_LICENSE='QLC-你的授权密钥' sh /tmp/qlcloud-install.sh

# 指定版本 / 回到旧版（install.sh 支持 QL_VERSION 指定目标 Release tag）
sudo QL_LICENSE='QLC-…' QL_VERSION=<目标版本> sh /tmp/qlcloud-install.sh

# 卸载（保留数据）；彻底卸载加 QL_PURGE=1
sudo QL_UNINSTALL=1 sh /tmp/qlcloud-install.sh
sudo QL_UNINSTALL=1 QL_PURGE=1 sh /tmp/qlcloud-install.sh
```

## 六、安装校验与运维

```bash
sha256sum -c SHA256SUMS                 # 1) 资产完整性（在发行目录内）
systemctl status qlcloud                # 2) 服务状态
curl -fsS http://127.0.0.1:3000/api/site  # 3) 接口自检
journalctl -u qlcloud -n 100            # 4) 日志（授权状态、错误原因）
```

| 命令 | 说明 |
|---|---|
| `systemctl restart qlcloud` | 重启服务 |
| `journalctl -u qlcloud -f` | 实时日志 |
| `cat /etc/qlcloud/qlcloud.env` | 查看端口 / 数据目录 / JWT 密钥配置 |

## 七、常见问题

| 现象 | 处理 |
|---|---|
| 提示「授权密钥验签失败 / 已到期」 | 确认密钥完整复制（含 `QLC-` 前缀与 `~` 分组符）；到期请联系厂商续期 |
| `curl` 下载失败（国内） | 改用 `install-cn.sh`，或设置 `QL_DOWNLOAD_BASE_URL=https://ghfast.top` |
| 无法访问面板 | 放行 TCP 端口（`QL_OPEN_FIREWALL=1`，或云厂商安全组）；确认 `systemctl status qlcloud` 正常 |
| 端口被占用 | 改端口：`QL_PORT=8080 sh /tmp/qlcloud-install.sh`（已安装则编辑 `qlcloud.env` 后重启） |
| 实例开通失败 | `docker ps` 确认 Docker 正常；日志确认服务用户在 `docker` 组（`id qlcloud`） |
| 升级后配置丢失 | 配置在 `/etc/qlcloud`、数据在 `/var/lib/qlcloud`，升级不会触碰；请勿手工删这两个目录 |

## 八、合规提示

本软件仅提供技术平台能力。使用者须自行确保其业务（支付通道、域名备案、用户数据处理、
自动化脚本内容等）符合所在地法律法规与第三方平台规则；因违规使用产生的后果由使用者自行承担。

---

© QL Cloud. 保留一切权利。未经书面授权，禁止复制、分发、转售、反编译或绕过授权校验。
购买授权 / 技术支持：请通过发行方公布的联系方式（见仓库主页或 Release 说明）。
