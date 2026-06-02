# Singbox-Auto-Updater

用途：维护已通过官方方式安装的 sing-box beta。脚本检查 GitHub Releases 最新 prerelease，安装前缓存当前版本包；如果新版本配置校验失败、服务启动失败或短时间内崩溃，自动回滚到更新前版本。

支持两类环境：

- Debian 13：`dpkg` + `systemd`
- OpenWrt 25.12+：`apk` + `/etc/init.d`

不包含 sing-box 初始安装功能。先按官方方式安装并确认 `sing-box` 服务正常运行，再使用本脚本维护后续 beta 更新。

## 文件

本项目只保留：

- `singbox-updater`
- `README.md`

## 手动部署

Debian：

```bash
sudo install -m 0755 singbox-updater /usr/local/sbin/singbox-updater
```

OpenWrt：

```sh
install -m 0755 singbox-updater /usr/local/sbin/singbox-updater
```

手动运行一次：

```sh
/usr/local/sbin/singbox-updater
```

## 配置

默认不需要配置文件。当前默认值就是：

- 配置文件：`/etc/sing-box/config.json`
- 服务名：`sing-box`
- 包名：`sing-box`
- 观察时间：30 秒
- 平台：自动识别 Debian/OpenWrt

通常只需要复制脚本并运行。需要改默认值时，直接编辑脚本顶部几行。

OpenWrt 如果自动识别的架构名和 GitHub release 资产名不一致，可以在 cron 里指定 `PACKAGE_ARCH`，例如：

```sh
30 4 * * * PACKAGE_ARCH=aarch64_cortex-a53 /usr/local/sbin/singbox-updater
```

## Debian 每天自动运行

创建 systemd service：

```bash
sudo tee /etc/systemd/system/singbox-updater.service >/dev/null <<'EOF'
[Unit]
Description=Safely update sing-box beta with rollback
Documentation=https://sing-box.sagernet.org/installation/package-manager/
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/singbox-updater
Nice=5
EOF
```

创建 systemd timer：

```bash
sudo tee /etc/systemd/system/singbox-updater.timer >/dev/null <<'EOF'
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
EOF
```

启用 timer：

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now singbox-updater.timer
```

## OpenWrt 每天自动运行

OpenWrt 没有 systemd，使用 cron：

```sh
grep -q 'singbox-updater' /etc/crontabs/root 2>/dev/null || \
  echo '30 4 * * * /usr/local/sbin/singbox-updater' >> /etc/crontabs/root

/etc/init.d/cron enable
/etc/init.d/cron restart
```

查看 cron：

```sh
cat /etc/crontabs/root
```

## 日志

脚本日志：

```sh
tail -n 200 /var/log/singbox-updater.log
```

Debian 服务日志：

```bash
journalctl -u singbox-updater.service -n 120 --no-pager
```

OpenWrt 系统日志：

```sh
logread | grep -i sing-box
```

## 行为

- 更新前要求当前 `sing-box` 服务必须正在运行。
- 更新前先用旧版本执行配置校验；旧版本都校验失败时，不升级。
- 旧版本包会缓存到 `/var/cache/singbox-updater/packages/`。
- Debian 下载 `sing-box_<version>_linux_<arch>.deb`，使用 `dpkg -i` 安装和回滚。
- OpenWrt 下载 `sing-box_<version>_openwrt_<arch>.apk`，使用 `apk add --allow-untrusted` 安装和回滚。
- 新 beta 安装后，会再次校验配置，并重启 `sing-box`。
- Debian 使用 systemd 的重启计数判断短时间崩溃。
- OpenWrt 使用 `/etc/init.d` 状态和 `sing-box` 进程 PID 变化判断短时间崩溃。
- 回滚成功后，`sing-box` 服务应恢复运行；更新器默认以退出码 `20` 结束，方便看出发生过回滚。

## 注意

OpenWrt 25.12+ 已切换到 `apk`。本脚本只对 sing-box 本地 release 包执行 `apk add --allow-untrusted`，不执行 `apk upgrade`，避免误做整机包升级。

如果你不是用官方 GitHub release 包安装 sing-box，而是改用某个第三方 feed 或自编译包，不建议直接复用默认下载规则；应先确认包名、版本号、架构名和 init 脚本路径完全一致。
