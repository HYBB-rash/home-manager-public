# 微信导出器 VM 初始化

VM 和宿主机桥接层中刻意不包含账号标识、微信密钥、原始数据库、导出器
源代码、SSH 私钥或 SOPS 数据。Second User 使用的稳定数据库路径是：

```text
/var/lib/hermes-user2-wechat/current/snapshot.db
```

只有 root 可以替换 `current` 这一代快照。Second User 通过用户组获得完整快照和
清单的读取权限；文件权限和 Hermes 的 systemd 沙箱共同禁止写入。

## 应用配置、构建和导入

先应用宿主机配置，以安装 `wechat-vmctl`、拉取定时器和 Second User 的只读边界，
然后构建并导入虚拟设备：

```bash
sudo nixos-rebuild switch --flake .#nixos
nix build .#wechat-exporter-vm
wechat-vmctl import result/*.ova
wechat-vmctl start
```

导入后，`wechat-exporter-vm.service` 会在宿主机之后的每次启动时以无头模式
启动 VM。第一次显式启动时会保留控制台，以便完成初始化和二维码登录。

导入命令会检查或添加两个仅监听回环地址的 NAT 转发：22222 端口用于仅限
SFTP 的快照账号，22223 端口用于 VM 操作者。它不会删除或改写已有的冲突
规则。这个稀疏虚拟设备配有独立的 256 GiB ext4 数据盘，挂载到
`/home/wechat-exporter/.var`，使微信 Flatpak 账号数据与 50 GiB 系统盘分离。

仅用于 VM 的 nixpkgs overlay 会把锁定版 LKL 镜像构建器硬编码的内存上限从
100 MiB 提高到 512 MiB。这个调整只影响 OVA 构建，不会改变虚拟机配置的
8 GiB 运行时内存。

## 建立信任关系

虚拟设备中不会预置 SSH 公钥。生成并显示宿主机上的两把公钥：

```bash
wechat-vmctl operator-key
wechat-vmctl pull-key
```

在 VM 控制台中，分别登记上面显示的准确公钥：

```bash
sudo wechat-authorize-operator 'ssh-ed25519 ...'
sudo wechat-authorize-puller 'ssh-ed25519 ...'
```

在 VM 控制台中，显示虚拟机主机密钥指纹：

```bash
wechat-show-host-fingerprint
```

在屏幕上完成比对后，在宿主机上固定这个准确的指纹：

```bash
wechat-vmctl trust-host-key SHA256:...
```

拉取私钥仍然只有 root 可访问。操作者私钥保存在宿主机操作者的
`~/.local/state/wechat-vm/` 下。Second User 无法访问其中任何一把私钥。

## 部署并到达登录边界

部署一次导出器已经提交的 `HEAD`。该命令使用 `git archive`，因此本地被
忽略或未跟踪的账号密钥和配置不会进入 VM。VM 会初始化自己的可变 Git
仓库，因此之后在导出器一侧开发时不依赖宿主机上的副本。

```bash
wechat-vmctl deploy /home/user/Projects/Hermes/wechat-linux-decrypt-demo
```

在 VM 中，根据第二个账号的本地设置创建
`/var/lib/wechat-exporter/source/` 下的 `config.local.json`。不要把密钥放入
该文件。然后运行：

```bash
wechat-exporterctl test
wechat-install-flatpak
```

从 Xfce 菜单启动微信。此处停止，由人工扫码并在手机上确认。本配置中的
任何服务都不会自动执行登录。

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

虚拟机暴露定时器只接受一个已经完成的 `published_*.db`，使用 SQLite backup
API，要求导出器的完整 Schema，执行 `integrity_check`，并以原子方式切换到
一个由 SHA-256 标识的快照版本。宿主机每分钟重复执行清单、哈希、Schema
和完整性校验，默认保留三个版本。
