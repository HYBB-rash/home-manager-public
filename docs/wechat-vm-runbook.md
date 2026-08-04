# 微信导出器 VM 初始化

VM 和宿主机桥接层中刻意不包含账号标识、微信密钥、原始数据库、导出器
源代码、SSH 私钥或 SOPS 数据。Second User 使用的稳定数据库路径是：

```text
/var/lib/hermes-user2-wechat/current/snapshot.db
```

只有 root 可以替换 `current` 这一代快照。Second User 通过用户组获得完整快照和
清单的读取权限；文件权限和 Hermes 的 systemd 沙箱共同禁止写入。

Second User 的 Hermes 服务环境中提供
`WECHAT_SNAPSHOT_DB=/var/lib/hermes-user2-wechat/current/snapshot.db`，并包含
`sqlite3`。该路径仅应以只读 URI 使用，例如
`sqlite3 "file:$WECHAT_SNAPSHOT_DB?mode=ro&immutable=1" 'PRAGMA integrity_check'`；
不要将快照复制到 workspace，也不要尝试写入。

## Second User 的微信日报技能

`hermes-user2.service` 的 profile 会安装 `wechat-daily` 技能。它只读取上述
稳定快照路径，默认生成不含消息正文的活动汇总；日报和其他生成物必须留在 Second User
自己的 workspace，属于私有用户数据，不进入本仓库。

在 Hermes 会话中可先执行不读取消息内容的就绪检查：

```bash
python3 "$HERMES_HOME/skills/wechat-daily/scripts/daily_report.py" --smoke-test
```

随后从目标 workspace 生成过去 24 小时的汇总：

```bash
mkdir -p reports
python3 "$HERMES_HOME/skills/wechat-daily/scripts/daily_report.py" \
  --hours 24 --output reports/wechat-daily.md
```

默认输出只有消息数、活跃会话数和会话类别。只有在用户明确要求消息级细节时，才可
添加 `--include-snippets`；不得对源快照执行写入、`VACUUM`、`ATTACH`、导出或复制。

## Cron 职责划分

导出、解密、增量同步和导出健康由 VM 内的 `wechat-exporter-sync.service` 负责；宿主机
的 `wechat-snapshot-pull.timer` 每分钟验证并拉取完成快照。不要在 Hermes cron 中重跑
`sync.py`、扫描 VM 的 `published_*.db`，或让 Second User 访问 `/home/user`。

Second User 的 Hermes cron 只运行快照消费者。`$HERMES_HOME/scripts/wechat_snapshot_feed.py`
从 `WECHAT_SNAPSHOT_DB` 以 immutable 只读方式生成 15 分钟或 24 小时 feed；每日模式将
公众号编号索引写入 Second User 私有的 `runtime/wechat_daily_brief_items.json`。
`wechat_brief_search.py` 只查询该索引，不重新读取数据库。cron job 的脚本路径和环境均由
Second User 的 profile 提供，不设置或使用 `WX_PROJECT_DIR`。

应用宿主机配置并重启 `hermes-user2.service` 后，可以使用下列命令在该服务的
实际 mount namespace 中做非内容验证：它只检查固定路径是否可读、不可写，不打开或查询数据库。

```bash
pid="$(systemctl show hermes-user2.service -p MainPID --value)"
test "$pid" -gt 0
sudo nsenter --mount="/proc/$pid/ns/mnt" \
  --setuid="$(id -u user2)" \
  --setgid="$(getent group hermes-user2 | cut -d: -f3)" \
  -- test -r /var/lib/hermes-user2-wechat/current/snapshot.db
sudo nsenter --mount="/proc/$pid/ns/mnt" \
  --setuid="$(id -u user2)" \
  --setgid="$(getent group hermes-user2 | cut -d: -f3)" \
  -- test ! -w /var/lib/hermes-user2-wechat/current/snapshot.db
```

## 应用配置、构建和导入

先应用宿主机配置，以安装 `wechat-vmctl`、拉取定时器和 Second User 的只读边界，
然后构建并导入虚拟设备：

```bash
sudo nixos-rebuild switch --flake .#nixos
nix build .#wechat-exporter-vm
wechat-vmctl import result/*.ova
wechat-vmctl console
```

如果 `wechat-vmctl status` 已经能看到 `wechat-exporter`，说明 VM 已导入，
不要再次执行 `import`，直接运行 `wechat-vmctl console`。该命令会通过受限的
systemd 控制入口启动 VM，并用 FreeRDP 打开本地控制台。关闭 RDP 窗口不会
关闭 VM；`wechat-exporter-vm.service` 会让它继续以无头模式运行，并在之后
每次宿主机启动时自动恢复。

`wechat-vmctl stop` 会依次尝试 Guest Additions 关机和 ACPI 关机；若客体
因锁屏等原因没有响应，则保存完整 VM 状态后停止，不会直接强制断电。下次
启动会从保存点继续运行。

导入命令会检查或添加两个仅监听回环地址的 NAT 转发：22222 端口用于受限的
快照拉取，22223 端口用于 VM 操作者。它不会删除或改写已有的冲突
规则。这个稀疏虚拟设备配有独立的 256 GiB ext4 数据盘，挂载到
`/home/wechat-exporter/.var`，使微信 Flatpak 账号数据与 50 GiB 系统盘分离。

## 迁移后的首次启动

从新版 OVA 启动的 VM 使用全新的系统盘。256 GiB 数据盘只保存
`/home/wechat-exporter/.var` 下的微信运行数据，**不包含 Flatpak 客户端软件本身**；
因此迁移后首次打开控制台发现微信尚未安装是预期现象，不表示数据盘丢失。

在 VM 的 Xfce 终端中安装客户端：

```bash
wechat-install-flatpak
```

安装完成后，从 Xfce 菜单启动微信。微信是否保留登录态取决于其本地认证状态与
账号安全策略；即使历史数据仍在，首次在新系统盘运行时要求重新扫码登录也属于
预期现象。登录和手机确认必须由人工完成，本配置不会代替账号执行扫码或确认。

迁移期间，旧的 `wechat-exporter` VM 及其原始数据盘保持不变；
`/home/user/VirtualBox VMs/wechat-exporter-lan-rollback/` 中还保留了独立的
256 GiB 数据盘克隆。在新的 VM 稳定运行、数据和同步均确认正常前，不要删除这些
回退资源。

## 按需启用局域网桥接

默认只有 NIC1 的 NAT 网络和上述两个回环端口转发。NIC2 为 NAT 附加但网线断开，
因此没有地址、没有网络路径，也不会改动 NIC1 或任何 NAT 转发。需要让 VM 临时
出现在局域网时，使用宿主机上的受控 NIC2；它只桥接到 `wlp0s20f3`。新版 VM
镜像为 NIC2 固定 MAC `08:00:27:A1:1C:E2`，在客体中以稳定的第二插槽名称
`enp0s8` 出现。只有这个接口被声明为 firewall trusted；全局防火墙仍然启用，
NIC1 仍只按现有规则开放 SSH：

```bash
wechat-vmctl bridge status
wechat-vmctl bridge enable
```

`enable` 仅在 NIC2 尚未按预期桥接时生效。受 systemd 管理且正在运行的 VM 使用
VirtualBox 热插拔 NIC2，不会停止、保存或重启 VM；NIC1、NAT 转发及 RDP 会话保持
不变。启用时，NIC2 以该固定 MAC 附加到桥接，客体中的 `enp0s8` 因而获得受
信任的入站访问，供手机同步使用。关机或中止的 VM 则在下一次启动前修改 NIC2。
保存状态的 VM 必须先通过 `wechat-vmctl start` 恢复后再操作，避免 VirtualBox 对
保存状态拒绝硬件配置变更。

完成局域网访问后立即关闭桥接：

```bash
wechat-vmctl bridge disable
wechat-vmctl bridge status
```

`disable` 将 NIC2 恢复为 NAT 附加并断开网线。`enp0s8` 虽会保留为一个没有载波、
没有地址的接口，但没有任何受信任接口可经由网络到达；这恢复了桥接前的
客体防火墙暴露面。同样保留 NIC1 NAT、22222/22223 的回环转发以及 VM 原有的
运行状态。状态显示
`enabled (wlp0s20f3, NIC2)` 或 `disabled (NIC2)`；任何其他 NIC2 配置都会以
非零状态退出，要求先人工检查。

首次启用前，VM 必须已经从包含上述客体网络策略的新版 OVA 导入，或已经以同一
Nix 配置完成客体系统更新。只更新宿主机配置不会把客体防火墙规则注入旧 VM；在
未满足此前提时不得启用桥接。

当前迁移完成后，受管的新 VM 名称为 `wechat-exporter-lan-secure`；旧的
`wechat-exporter` 保持注册且为保存状态，作为本地回退实例。

RDP 控制台使用 Oracle Extension Pack 的 VRDE，只监听
`127.0.0.1:33890`。`wechat-vmctl` 在 User 的 0700 状态目录中生成专用
随机密码，以 `VBoxAuthSimple` 完成认证，并通过标准输入把连接参数交给
FreeRDP，因此密码不会出现在进程参数中。RDP 的剪贴板和音频重定向均关闭。

仅用于 VM 的 nixpkgs overlay 会把锁定版 LKL 镜像构建器硬编码的内存上限从
100 MiB 提高到 512 MiB。这个调整只影响 OVA 构建，不会改变虚拟机配置的
8 GiB 运行时内存。

## 建立信任关系

虚拟设备中不会预置 SSH 公钥。生成并显示宿主机上的两把公钥：

```bash
wechat-vmctl operator-key
wechat-vmctl pull-key
```

在 `wechat-vmctl console` 打开的 VM 控制台中，只登记操作者公钥：

```bash
sudo wechat-authorize-operator 'ssh-ed25519 ...'
```

在该 VM 控制台中，显示虚拟机主机密钥指纹：

```bash
wechat-show-host-fingerprint
```

在屏幕上完成比对后，在宿主机上固定这个准确的指纹：

```bash
wechat-vmctl trust-host-key SHA256:...
```

客体当前不提供 root 权限时，改由已登记的操作者通道安装拉取规则：

```bash
wechat-vmctl configure-rootless-pull
```

该命令把宿主机 root 持有的拉取公钥写入 `wechat-exporter` 的授权文件，但其
权限被限制为固定命令 `wechat-snapshot-read-v1`：不能取得 shell、不能转发端口、
不能请求其他路径；它只能把唯一已完成的 `published_*.db` 以单文件
`snapshot.db` 流输出。宿主机仍会验证 SQLite 完整性和完整 Schema，并原子发布
给 Second User。拉取私钥仍然只有 root 可访问；操作者私钥保存在宿主机操作者的
`~/.local/state/wechat-vm/` 下。Second User 无法访问其中任何一把私钥。

## 部署并到达登录边界

部署一次导出器已经提交的 `HEAD`。该命令使用 `git archive`，因此本地被
忽略或未跟踪的账号密钥和配置不会进入 VM。部署先在 VM 的暂存目录运行测试，
成功后才原子切换运行版本；不会在 VM 中执行 `git pull`。

```bash
wechat-vmctl deploy /home/user/Projects/Hermes/wechat-linux-decrypt-demo
```

首次部署后，在 VM 中根据第二个账号的本地设置创建
`/var/lib/wechat-exporter/state/config.local.json`。不要把密钥放入该文件。然后运行：

```bash
wechat-exporterctl test
wechat-install-flatpak
```

从 RDP 控制台里的 Xfce 菜单启动微信。此处停止，由人工扫码并在手机上
确认。本配置中的任何服务都不会自动执行登录。扫码完成后可以关闭 RDP
窗口，VM 和微信会继续运行。

## 人工登录完成后

只有登录完成后，VM 操作者才运行：

```bash
wechat-exporterctl acquire-keys
wechat-exporterctl extract
wechat-exporterctl export
wechat-exporterctl start
```

配置文件和密钥文件就绪后，导出器服务会在之后每次虚拟机启动时运行。
微信也会在专用的 Xfce 会话中启动，因此预期只需要进行一次交互式账号登录。

## 日常发布和回退

代码、账号状态与发布物严格分离：

```text
/var/lib/wechat-exporter/
  releases/<git-commit>/     # 不可变代码版本
  current -> releases/...    # 当前运行版本
  previous -> releases/...   # 上一个可回退版本
  state/                     # config、keys、解密缓存和 published_*.db
```

发布只传送导出项目的已提交 `HEAD`。若 `state` 已准备好配置和密钥，控制器会重启
服务并最多等待三分钟执行只读健康检查；检查失败会自动恢复 `previous`。首次登录尚未
完成时，发布会成功完成代码切换并明确提示 bootstrap 未完成，不会把“没有数据”误报成
发布失败。

```bash
wechat-vmctl deploy /home/user/Projects/Hermes/wechat-linux-decrypt-demo
wechat-vmctl release-status
wechat-vmctl rollback
```

`rollback` 只切换代码软链接并重启服务，绝不回退或删除 `state` 中的微信数据、密钥和
发布数据库。当前正在运行的已迁移 VM 会保留一个兼容启动器，直到下次重新制作 VM 镜像；
这不影响发布语义，也不要求重装微信或重新登录。

虚拟机暴露定时器只接受一个已经完成的 `published_*.db`，使用 SQLite backup
API，要求导出器的完整 Schema，执行 `integrity_check`，并以原子方式切换到
一个由 SHA-256 标识的快照版本。宿主机每分钟重复执行清单、哈希、Schema
和完整性校验，默认保留三个版本。
