# sing-box 安全更新器

用于安装、更新和回滚 [sing-box](https://github.com/SagerNet/sing-box) 的官方 GitHub Release 软件包。更新前会缓存当前版本；新版本的配置校验、服务重启或短时间健康检查失败时，脚本会自动回滚到更新前版本。

支持首次安装，但首次安装**只安装软件包**：不会要求已有配置、不会启用服务、也不会启动服务，便于先按自己的需求修改配置。

## 支持环境

- Debian / Ubuntu 等使用 `dpkg` 的系统：安装 `.deb` 包，支持 `systemd` 或 `init.d`。
- OpenWrt 25.12+：安装 `.apk` 包，使用 `/etc/init.d`。

脚本按本机环境自动识别包管理器、服务管理器与架构。OpenWrt 若自动识别的架构名与 GitHub Release 资产名不一致，可通过 `PACKAGE_ARCH` 覆盖。

## 功能

- 正式版与测试版（prerelease）渠道更新。
- 首次安装正式版或测试版；也支持指定版本安装。
- 更新前校验当前配置、缓存旧包，并拒绝 Debian 降级更新。
- 更新后校验配置、重启服务并观察健康状态。
- 更新失败自动回滚；手动回滚仅使用本地已缓存的包。
- 每次更新或手动回滚成功后，自动清理旧缓存，仅保留当前运行版本和一个上一版本，用于下次自动更新与手动回滚。
- 防止并发运行、保留更新日志和包缓存。
- 交互式数字菜单，以及适合 systemd timer / cron 的非交互参数。

## 文件

项目包含：

- `singbox-updater`：主脚本。
- `README.md`：使用说明。

## 安装脚本

Debian：

```bash
sudo install -m 0755 singbox-updater /usr/local/sbin/singbox-updater
```

OpenWrt：

```sh
install -m 0755 singbox-updater /usr/local/sbin/singbox-updater
```

## 交互式使用

不带参数运行会显示菜单：

```sh
/usr/local/sbin/singbox-updater
```

主菜单顶部会显示当前 sing-box 版本、运行状态和开机启动状态。菜单提供以下操作：

1. 更新 sing-box，再选择正式版或测试版；
2. 首次安装 sing-box，再选择正式版或测试版；
3. 强制安装指定版本（不重启、不自动回滚）；
4. 回滚到本地缓存版本。

重点状态与选项会使用颜色标记；设置 `NO_COLOR=1` 可关闭颜色输出。

## 命令行用法

### 更新

测试版更新：

```sh
/usr/local/sbin/singbox-updater --update --channel beta
```

正式版更新：

```sh
/usr/local/sbin/singbox-updater --update --channel stable
```

`--channel` 可选值为 `stable` 和 `beta`，默认是 `beta`。

普通更新要求当前 `sing-box` 服务正在运行。它会先用当前二进制校验配置、缓存当前版本包，再下载并安装目标版本；新版本通过配置校验、服务重启和健康观察后才算成功。任何步骤失败都会尝试恢复更新前版本。

### 首次安装

安装最新测试版：

```sh
/usr/local/sbin/singbox-updater --install
```

安装最新正式版：

```sh
/usr/local/sbin/singbox-updater --install --channel stable
```

安装指定版本：

```sh
/usr/local/sbin/singbox-updater --install 1.14.0
```

首次安装只安装官方 Release 包。脚本不会检查配置文件、启用服务或启动服务。请修改 `/etc/sing-box/config.json` 后，再自行启动服务：

```sh
# systemd
systemctl enable --now sing-box

# OpenWrt
/etc/init.d/sing-box enable
/etc/init.d/sing-box start
```

### 强制安装指定版本

```sh
/usr/local/sbin/singbox-updater --force 1.14.0-alpha.41
```

强制模式只安装指定 Release 包，不执行更新后的配置检查、不重启服务，也不自动回滚。适合先升级二进制、再手动迁移配置的场景。

### 手动回滚

交互选择本地缓存版本：

```sh
/usr/local/sbin/singbox-updater --rollback
```

指定缓存版本：

```sh
/usr/local/sbin/singbox-updater --rollback 1.14.0-alpha.41
```

手动回滚不会下载历史版本，只能使用 `/var/cache/singbox-updater/packages/` 中已有的对应包。回滚后同样会校验配置、重启并观察服务；失败时会自动恢复回滚前版本。

## 配置

默认值：

| 项目 | 默认值 |
| --- | --- |
| 配置文件 | `/etc/sing-box/config.json` |
| 服务名 / 包名 | `sing-box` |
| 包管理器 | 自动识别：`deb` 或 `apk` |
| 服务管理器 | 自动识别：`systemd` 或 `initd` |
| 更新后的观察时间 | `5` 秒 |
| 包缓存目录 | `/var/cache/singbox-updater` |
| 更新日志 | `/var/log/singbox-updater.log` |

可通过环境变量覆盖默认值，例如 OpenWrt 架构名需要手动指定时：

```sh
PACKAGE_ARCH=aarch64_cortex-a53 /usr/local/sbin/singbox-updater --update --channel beta
```

其他可用覆盖项包括 `PACKAGE_MANAGER`、`SERVICE_MANAGER`、`CONFIG_FILE`、`SERVICE_NAME`、`PACKAGE_NAME`、`VERIFY_SECONDS`、`CACHE_DIR` 和 `LOG_FILE`。

## Debian 自动更新

创建 `/etc/systemd/system/singbox-updater.service`：

```ini
[Unit]
Description=Safely update sing-box beta with rollback
Documentation=https://sing-box.sagernet.org/installation/package-manager/
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/singbox-updater --update --channel beta
Nice=5
```

创建每日运行的 `/etc/systemd/system/singbox-updater.timer`：

```ini
[Unit]
Description=Daily safe sing-box beta update

[Timer]
OnCalendar=*-*-* 04:30:00
RandomizedDelaySec=30m
Persistent=true
AccuracySec=5m
Unit=singbox-updater.service

[Install]
WantedBy=timers.target
```

加载并启用 timer：

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now singbox-updater.timer
```

如需自动跟踪正式版，将 service 中的 `--channel beta` 改为 `--channel stable`，然后执行 `systemctl daemon-reload`。

## OpenWrt 自动更新

使用 cron 每日更新测试版：

```sh
grep -q 'singbox-updater' /etc/crontabs/root 2>/dev/null || \
  echo '30 4 * * * /usr/local/sbin/singbox-updater --update --channel beta' >> /etc/crontabs/root

/etc/init.d/cron enable
/etc/init.d/cron restart
```

查看当前 cron：

```sh
cat /etc/crontabs/root
```

## 日志与缓存

查看更新日志：

```sh
tail -n 200 /var/log/singbox-updater.log
```

查看更新 service 的日志：

```sh
journalctl -u singbox-updater.service -n 120 --no-pager
```

查看缓存包：

```sh
ls -lh /var/cache/singbox-updater/packages/
```

## 注意事项

- 脚本必须以 root 运行。
- `--update` 用于定时任务；不要让 cron 或 systemd timer 直接调用无参数脚本，否则它会进入交互菜单。
- 成功更新后缓存会自动清理，仅保留当前运行版本和一个上一版本；这样下次更新通常只需下载新版本，同时仍可手动回滚。不要把缓存目录当作长期版本仓库。
- 更新默认面向 GitHub Release 软件包。若系统上的 sing-box 来自第三方 feed 或自行编译，请先确认包名、架构、版本规则和服务路径一致。
- OpenWrt 使用本地 Release `.apk` 包执行 `apk add --allow-untrusted`，不会执行 `apk upgrade`，因此不会触发整机包升级。
- 更新自动回滚成功时，脚本默认以退出码 `20` 结束，便于监控系统识别发生过回滚。
