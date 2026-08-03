# WeChat exporter VM bootstrap

The VM and host bridge deliberately contain no account identifiers, WeChat
keys, raw databases, exporter source, private SSH keys, or SOPS data. Second User's
stable database path is:

```text
/var/lib/hermes-user2-wechat/current/snapshot.db
```

Only root replaces the `current` generation. Second User receives group read access
to the complete snapshot and manifest; file modes and the Hermes systemd
sandbox deny writes.

## Apply, build, and import

Apply the host configuration first so `wechat-vmctl`, the pull timer, and the
Second User read-only boundary are installed. Then build and import the appliance:

```bash
sudo nixos-rebuild switch --flake .#nixos
nix build .#wechat-exporter-vm
wechat-vmctl import result/*.ova
wechat-vmctl start
```

After import, `wechat-exporter-vm.service` starts the VM headlessly on later
host boots. The explicit first start keeps the console visible for setup and
the QR login.

The import command verifies or adds two loopback-only NAT forwards: port 22222
for the SFTP-only snapshot account and port 22223 for the VM operator. It never
deletes or rewrites an existing conflicting rule. The sparse appliance is
shipped with a separate 256 GiB ext4 data disk mounted at
`/home/wechat-exporter/.var`, which keeps the WeChat Flatpak account data away
from the 50 GiB system disk.

The VM-only nixpkgs overlay raises the locked LKL image builder's hard-coded
memory from 100 MiB to 512 MiB. This affects OVA construction only; it does not
change the guest's configured 8 GiB runtime memory.

## Establish trust

No SSH public key is baked into the appliance. Generate and display both host
public keys:

```bash
wechat-vmctl operator-key
wechat-vmctl pull-key
```

At the VM console, enroll those exact public keys separately:

```bash
sudo wechat-authorize-operator 'ssh-ed25519 ...'
sudo wechat-authorize-puller 'ssh-ed25519 ...'
```

At the VM console, display the guest host-key fingerprint:

```bash
wechat-show-host-fingerprint
```

After comparing it on-screen, pin that exact fingerprint on the host:

```bash
wechat-vmctl trust-host-key SHA256:...
```

The pull private key remains root-only. The operator private key remains under
the host operator's `~/.local/state/wechat-vm/`. Second User can access neither key.

## Deploy and reach the login boundary

Deploy the exporter's committed `HEAD` once. The command uses `git archive`, so
ignored or untracked local account keys and configuration cannot enter the VM.
The VM initializes its own mutable Git repository so later exporter-side
development does not depend on the host copy.

```bash
wechat-vmctl deploy /home/user/Projects/Hermes/wechat-linux-decrypt-demo
```

In the VM, create `config.local.json` under
`/var/lib/wechat-exporter/source/` using only the second account's local
settings. Do not place keys in that file. Then run:

```bash
wechat-exporterctl test
wechat-install-flatpak
```

Launch WeChat from the Xfce menu. Stop here for the human QR scan and mobile
confirmation. No service in this configuration automates login.

## After human login

Only after login is complete, the VM operator runs:

```bash
wechat-exporterctl acquire-keys
wechat-exporterctl extract
wechat-exporterctl export
wechat-exporterctl start
```

Once its configuration and key files exist, the exporter service starts on
later guest boots. WeChat also starts in the dedicated Xfce session, so the
one-time login is the only expected interactive account step.

The guest exposure timer accepts exactly one completed `published_*.db`, uses
the SQLite backup API, requires the complete exporter schema, runs
`integrity_check`, and atomically switches a SHA-256-addressed generation. The
host repeats manifest, hash, schema, and integrity validation every minute and
retains three generations by default.
