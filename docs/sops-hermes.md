# SOPS-Nix Hermes profile setup

This repository runs one system Hermes gateway per configured normal user. The
local `services.hermesMultiUser` module uses the upstream Hermes package, but
does not use its singleton NixOS service module. Each gateway has a distinct
`HERMES_HOME`, state directory, private Unix group, and separately permissioned
SOPS deployment.

Encrypted source material lives in `secrets/hermes.yaml`. Nix only receives the
SOPS key names and runtime destinations: no profile content, token, platform
identity, or provider credential is rendered into a derivation or copied to the
Nix store. The NixOS module expects an age identity at
`/var/lib/sops-nix/key.txt`.

Run commands from the repository root. The examples use transient Nix shells,
so `sops` and `age` do not need to be installed permanently.

## 1. Install or generate the age identity

Do not overwrite an existing identity:

```bash
sudo test -f /var/lib/sops-nix/key.txt && echo "age key already exists"
```

On a fresh machine, generate it directly at the configured location with
root-only permissions:

```bash
nix shell nixpkgs#age --command bash -c '
  sudo install -d -m 0700 /var/lib/sops-nix
  sudo "$(command -v age-keygen)" -o /var/lib/sops-nix/key.txt
  sudo chmod 0600 /var/lib/sops-nix/key.txt
'
```

Fish equivalent:

```fish
nix shell nixpkgs#age --command bash -c '
  sudo install -d -m 0700 /var/lib/sops-nix
  sudo "$(command -v age-keygen)" -o /var/lib/sops-nix/key.txt
  sudo chmod 0600 /var/lib/sops-nix/key.txt
'
```

Check permissions without printing the key:

```bash
sudo stat -c '%U:%G %a %n' /var/lib/sops-nix/key.txt
```

## 2. Obtain the recipient

Derive the public age recipient from the private identity. A recipient begins
with `age1` and is safe to share; never share `key.txt`.

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

## 3. Create or edit `secrets/hermes.yaml`

`sudo` often has a restricted `PATH`. Resolve an absolute SOPS path from a
transient shell and use that path with `sudo`.

Bash:

```bash
set -euo pipefail
recipient='age1REPLACE_WITH_THE_RECIPIENT_FROM_STEP_2'
sops_bin=$(nix shell nixpkgs#sops nixpkgs#age --command which sops)
mkdir -p secrets
sudo env \
  SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt \
  "$sops_bin" --config /dev/null --age "$recipient" secrets/hermes.yaml
```

Fish:

```fish
set -l recipient 'age1REPLACE_WITH_THE_RECIPIENT_FROM_STEP_2'
set -l sops_bin (nix shell nixpkgs#sops nixpkgs#age --command which sops)
mkdir -p secrets
sudo env \
  SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt \
  "$sops_bin" --config /dev/null --age "$recipient" secrets/hermes.yaml
```

For a new file, SOPS opens an editor. Add the secret keys named by
`system/services.nix`. Each enabled instance requires its own dotenv key and
one encrypted key per stable profile file. The provider account may be shared,
but copy its key value into each user's separate dotenv deployment. Platform
tokens, OAuth material, and all user-specific values belong only in that
user's encrypted keys.

The initial two-instance mapping is:

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

The two dotenv values may contain the same `DEEPSEEK_API_KEY`. Every messaging
credential, including Telegram, Discord, Slack, and any other platform token or
OAuth material, must identify that user only. Do not reuse a bot or app token
between the two instances.

When the eight values already exist as separate plaintext files in a protected
runtime directory such as `$draft`, encode each entire file as one JSON string
before passing it to `sops set`. SOPS 3.13 requires the value read by `set` to
be valid JSON. `--value-file` does not JSON-encode dotenv, YAML, or Markdown
text, so using it directly fails with `Value for --set is not valid JSON`.

Authenticate `sudo` before constructing the pipeline. Keep the encoded value on
standard input: do not put it in a command argument or write an intermediate
JSON file. Bash:

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

Fish:

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

To add stable skills, plugins, tool settings, or platform configuration, add
one encrypted SOPS key for every file and map it in the corresponding
`profile.files` attribute. The attribute key is a safe path relative to
`HERMES_HOME`; only `config.yaml`, `SOUL.md`, and `USER.md` are mapped by the
initial setup. Files under `cache`, `cron`, `logs`, `memories`, `runtime`, and
`sessions`, as well as `.env`, are reserved for mutable runtime state and
cannot be declared as profile files.

For an existing file, the same command opens it for editing. SOPS rewrites the
file encrypted; do not commit plaintext, editor backups, or a decrypted profile
export.

## 4. Validate

Validate all eight configured keys without printing plaintext. A successful
write of only some values is not sufficient.

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

Only after all eight values pass validation may you delete the plaintext
`$draft` directory, remove the temporary `sops.validateSopsFiles = false` line
and its explanatory comment from `system/services.nix`, and proceed. If any key
fails, stop: keep strict validation disabled only while correcting the encrypted
file, and do not rebuild the system.

After removing the temporary setting, run:

```bash
nix flake check --no-write-lock-file
sudo nixos-rebuild dry-activate --flake .#nixos
```

## 5. Apply

```bash
sudo nixos-rebuild switch --flake .#nixos
systemctl is-active hermes-user.service
systemctl is-active hermes-user2.service
sudo journalctl -u hermes-user.service -u hermes-user2.service -n 50 --no-pager
```

Each `hermes-<instance>.service` starts under `multi-user.target`; neither
login nor user lingering is required. The profile deployment units run first as
root, install stable profile files as `root:hermes-<instance>`, and install the
dotenv file as the actual user with mode `0600`. The gateway is only wuser2ble
to its own `HERMES_HOME` and workspace; stable profile targets remain
root-owned and are restored on every profile deployment. Sessions, runtime
memories, cache, and logs are intentionally not Git-backed.

Platforms that bind local listeners must use a different port in each user's
encrypted configuration. In particular, the Hermes defaults for `api_server`,
WhatsApp Cloud webhooks, and BlueBubbles webhooks cannot be enabled unchanged
in both instances at the same time. Telegram polling, Discord gateways, and
Slack socket mode do not share those listener ports, but still require distinct
per-user bot or app identities.

## Updating secrets

Edit with the step 3 command, validate, then run the rebuild again. Do not
manually edit SOPS ciphertext. For key rotation, retain the old identity until
all secrets are re-encrypted to the new recipient and a rebuild is verified.

## Troubleshooting

- **`sops: command not found` under `sudo`:** use the absolute `sops_bin` path
  resolved by `nix shell`, not bare `sops`.
- **Age decryption failure:** verify the root-owned `0600` key exists and its
  recipient matches the encrypted file; never expose the private key in logs.
- **`no such key` or a failed profile deployment:** provision every SOPS key
  referenced by the selected user's `environmentSecretName` and
  `profile.files` mapping before activation. Do not add dummy ciphertext or
  replace the module's ownership modes to bypass this check.
- **Missing variables at runtime:** inspect `systemctl status` and the journal,
  then repeat the decrypt/extract validation without printing its output.
- **Flake errors:** run `nix flake check` from the repository root first.

## Security and Git guidance

Treat `/var/lib/sops-nix/key.txt` and provider tokens as production credentials.
Keep the key root-only, rotate tokens after exposure, and never stage plaintext
exports, backups, or command output. The encrypted `secrets/hermes.yaml` may be
versioned, but review diffs and follow this repository's private-remote and
public-export scanning workflow; never bypass its secret checks.
