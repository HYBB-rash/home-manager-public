# SOPS-Nix Hermes 个性化配置部署

[日常启动与运维手册](./hermes-multiuser-runbook.zh-CN.md) | [English](./sops-hermes.md)

本仓库为每个已配置的普通用户运行一个系统级 Hermes 网关。本地
`services.hermesMultiUser` 模块使用上游 Hermes 软件包，但不使用其只能运行
单个实例的 NixOS 服务模块。每个网关都有各自独立的 `HERMES_HOME`、状态目录、
私有 Unix 用户组，以及单独设置权限的 SOPS 部署。

加密源数据保存在 `secrets/hermes.yaml`。Nix 只接收 SOPS 键名和运行时目标路径：
任何个性化配置内容、令牌、平台身份或服务商凭据都不会渲染到 derivation 中，
也不会复制进 Nix store。NixOS 模块要求 age 身份文件位于
`/var/lib/sops-nix/key.txt`。

请从仓库根目录运行本文命令。示例使用临时 Nix shell，因此无须永久安装
`sops` 和 `age`。

## 1. 安装或生成 age 身份

不要覆盖已经存在的身份文件：

```bash
sudo test -f /var/lib/sops-nix/key.txt && echo "age key already exists"
```

在新机器上，直接在模块配置的路径生成身份文件，并确保只有 root 可以读取：

```bash
nix shell nixpkgs#age --command bash -c '
  sudo install -d -m 0700 /var/lib/sops-nix
  sudo "$(command -v age-keygen)" -o /var/lib/sops-nix/key.txt
  sudo chmod 0600 /var/lib/sops-nix/key.txt
'
```

Fish 等价命令：

```fish
nix shell nixpkgs#age --command bash -c '
  sudo install -d -m 0700 /var/lib/sops-nix
  sudo "$(command -v age-keygen)" -o /var/lib/sops-nix/key.txt
  sudo chmod 0600 /var/lib/sops-nix/key.txt
'
```

在不打印密钥内容的情况下检查权限：

```bash
sudo stat -c '%U:%G %a %n' /var/lib/sops-nix/key.txt
```

## 2. 获取 recipient

从私有身份文件导出公开的 age recipient。recipient 以 `age1` 开头，可以安全地
公开；绝对不要公开 `key.txt`。

```bash
age_keygen_bin=$(nix shell nixpkgs#age --command bash -c 'command -v age-keygen')
recipient=$(sudo "$age_keygen_bin" -y /var/lib/sops-nix/key.txt)
echo "$recipient"
```

```fish
set -l age_keygen_bin (nix shell nixpkgs#age --command bash -c 'command -v age-keygen')
set -l recipient (sudo "$age_keygen_bin" -y /var/lib/sops-nix/key.txt)
echo "$recipient"
```

## 3. 创建或编辑 `secrets/hermes.yaml`

`sudo` 通常使用受限的 `PATH`。请通过临时 shell 解析 SOPS 的绝对路径，再让
`sudo` 使用这个路径。

Bash：

```bash
set -euo pipefail
recipient='age1REPLACE_WITH_THE_RECIPIENT_FROM_STEP_2'
sops_bin=$(nix shell nixpkgs#sops nixpkgs#age --command which sops)
mkdir -p secrets
sudo env \
  SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt \
  "$sops_bin" --config /dev/null --age "$recipient" secrets/hermes.yaml
```

Fish：

```fish
set -l recipient 'age1REPLACE_WITH_THE_RECIPIENT_FROM_STEP_2'
set -l sops_bin (nix shell nixpkgs#sops nixpkgs#age --command which sops)
mkdir -p secrets
sudo env \
  SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt \
  "$sops_bin" --config /dev/null --age "$recipient" secrets/hermes.yaml
```

对于新文件，SOPS 会打开编辑器。添加 `system/services.nix` 中声明的秘密键。
每个已启用实例都需要自己的 dotenv 键，并且每个稳定个性化配置文件都需要一个
独立加密键。服务商账号可以共享，但必须把相同密钥值分别写进两个用户各自的
dotenv 部署。平台令牌、OAuth 材料以及所有用户专属数据只能放在对应用户的
加密键中。

初始的双实例映射如下：

```yaml
hermes-user-env: |
  DEEPSEEK_API_KEY=REPLACE_WITH_SHARED_PROVIDER_TOKEN
  TELEGRAM_BOT_TOKEN=REPLACE_WITH_USER_A_BOT_TOKEN
hermes-user-config: |
  # Hermes YAML configuration for this user only
hermes-user-soul: |
  # Persona for this user only
hermes-user-user: |
  # User context for this user only
hermes-user2-env: |
  DEEPSEEK_API_KEY=REPLACE_WITH_SHARED_PROVIDER_TOKEN
  TELEGRAM_BOT_TOKEN=REPLACE_WITH_USER_B_BOT_TOKEN
hermes-user2-config: |
  # Hermes YAML configuration for this user only
hermes-user2-soul: |
  # Persona for this user only
hermes-user2-user: |
  # User context for this user only
```

两个 dotenv 值可以包含相同的 `DEEPSEEK_API_KEY`。所有消息平台凭据，包括
Telegram、Discord、Slack 以及其他平台令牌或 OAuth 材料，都必须只标识对应的
那个用户。两个实例之间不得复用机器人或应用令牌。

如果八项配置已经分别保存在受保护运行时目录（例如 `$draft`）中的明文文件里，
必须先把每个完整文件编码为一个 JSON 字符串，再传给 `sops set`。SOPS 3.13
要求 `set` 读取的值是合法 JSON。`--value-file` 不会自动把 dotenv、YAML 或
Markdown 文本编码成 JSON，因此直接使用会报
`Value for --set is not valid JSON`。

在建立管道前先完成 `sudo` 认证。编码后的值应当只通过标准输入传递：不要把它
放进命令参数，也不要创建中间 JSON 文件。Bash：

```bash
set -euo pipefail
sops_bin=$(nix shell nixpkgs#sops --command which sops)
jq_bin=$(nix shell nixpkgs#jq --command which jq)
sudo -v

put_hermes_secret() {
  local key=$1 source=$2
  "$jq_bin" --raw-input --slurp '.' "$source" |
    sudo env SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt \
      "$sops_bin" set --value-stdin secrets/hermes.yaml "[\"$key\"]"
}

put_hermes_secret hermes-user-env    "$draft/user.env"
put_hermes_secret hermes-user-config "$draft/user-config.yaml"
put_hermes_secret hermes-user-soul   "$draft/user-SOUL.md"
put_hermes_secret hermes-user-user   "$draft/user-USER.md"
put_hermes_secret hermes-user2-env      "$draft/user2.env"
put_hermes_secret hermes-user2-config   "$draft/user2-config.yaml"
put_hermes_secret hermes-user2-soul     "$draft/user2-SOUL.md"
put_hermes_secret hermes-user2-user     "$draft/user2-USER.md"
unset -f put_hermes_secret
sudo chown "$(id -u):$(id -g)" secrets/hermes.yaml
chmod 0644 secrets/hermes.yaml
```

Fish：

```fish
set sops_bin (nix shell nixpkgs#sops --command which sops)
set jq_bin (nix shell nixpkgs#jq --command which jq)
sudo -v

function put_hermes_secret --argument-names key source
    "$jq_bin" --raw-input --slurp '.' "$source" | \
        sudo env SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt \
        "$sops_bin" set --value-stdin \
        secrets/hermes.yaml "[\"$key\"]"
end

put_hermes_secret hermes-user-env    "$draft/user.env"
put_hermes_secret hermes-user-config "$draft/user-config.yaml"
put_hermes_secret hermes-user-soul   "$draft/user-SOUL.md"
put_hermes_secret hermes-user-user   "$draft/user-USER.md"
put_hermes_secret hermes-user2-env      "$draft/user2.env"
put_hermes_secret hermes-user2-config   "$draft/user2-config.yaml"
put_hermes_secret hermes-user2-soul     "$draft/user2-SOUL.md"
put_hermes_secret hermes-user2-user     "$draft/user2-USER.md"
functions -e put_hermes_secret
sudo chown (id -u):(id -g) secrets/hermes.yaml
chmod 0644 secrets/hermes.yaml
```

要添加稳定的 skills、plugins、工具设置或平台配置，请为每个文件添加一个加密
SOPS 键，并在相应的 `profile.files` 属性中建立映射。属性键是相对于
`HERMES_HOME` 的安全路径；初始设置只映射 `config.yaml`、`SOUL.md` 和
`USER.md`。`cache`、`cron`、`logs`、`memories`、`runtime` 和 `sessions`
目录下的文件以及 `.env` 都属于可变运行时状态，不能声明为个性化配置文件。

对于已经存在的文件，同一条命令会打开文件进行编辑。SOPS 会以加密形式重写
文件；不要提交明文、编辑器备份或解密后的个性化配置导出。

## 4. 验证

在不打印明文的情况下验证全部八个配置键。只成功写入其中一部分不算完成。

```bash
sops_bin=$(nix shell nixpkgs#sops --command which sops)
hermes_keys=(
  hermes-user-env hermes-user-config hermes-user-soul hermes-user-user
  hermes-user2-env hermes-user2-config hermes-user2-soul hermes-user2-user
)
sudo -v
for key in "${hermes_keys[@]}"; do
  sudo env SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt \
    "$sops_bin" --decrypt --extract "[\"$key\"]" \
    secrets/hermes.yaml >/dev/null || exit 1
done
echo 'SOPS validation passed: all eight values exist and decrypt'
```

```fish
set sops_bin (nix shell nixpkgs#sops --command which sops)
set hermes_keys \
    hermes-user-env hermes-user-config \
    hermes-user-soul hermes-user-user \
    hermes-user2-env hermes-user2-config \
    hermes-user2-soul hermes-user2-user
set validation_failed 0
sudo -v
for key in $hermes_keys
    sudo env SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt \
        "$sops_bin" --decrypt --extract "[\"$key\"]" \
        secrets/hermes.yaml >/dev/null
    or begin
        echo "Validation failed: $key"
        set validation_failed 1
        break
    end
end
if test $validation_failed -eq 0
    echo 'SOPS validation passed: all eight values exist and decrypt'
end
```

只有当八项配置全部通过验证后，才能删除明文 `$draft` 目录、移除
`system/services.nix` 中临时的 `sops.validateSopsFiles = false` 及其说明注释，
然后继续操作。如果任意键验证失败，必须停止：只在修正加密文件期间保留关闭
严格验证的设置，不要重建系统。

移除临时设置后，运行：

```bash
nix flake check --no-write-lock-file
sudo nixos-rebuild dry-activate --flake .#nixos
```

## 5. 应用配置

```bash
sudo nixos-rebuild switch --flake .#nixos
systemctl is-active hermes-user.service
systemctl is-active hermes-user2.service
sudo journalctl -u hermes-user.service -u hermes-user2.service -n 50 --no-pager
```

每个 `hermes-<instance>.service` 都挂载到 `multi-user.target`；不需要用户登录，
也不需要 user lingering。个性化配置部署单元首先以 root 身份运行，然后把配置
文件和 dotenv 安装为对应实例用户所有。该用户可以通过交互式 CLI 修改自己的
配置；后续个性化配置部署会恢复 SOPS 中的版本，因此需要长期保留的运行时改动
必须回存 SOPS。网关只能写入自己的 `HERMES_HOME` 和 workspace。sessions、
运行时 memories、cache 和 logs 有意不纳入 Git。

任何绑定本地监听端口的平台，都必须为两个用户配置不同端口。尤其是 Hermes 的
`api_server`、WhatsApp Cloud webhook 和 BlueBubbles webhook 默认设置，不能在
两个实例中原样同时启用。Telegram 轮询、Discord 网关和 Slack socket mode
不共享这些监听端口，但仍然必须使用每个用户各自独立的机器人或应用身份。

## 交互式 CLI

systemd 后台网关和 Hermes 交互会话是两个独立入口。完成系统重建后，以目标
操作系统用户运行自动生成的包装器：

```fish
sudo -u user /run/current-system/sw/bin/hermes-user-cli --tui
sudo -u user2 /run/current-system/sw/bin/hermes-user2-cli --tui
```

经典 CLI 使用 `--cli`。以下命令可以查看最终生效的配置和运行诊断，不会启动
第二个后台网关：

```fish
sudo -u user2 /run/current-system/sw/bin/hermes-user2-cli config
sudo -u user2 /run/current-system/sw/bin/hermes-user2-cli doctor
```

每个包装器都会检查操作系统用户，设置该实例隔离的 `HOME`、`HERMES_HOME` 和
XDG 路径，在包装器内部进入对应 workspace，最后执行此 flake 锁定的 Hermes
软件包。它不使用 `sudo --chdir`/`sudo -D`，因此不需要相应的 sudoers 权限。

交互式包装器不会设置 `HERMES_MANAGED`。`hermes setup`、`hermes config set`、
`hermes gateway setup` 等命令都可以修改该用户隔离的个性配置。无人值守的
systemd gateway 仍然以 `HERMES_MANAGED=true` 运行。交互式 CLI 可以和负责
后台消息网关的 `hermes-user2.service` 同时运行。

### 注册消息平台

Hermes 的 Weixin 集成通过腾讯 iLink Bot API 工作，并通过交互式扫码取得
account ID 和令牌。使用对应实例的包装器启动平台向导：

```fish
sudo -u user2 /run/current-system/sw/bin/hermes-user2-cli gateway setup
```

选择 **Weixin / WeChat**，扫描并确认二维码，设置私聊策略，然后选择 **Done**。
向导最后会询问是否立即启动以及是否安装 gateway 服务，这两项都回答 `n`。
后台网关只能继续由 Nix 管理的 `hermes-user2.service` 托管。

向导会把凭据写入 Second User 隔离的 `/var/lib/hermes-user2/home/.env`。重启现有服务后
即可使用，但下一次个性化配置部署会恢复 SOPS 中的版本。因此，重建前必须把
更新后的 dotenv 文件重新封装进加密秘密：

```fish
cd ~/.config/home-manager

set sops_out (nix build --no-link --print-out-paths nixpkgs#sops)
set sops_bin "$sops_out/bin/sops"
set jq_out (nix build --no-link --print-out-paths nixpkgs#jq)
set jq_bin "$jq_out/bin/jq"

sudo -v
sudo -u user2 "$jq_bin" --raw-input --slurp '.' \
    /var/lib/hermes-user2/home/.env | \
    sudo env SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt \
    "$sops_bin" set --value-stdin \
    secrets/hermes.yaml '["hermes-user2-env"]'

sudo chown (id -u):(id -g) secrets/hermes.yaml
chmod 0644 secrets/hermes.yaml

sudo env SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt \
    "$sops_bin" --decrypt --extract '["hermes-user2-env"]' \
    secrets/hermes.yaml >/dev/null
and sudo nixos-rebuild switch --flake .#nixos
and sudo systemctl restart hermes-user2.service
```

这条管道通过标准输入把 dotenv 内容编码为 JSON 字符串，不会把微信令牌放入
进程参数，也不会生成额外的明文临时文件。为 User 注册平台身份时，改用
User 的包装器以及 `hermes-user-env`，其余流程相同。其他可写 CLI 命令对
`config.yaml`、`SOUL.md` 或 `USER.md` 所做的改动也遵循同样生命周期：如果需要
在下一次个性化配置部署后继续保留，应在部署前使用第 3 步函数回存对应 SOPS 值。

### 导出全部可写个性配置

如需检查 Second User 当前配置并手工选择要写回的改动，可以把四项托管输入导出到
权限受限的临时目录。以下命令不会导出 sessions、memories、cache、logs 或
workspace 内容：

```fish
set runtime_export (mktemp -d --tmpdir hermes-user2-export.XXXXXXXX)
chmod 0700 "$runtime_export"

sudo -v
sudo install -o (id -u) -g (id -g) -m 0600 \
    /var/lib/hermes-user2/home/.env "$runtime_export/user2.env"
sudo install -o (id -u) -g (id -g) -m 0600 \
    /var/lib/hermes-user2/home/config.yaml "$runtime_export/user2-config.yaml"
sudo install -o (id -u) -g (id -g) -m 0600 \
    /var/lib/hermes-user2/home/SOUL.md "$runtime_export/user2-SOUL.md"
sudo install -o (id -u) -g (id -g) -m 0600 \
    /var/lib/hermes-user2/home/USER.md "$runtime_export/user2-USER.md"

echo "Second User profile exported to $runtime_export"
```

检查或编辑这些本地文件时，不要把内容打印到终端。如果当前 Fish 会话已经没有
第 3 步定义的 `put_hermes_secret` 函数，先重新执行其定义，然后只写回你希望
长期保留的值：

```fish
put_hermes_secret hermes-user2-env "$runtime_export/user2.env"
put_hermes_secret hermes-user2-config "$runtime_export/user2-config.yaml"
put_hermes_secret hermes-user2-soul "$runtime_export/user2-SOUL.md"
put_hermes_secret hermes-user2-user "$runtime_export/user2-USER.md"
```

重建前先执行 SOPS extract 验证。只有全部更新键均可解密且重建后的配置验证通过，
才能删除四个明文文件并移除已经为空的导出目录：

```fish
rm "$runtime_export/user2.env" \
    "$runtime_export/user2-config.yaml" \
    "$runtime_export/user2-SOUL.md" \
    "$runtime_export/user2-USER.md"
rmdir "$runtime_export"
set -e runtime_export
```

导出 User 时，把源路径、目标文件名和 SOPS 键中的 `user2` 全部替换为 `user`。

## 更新秘密配置

使用第 3 步的命令进行编辑，完成验证后再次重建。不要手工编辑 SOPS 密文。
轮换密钥时，在所有秘密都重新加密给新 recipient 且完成重建验证之前，必须保留
旧身份文件。

## 故障排查

- **在 `sudo` 下提示 `sops: command not found`：** 使用 `nix shell` 解析得到的
  `sops_bin` 绝对路径，不要直接使用裸命令 `sops`。
- **Age 解密失败：** 确认 root 所有、权限为 `0600` 的密钥文件存在，并且其
  recipient 与加密文件匹配；绝对不要在日志中暴露私钥。
- **出现 `no such key` 或个性化配置部署失败：** 激活前必须配置所选用户的
  `environmentSecretName` 和 `profile.files` 映射引用的每一个 SOPS 键。不要添加
  虚假密文，也不要修改模块的所有权模式来绕过检查。
- **运行时缺少变量：** 检查 `systemctl status` 和日志，然后重新执行
  decrypt/extract 验证，但不要打印验证输出。
- **`sudo` 拒绝 `--chdir` 或 `-D`：** 使用自动生成的每用户 CLI 包装器。不要
  放宽 sudoers，也不要手工复制托管环境变量。
- **CLI 写入提示安装由系统管理：** 先重建以安装当前包装器，并通过对应的
  每用户包装器调用 Hermes。systemd gateway 仍为托管模式，但交互式包装器可写。
- **Flake 错误：** 先从仓库根目录运行 `nix flake check`。

## 安全与 Git 指引

把 `/var/lib/sops-nix/key.txt` 和服务商令牌视为生产凭据。密钥只能由 root
读取；凭据暴露后必须轮换；绝对不要暂存明文导出、备份或命令输出。加密后的
`secrets/hermes.yaml` 可以纳入版本控制，但必须审查差异，并遵守本仓库的私有
远端和公开导出扫描流程；绝对不能绕过秘密扫描。
