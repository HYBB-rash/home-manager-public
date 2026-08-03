# Hermes 双用户启动与运维手册

本文是本机 User/Second User 双实例 Hermes 的日常操作入口，面向 Fish shell。
首次创建 age/SOPS、日常启动、交互式配置、微信扫码、导出个性配置、写回 SOPS
以及已遇到过的故障都集中在这里。SOPS 的设计和安全细节见
[SOPS-Nix Hermes 个性化配置部署](./sops-hermes.zh-CN.md)。

## 0. 先记住这几个概念

本机有两个完全分开的实例：

| 实例 | 系统用户 | 后台服务 | 交互式命令 | 数据目录 |
| --- | --- | --- | --- | --- |
| User | `user` | `hermes-user.service` | `hermes-user-cli` | `/var/lib/hermes-user` |
| Second User | `user2` | `hermes-user2.service` | `hermes-user2-cli` | `/var/lib/hermes-user2` |

后台服务负责 Telegram、Discord、Slack、Weixin/微信等消息平台；TUI、经典 CLI
和 dashboard 是人工交互入口。两者可以同时运行。

后台服务在系统启动时运行，不依赖用户登录，也不需要 user lingering。交互式
wrapper 可修改对应用户的个性配置；后台 systemd 服务仍以 managed mode 运行。

SOPS 中的八个键是可重建的稳定版本：

```text
hermes-user-env
hermes-user-config
hermes-user-soul
hermes-user-user
hermes-user2-env
hermes-user2-config
hermes-user2-soul
hermes-user2-user
```

交互式修改会立即写入 `/var/lib/hermes-<用户>/home`，但下一次 Nix/SOPS
个性配置部署会恢复上述稳定版本。需要长期保留的修改必须先导出并写回 SOPS。

## 1. 最常用的启动命令

### 1.1 应用仓库配置

```fish
cd ~/.config/home-manager
sudo nixos-rebuild switch --flake .#nixos
```

### 1.2 启动两个后台消息网关

```fish
sudo systemctl enable --now hermes-user.service
sudo systemctl enable --now hermes-user2.service
```

只启动 Second User：

```fish
sudo systemctl start hermes-user2.service
```

重启 Second User：

```fish
sudo systemctl restart hermes-user2.service
```

停止 Second User：

```fish
sudo systemctl stop hermes-user2.service
```

检查是否已经随系统启动：

```fish
systemctl is-enabled hermes-user.service
systemctl is-enabled hermes-user2.service
systemctl is-active hermes-user.service
systemctl is-active hermes-user2.service
```

### 1.3 启动交互式 TUI

User：

```fish
sudo -u user /run/current-system/sw/bin/hermes-user-cli --tui
```

Second User：

```fish
sudo -u user2 /run/current-system/sw/bin/hermes-user2-cli --tui
```

### 1.4 启动经典 CLI

```fish
sudo -u user /run/current-system/sw/bin/hermes-user-cli --cli
sudo -u user2 /run/current-system/sw/bin/hermes-user2-cli --cli
```

### 1.5 启动或检查 dashboard

```fish
sudo -u user /run/current-system/sw/bin/hermes-user-cli dashboard
sudo -u user2 /run/current-system/sw/bin/hermes-user2-cli dashboard
```

```fish
sudo -u user /run/current-system/sw/bin/hermes-user-cli dashboard --status
sudo -u user2 /run/current-system/sw/bin/hermes-user2-cli dashboard --status
```

```fish
sudo -u user /run/current-system/sw/bin/hermes-user-cli dashboard --stop
sudo -u user2 /run/current-system/sw/bin/hermes-user2-cli dashboard --stop
```

系统重建不会改变已经运行进程的环境。重建 wrapper 后，应退出旧 TUI/CLI/dashboard
并重新启动。

## 2. 查看配置、诊断和日志

查看最终生效配置：

```fish
sudo -u user /run/current-system/sw/bin/hermes-user-cli config
sudo -u user2 /run/current-system/sw/bin/hermes-user2-cli config
```

运行 Hermes 自检：

```fish
sudo -u user /run/current-system/sw/bin/hermes-user-cli doctor
sudo -u user2 /run/current-system/sw/bin/hermes-user2-cli doctor
```

查看 systemd 状态：

```fish
systemctl status hermes-user.service
systemctl status hermes-user2.service
systemctl status hermes-profile-user.service
systemctl status hermes-profile-user2.service
```

查看最近日志：

```fish
sudo journalctl \
    -u hermes-profile-user.service \
    -u hermes-user.service \
    -u hermes-profile-user2.service \
    -u hermes-user2.service \
    -n 100 --no-pager
```

持续跟踪 Second User 日志：

```fish
sudo journalctl -u hermes-user2.service -f
```

只看本次系统启动的错误：

```fish
sudo journalctl \
    -u hermes-profile-user2.service \
    -u hermes-user2.service \
    -b -p err --no-pager
```

## 3. 修改个性配置

交互式 wrapper 完全开放配置写入。以下命令都通过目标用户自己的 wrapper 运行：

```fish
sudo -u user /run/current-system/sw/bin/hermes-user-cli setup
sudo -u user2 /run/current-system/sw/bin/hermes-user2-cli setup
```

```fish
sudo -u user /run/current-system/sw/bin/hermes-user-cli config edit
sudo -u user2 /run/current-system/sw/bin/hermes-user2-cli config edit
```

```fish
sudo -u user /run/current-system/sw/bin/hermes-user-cli gateway setup
sudo -u user2 /run/current-system/sw/bin/hermes-user2-cli gateway setup
```

不要直接运行裸 `hermes`，也不要手工拼接 `HOME`、`HERMES_HOME` 或 XDG 变量。
wrapper 会自动进入对应 workspace，并保持两个用户的配置、会话、记忆和缓存隔离。

不要使用 `sudo --chdir` 或 `sudo -D`。当前 sudoers 不允许该能力，wrapper 已在
内部完成 `cd`。

### 3.1 配置微信/Weixin

以 Second User 为例：

```fish
sudo -u user2 /run/current-system/sw/bin/hermes-user2-cli gateway setup
```

在向导中：

1. 选择 `Weixin / WeChat`。
2. 使用微信扫描终端二维码并在手机上确认。
3. 设置私聊授权策略。
4. 选择 `Done`。
5. “是否立即启动 gateway”回答 `n`。
6. “是否安装开机启动服务”也回答 `n`。

不要让 Hermes 另装一套 systemd 服务。本机只使用 Nix 管理的
`hermes-user2.service`。扫码完成后：

```fish
sudo systemctl restart hermes-user2.service
systemctl status hermes-user2.service
```

User 的微信配置入口：

```fish
sudo -u user /run/current-system/sw/bin/hermes-user-cli gateway setup
```

微信扫码结果写入对应用户的 `.env`。在下一次重建前，按第 5、6 节导出并写回
`hermes-<用户>-env`。

### 3.2 配置 Telegram、Discord、Slack 或其他平台

仍然使用同一向导：

```fish
sudo -u user /run/current-system/sw/bin/hermes-user-cli gateway setup
sudo -u user2 /run/current-system/sw/bin/hermes-user2-cli gateway setup
```

每个用户必须使用自己的平台机器人、应用身份、令牌或 OAuth 材料。共享的推理
API 账号可以把同一个 `DEEPSEEK_API_KEY` 分别写进两个用户的 env；消息平台身份
不得跨用户共用。

使用本地 webhook/API 监听端口的平台必须为两个实例配置不同端口。Telegram
轮询、Discord gateway 和 Slack socket mode 不共享监听端口，但仍须使用独立身份。

## 4. 准备 SOPS 命令

以下 Fish 变量和函数供后续写回、验证使用。每次打开新 Fish 会话后可重新执行：

```fish
cd ~/.config/home-manager

set sops_out (nix build --no-link --print-out-paths nixpkgs#sops)
set sops_bin "$sops_out/bin/sops"

set jq_out (nix build --no-link --print-out-paths nixpkgs#jq)
set jq_bin "$jq_out/bin/jq"

sudo -v

function put_hermes_secret --argument-names key source
    "$jq_bin" --raw-input --slurp '.' "$source" | \
        sudo env SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt \
        "$sops_bin" set --value-stdin \
        secrets/hermes.yaml "[\"$key\"]"
end
```

这里必须使用 `jq --raw-input --slurp` 和 `sops set --value-stdin`。不要改回
`sops set --value-file`，否则 dotenv、YAML 和 Markdown 会报：

```text
Value for --set is not valid JSON
```

秘密值只通过标准输入传递；不要放入命令参数，也不要额外创建 JSON 明文文件。

## 5. 导出当前个性配置

导出只包括 `.env`、`config.yaml`、`SOUL.md` 和 `USER.md`。不会导出 sessions、
memories、cache、logs 或 workspace。

### 5.1 导出 User

```fish
set user_export (mktemp -d --tmpdir hermes-user-export.XXXXXXXX)
chmod 0700 "$user_export"

sudo -v
sudo install -o (id -u) -g (id -g) -m 0600 \
    /var/lib/hermes-user/home/.env \
    "$user_export/user.env"
sudo install -o (id -u) -g (id -g) -m 0600 \
    /var/lib/hermes-user/home/config.yaml \
    "$user_export/user-config.yaml"
sudo install -o (id -u) -g (id -g) -m 0600 \
    /var/lib/hermes-user/home/SOUL.md \
    "$user_export/user-SOUL.md"
sudo install -o (id -u) -g (id -g) -m 0600 \
    /var/lib/hermes-user/home/USER.md \
    "$user_export/user-USER.md"

echo "User profile exported to $user_export"
```

### 5.2 导出 Second User

```fish
set user2_export (mktemp -d --tmpdir hermes-user2-export.XXXXXXXX)
chmod 0700 "$user2_export"

sudo -v
sudo install -o (id -u) -g (id -g) -m 0600 \
    /var/lib/hermes-user2/home/.env \
    "$user2_export/user2.env"
sudo install -o (id -u) -g (id -g) -m 0600 \
    /var/lib/hermes-user2/home/config.yaml \
    "$user2_export/user2-config.yaml"
sudo install -o (id -u) -g (id -g) -m 0600 \
    /var/lib/hermes-user2/home/SOUL.md \
    "$user2_export/user2-SOUL.md"
sudo install -o (id -u) -g (id -g) -m 0600 \
    /var/lib/hermes-user2/home/USER.md \
    "$user2_export/user2-USER.md"

echo "Second User profile exported to $user2_export"
```

可以列出文件名和权限，但不要把内容输出到终端：

```fish
ls -la "$user_export"
ls -la "$user2_export"
```

## 6. 把导出内容写回 SOPS

先执行第 4 节，确保 `put_hermes_secret`、`sops_bin` 和 `jq_bin` 已定义。

### 6.1 写回 User

```fish
put_hermes_secret hermes-user-env \
    "$user_export/user.env"
put_hermes_secret hermes-user-config \
    "$user_export/user-config.yaml"
put_hermes_secret hermes-user-soul \
    "$user_export/user-SOUL.md"
put_hermes_secret hermes-user-user \
    "$user_export/user-USER.md"
```

### 6.2 写回 Second User

```fish
put_hermes_secret hermes-user2-env \
    "$user2_export/user2.env"
put_hermes_secret hermes-user2-config \
    "$user2_export/user2-config.yaml"
put_hermes_secret hermes-user2-soul \
    "$user2_export/user2-SOUL.md"
put_hermes_secret hermes-user2-user \
    "$user2_export/user2-USER.md"
```

SOPS 由 `sudo` 执行，写完后恢复仓库文件所有权：

```fish
sudo chown (id -u):(id -g) secrets/hermes.yaml
chmod 0644 secrets/hermes.yaml
```

## 7. 验证 SOPS 后重建

验证全部八项，但不打印任何明文：

```fish
set hermes_keys \
    hermes-user-env hermes-user-config \
    hermes-user-soul hermes-user-user \
    hermes-user2-env hermes-user2-config \
    hermes-user2-soul hermes-user2-user

set validation_failed 0
sudo -v

for key in $hermes_keys
    sudo env SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt \
        "$sops_bin" --decrypt \
        --extract "[\"$key\"]" \
        secrets/hermes.yaml >/dev/null

    or begin
        echo "验证失败：$key"
        set validation_failed 1
        break
    end
end

if test $validation_failed -eq 0
    echo "SOPS 验证通过：八项配置均存在且可以解密"
end
```

只有验证全部通过后才检查和重建：

```fish
if test $validation_failed -eq 0
    nix flake check --no-write-lock-file
    and sudo nixos-rebuild dry-activate --flake .#nixos
    and sudo nixos-rebuild switch --flake .#nixos
end
```

重建后检查两个实例：

```fish
systemctl is-active hermes-user.service
systemctl is-active hermes-user2.service

sudo -u user /run/current-system/sw/bin/hermes-user-cli doctor
sudo -u user2 /run/current-system/sw/bin/hermes-user2-cli doctor
```

## 8. 删除明文导出

只有 SOPS 验证、系统重建和服务验证全部成功后，才能删除明文导出。

删除 User 导出：

```fish
rm "$user_export/user.env" \
    "$user_export/user-config.yaml" \
    "$user_export/user-SOUL.md" \
    "$user_export/user-USER.md"
rmdir "$user_export"
set -e user_export
```

删除 Second User 导出：

```fish
rm "$user2_export/user2.env" \
    "$user2_export/user2-config.yaml" \
    "$user2_export/user2-SOUL.md" \
    "$user2_export/user2-USER.md"
rmdir "$user2_export"
set -e user2_export
```

清理 Fish 函数和工具变量：

```fish
functions -e put_hermes_secret
set -e sops_bin sops_out jq_bin jq_out
```

## 9. 首次创建 age/SOPS

本节只用于新机器或完全重建秘密基础设施。已有
`/var/lib/sops-nix/key.txt` 时不要覆盖。

检查密钥是否存在：

```fish
sudo test -f /var/lib/sops-nix/key.txt
and echo "age key already exists"
```

新机器生成 age 身份：

```fish
nix shell nixpkgs#age --command bash -c '
  sudo install -d -m 0700 /var/lib/sops-nix
  sudo "$(command -v age-keygen)" -o /var/lib/sops-nix/key.txt
  sudo chmod 0600 /var/lib/sops-nix/key.txt
'
```

检查权限而不读取密钥：

```fish
sudo stat -c '%U:%G %a %n' /var/lib/sops-nix/key.txt
```

取得可公开的 recipient：

```fish
set age_keygen_bin \
    (nix shell nixpkgs#age --command bash -c 'command -v age-keygen')
set recipient \
    (sudo "$age_keygen_bin" -y /var/lib/sops-nix/key.txt)
echo "$recipient"
```

创建或编辑 SOPS 文件：

```fish
cd ~/.config/home-manager
set sops_bin (nix shell nixpkgs#sops nixpkgs#age --command which sops)
sudo env SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt \
    "$sops_bin" --config /dev/null --age "$recipient" \
    secrets/hermes.yaml
sudo chown (id -u):(id -g) secrets/hermes.yaml
chmod 0644 secrets/hermes.yaml
```

文件中必须存在第 0 节列出的八个键。共享 API key 要分别放进 User 和 Second User
自己的 env 值；平台令牌只放进所属用户的 env 值。

## 10. 已遇到过的错误

### 10.1 `Value for --set is not valid JSON`

原因：把 dotenv、YAML 或 Markdown 原文直接传给了 `sops set --value-file`。

修复：使用第 4 节的 `jq --raw-input --slurp` 和 `--value-stdin` 管道。原失败发生
在写入前，通常不会破坏 `secrets/hermes.yaml`。

### 10.2 `the key 'hermes-...' cannot be found`

原因：`system/services.nix` 已声明该键，但加密文件中尚不存在，或路径拼写错误。

单独验证某个键：

```fish
sudo env SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt \
    "$sops_bin" --decrypt \
    --extract '["hermes-user2-config"]' \
    secrets/hermes.yaml >/dev/null
```

必须使用 `["hermes-..."]` 形式的 JSON 路径。补齐全部八个键并验证后再重建。

### 10.3 `Unit sops-install-secrets.service not found`

当前模块会根据 `sops.useSystemdActivation` 决定是否依赖该单元。出现此错误通常
表示仍在运行旧系统 generation。先更新仓库并完整重建：

```fish
cd ~/.config/home-manager
nix flake check --no-write-lock-file
and sudo nixos-rebuild switch --flake .#nixos
```

检查当前生成单元：

```fish
systemctl cat hermes-profile-user.service
systemctl cat hermes-profile-user2.service
```

### 10.4 `sudo: you are not permitted to use the -D option`

原因：`sudo --chdir` 等价于 `sudo -D`，当前 sudoers 不允许。

修复：不要修改 sudoers，直接使用系统 wrapper：

```fish
sudo -u user /run/current-system/sw/bin/hermes-user-cli --tui
sudo -u user2 /run/current-system/sw/bin/hermes-user2-cli --tui
```

### 10.5 CLI 提示 `HERMES_MANAGED=true`

当前交互式 wrapper 不设置 managed mode；后台服务才设置。出现提示时通常是旧
wrapper 或旧进程：

```fish
cd ~/.config/home-manager
sudo nixos-rebuild switch --flake .#nixos
```

退出旧 TUI/CLI/dashboard，再通过 `/run/current-system/sw/bin/hermes-<用户>-cli`
重新启动。

### 10.6 Second User 服务启动失败

按以下顺序检查：

```fish
systemctl status hermes-profile-user2.service
systemctl status hermes-user2.service
sudo journalctl \
    -u hermes-profile-user2.service \
    -u hermes-user2.service \
    -n 100 --no-pager
sudo -u user2 /run/current-system/sw/bin/hermes-user2-cli doctor
```

常见原因是 SOPS 键缺失、环境值格式错误、平台令牌无效或本地监听端口冲突。

### 10.7 配置改完后又消失

原因：运行时修改没有写回 SOPS，后续 profile 部署恢复了稳定版本。

修复：按第 5 节导出、第 6 节写回、第 7 节验证并重建。不要在导出和写回之前
再次执行 `nixos-rebuild switch`。

## 11. 安全边界

- 不读取、打印、截图或粘贴 `/var/lib/sops-nix/key.txt`。
- 不把 `.env`、解密后的 YAML/Markdown、导出目录或编辑器备份加入 Git。
- `secrets/hermes.yaml` 是密文，可以纳入私有仓库，但仍要经过公开导出净化扫描。
- 不把 JSON 编码后的秘密放进命令参数；使用标准输入。
- 不使用额外 JSON 明文临时文件。
- User 和 Second User 的平台身份必须独立；共享推理 API 账号是唯一允许的共享凭据。
- 不手工安装第二套 Hermes gateway systemd 服务。
- 不同时运行 `hermes gateway run --force` 和对应的 Nix systemd gateway。
- 删除明文导出前，先验证 SOPS、重建结果和服务状态。

## 12. 最短恢复清单

以后只想确认“系统能不能跑”，依次执行：

```fish
cd ~/.config/home-manager
sudo nixos-rebuild switch --flake .#nixos

sudo systemctl enable --now hermes-user.service
sudo systemctl enable --now hermes-user2.service

systemctl is-active hermes-user.service
systemctl is-active hermes-user2.service

sudo -u user /run/current-system/sw/bin/hermes-user-cli doctor
sudo -u user2 /run/current-system/sw/bin/hermes-user2-cli doctor
```

启动 Second User TUI：

```fish
sudo -u user2 /run/current-system/sw/bin/hermes-user2-cli --tui
```

启动 User TUI：

```fish
sudo -u user /run/current-system/sw/bin/hermes-user-cli --tui
```
