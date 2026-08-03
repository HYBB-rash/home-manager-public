# SOPS-Nix Hermes environment setup

This guide configures the Hermes system service to read its environment from
`secrets/hermes.yaml`. The NixOS module expects an age identity at
`/var/lib/sops-nix/key.txt`, a YAML secret named `hermes-env`, and that file as
the default SOPS file.

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

For a new file, SOPS opens an editor. Enter a top-level `hermes-env` block
scalar containing one `NAME=value` assignment per line:

```yaml
hermes-env: |
  HERMES_API_KEY=replace-with-a-real-token
  HERMES_BASE_URL=https://example.invalid
```

For an existing file, the same command opens it for editing. SOPS rewrites the
file encrypted; do not commit plaintext or editor backups.

## 4. Validate

Decrypt and extract only the expected key, discarding the plaintext output:

```bash
sops_bin=$(nix shell nixpkgs#sops nixpkgs#age --command which sops)
sudo env \
  SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt \
  "$sops_bin" --decrypt --extract 'hermes-env' secrets/hermes.yaml >/dev/null
nix flake check
```

```fish
set sops_bin (nix shell nixpkgs#sops nixpkgs#age --command which sops)
sudo env \
  SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt \
  "$sops_bin" --decrypt --extract 'hermes-env' secrets/hermes.yaml >/dev/null
nix flake check
```

## 5. Apply

```bash
sudo nixos-rebuild switch --flake .#nixos
systemctl is-active hermes-agent.service
sudo journalctl -u hermes-agent.service -n 50 --no-pager
```

## Updating secrets

Edit with the step 3 command, validate, then run the rebuild again. Do not
manually edit SOPS ciphertext. For key rotation, retain the old identity until
all secrets are re-encrypted to the new recipient and a rebuild is verified.

## Troubleshooting

- **`sops: command not found` under `sudo`:** use the absolute `sops_bin` path
  resolved by `nix shell`, not bare `sops`.
- **Age decryption failure:** verify the root-owned `0600` key exists and its
  recipient matches the encrypted file; never expose the private key in logs.
- **`no such key: hermes-env`:** use exactly that top-level YAML key and a block
  scalar containing valid `NAME=value` lines.
- **Missing variables at runtime:** inspect `systemctl status` and the journal,
  then repeat the decrypt/extract validation without printing its output.
- **Flake errors:** run `nix flake check` from the repository root first.

## Security and Git guidance

Treat `/var/lib/sops-nix/key.txt` and provider tokens as production credentials.
Keep the key root-only, rotate tokens after exposure, and never stage plaintext
exports, backups, or command output. The encrypted `secrets/hermes.yaml` may be
versioned, but review diffs and follow this repository's private-remote and
public-export scanning workflow; never bypass its secret checks.
