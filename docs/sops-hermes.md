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
  HERMES_API_KEY=REPLACE_WITH_PROVIDER_TOKEN
hermes-user-config: |
  # Hermes YAML configuration for this user only
hermes-user-soul: |
  # Persona for this user only
hermes-user-user: |
  # User context for this user only
hermes-user2-env: |
  HERMES_API_KEY=REPLACE_WITH_PROVIDER_TOKEN
hermes-user2-config: |
  # Hermes YAML configuration for this user only
hermes-user2-soul: |
  # Persona for this user only
hermes-user2-user: |
  # User context for this user only
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

Validate every configured key without printing plaintext:

```bash
sops_bin=$(nix shell nixpkgs#sops nixpkgs#age --command which sops)
sudo env \
  SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt \
  "$sops_bin" --decrypt --extract 'hermes-user-env' secrets/hermes.yaml >/dev/null
sudo env \
  SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt \
  "$sops_bin" --decrypt --extract 'hermes-user2-env' secrets/hermes.yaml >/dev/null
nix flake check
```

```fish
set sops_bin (nix shell nixpkgs#sops nixpkgs#age --command which sops)
sudo env \
  SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt \
  "$sops_bin" --decrypt --extract 'hermes-user-env' secrets/hermes.yaml >/dev/null
sudo env \
  SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt \
  "$sops_bin" --decrypt --extract 'hermes-user2-env' secrets/hermes.yaml >/dev/null
nix flake check
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
