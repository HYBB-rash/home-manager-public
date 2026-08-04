{
  lib,
  pkgs,
  ...
}:

let
  pythonEnv = pkgs.python3.withPackages (pythonPackages: [
    pythonPackages.pycryptodome
  ]);

  snapshotTool = pkgs.writeShellApplication {
    name = "wechat-snapshot";
    runtimeInputs = [ pkgs.python3 ];
    text = ''
      exec ${pkgs.python3}/bin/python3 ${../system/wechat-snapshot.py} "$@"
    '';
  };

  installWechat = pkgs.writeShellApplication {
    name = "wechat-install-flatpak";
    runtimeInputs = [ pkgs.flatpak ];
    text = ''
      set -euo pipefail
      flatpak remote-add --user --if-not-exists flathub \
        https://dl.flathub.org/repo/flathub.flatpakrepo
      flatpak install --user flathub com.tencent.WeChat
    '';
  };

  exporterCtl = pkgs.writeShellApplication {
    name = "wechat-exporterctl";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.git
      pythonEnv
      pkgs.systemd
    ];
    text = ''
      set -euo pipefail
      release_dir=/var/lib/wechat-exporter/current
      state_dir=/var/lib/wechat-exporter/state
      export WX_EXPORT_STATE_DIR="$state_dir"
      export WX_EXPORT_OUTPUT_DIR="$state_dir/published"
      export WX_EXPORT_MANAGED_DEPLOYMENT=1
      case "''${1:-}" in
        test)
          cd "$release_dir"
          exec ${pythonEnv}/bin/python3 -m unittest discover -s tests
          ;;
        acquire-keys)
          cd "$release_dir"
          exec ${pythonEnv}/bin/python3 key_scan.py --write-keys
          ;;
        extract)
          cd "$release_dir"
          exec ${pythonEnv}/bin/python3 extract.py
          ;;
        export)
          cd "$release_dir"
          exec ${pythonEnv}/bin/python3 export_all.py
          ;;
        start|restart|stop|status)
          exec sudo systemctl "$1" wechat-exporter-sync.service
          ;;
        *)
          echo "usage: wechat-exporterctl {test|acquire-keys|extract|export|start|restart|stop|status}" >&2
          exit 2
          ;;
      esac
    '';
  };

  authorizePuller = pkgs.writeShellScriptBin "wechat-authorize-puller" ''
    set -euo pipefail
    [ "$#" -eq 1 ] || { echo "usage: wechat-authorize-puller 'ssh-ed25519 ...'" >&2; exit 2; }
    key=$1
    case "$key" in
      ssh-ed25519\ *) ;;
      *) echo "only an ssh-ed25519 REPLACE_WITH_YOUR_PUBLIC_KEY" >&2; exit 1 ;;
    esac
    ${pkgs.coreutils}/bin/install -d -o root -g root -m 0755 /var/lib/wechat-exporter/ssh
    ${pkgs.coreutils}/bin/printf '%s\n' "$key" > /var/lib/wechat-exporter/ssh/wechat-pull
    ${pkgs.coreutils}/bin/chown root:root /var/lib/wechat-exporter/ssh/wechat-pull
    ${pkgs.coreutils}/bin/chmod 0600 /var/lib/wechat-exporter/ssh/wechat-pull
  '';

  authorizeOperator = pkgs.writeShellScriptBin "wechat-authorize-operator" ''
    set -euo pipefail
    [ "$#" -eq 1 ] || { echo "usage: wechat-authorize-operator 'ssh-ed25519 ...'" >&2; exit 2; }
    key=$1
    case "$key" in
      ssh-ed25519\ *) ;;
      *) echo "only an ssh-ed25519 REPLACE_WITH_YOUR_PUBLIC_KEY" >&2; exit 1 ;;
    esac
    ${pkgs.coreutils}/bin/install -d -o root -g root -m 0755 /var/lib/wechat-exporter/ssh
    ${pkgs.coreutils}/bin/printf '%s\n' "$key" > /var/lib/wechat-exporter/ssh/wechat-exporter
    ${pkgs.coreutils}/bin/chown root:root /var/lib/wechat-exporter/ssh/wechat-exporter
    ${pkgs.coreutils}/bin/chmod 0600 /var/lib/wechat-exporter/ssh/wechat-exporter
  '';

  showHostFingerprint = pkgs.writeShellApplication {
    name = "wechat-show-host-fingerprint";
    runtimeInputs = [ pkgs.openssh ];
    text = ''
      exec ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub -E sha256
    '';
  };
in
{
  # The locked LKL cptofs binary hard-codes a 100 MiB kernel, which cannot
  # copy this graphical NixOS closure. Patch only its equal-length boot
  # argument while preserving the locked binary and library versions.
  nixpkgs.overlays = [
    (
      _final: prev:
      let
        patchedOut = prev.runCommand "lkl-cptofs-512m" { nativeBuildInputs = [ prev.perl ]; } ''
          cp -a ${prev.lkl.out}/. "$out"
          chmod u+w "$out/bin" "$out/bin/cptofs"
          perl -0pi -e 's/mem=100M/mem=512M/g' "$out/bin/cptofs"
          ! grep -aFq 'mem=100M' "$out/bin/cptofs"
          grep -aFq 'mem=512M' "$out/bin/cptofs"
        '';
      in
      {
        lkl = patchedOut // {
          inherit (prev.lkl) dev lib;
        };
      }
    )
  ];

  networking = {
    hostName = "wechat-exporter";
    networkmanager.enable = true;
    firewall.allowedTCPPorts = [ 22 ];
    # NIC2 has no carrier by default. This lets the host hot-switch it to the
    # temporary phone-sync LAN bridge without exposing a live LAN path.
    firewall.trustedInterfaces = [ "enp0s8" ];
  };

  time.timeZone = "Asia/Shanghai";
  i18n.defaultLocale = "zh_CN.UTF-8";

  virtualbox = {
    vmName = "wechat-exporter";
    memorySize = 8192;
    extraDisk = {
      size = 256 * 1024;
      label = "wechat-data";
      mountPoint = "/home/wechat-exporter/.var";
    };
    params = {
      cpus = 4;
      vram = 128;
      clipboard = "disabled";
      draganddrop = "disabled";
      # Preserve NAT and its loopback forwards on NIC1. NIC2 uses a disconnected
      # NAT attachment so VirtualBox can hot-switch it to the LAN bridge.
      nic2 = "nat";
      macaddress2 = "080027A11CE2";
      cableconnected2 = "off";
      natpf1 = [
        "wechat-pull,tcp,127.0.0.1,22222,,22"
        "wechat-operator,tcp,127.0.0.1,22223,,22"
      ];
    };
  };

  virtualisation.virtualbox.guest = {
    enable = true;
    clipboard = false;
    dragAndDrop = false;
  };

  services = {
    xserver.enable = true;
    xserver.desktopManager.xfce.enable = true;
    xserver.displayManager.lightdm.enable = true;
    displayManager.autoLogin = {
      enable = true;
      user = "wechat-exporter";
    };
    flatpak.enable = true;

    openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        PermitRootLogin = "no";
        AllowUsers = [
          "wechat-exporter"
          "wechat-pull"
        ];
        AuthorizedKeysFile = ".ssh/authorized_keys /var/lib/wechat-exporter/ssh/%u";
      };
      extraConfig = ''
        Match User wechat-pull
          ChrootDirectory /srv/wechat-snapshot
          ForceCommand internal-sftp -R -d /
          AllowTcpForwarding no
          PermitTunnel no
          X11Forwarding no
      '';
    };
  };

  users.groups.wechat-pull = { };
  users.users = {
    wechat-exporter = {
      isNormalUser = true;
      description = "Dedicated WeChat exporter operator";
      extraGroups = [ "networkmanager" ];
      initialHashedPassword = "";
    };
    wechat-pull = {
      isSystemUser = true;
      group = "wechat-pull";
      home = "/var/empty";
    };
  };

  boot.kernel.sysctl."kernel.yama.ptrace_scope" = 0;

  environment.systemPackages = [
    authorizePuller
    authorizeOperator
    exporterCtl
    installWechat
    pkgs.ffmpeg
    pkgs.git
    pkgs.gnumake
    pythonEnv
    pkgs.zstd
    showHostFingerprint
    snapshotTool
  ];

  # Start WeChat in the dedicated Xfce session after the operator installs the
  # Flatpak and completes the one-time account login.
  environment.etc."xdg/autostart/wechat-exporter.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=WeChat
    Exec=${pkgs.flatpak}/bin/flatpak run com.tencent.WeChat
    OnlyShowIn=XFCE;
    X-GNOME-Autostart-enabled=true
  '';

  systemd.tmpfiles.rules = [
    "d /home/wechat-exporter/.var 0700 wechat-exporter users -"
    "d /var/lib/wechat-exporter 0700 wechat-exporter users -"
    "d /var/lib/wechat-exporter/releases 0700 wechat-exporter users -"
    "d /var/lib/wechat-exporter/state 0700 wechat-exporter users -"
    "d /var/lib/wechat-exporter/state/published 0700 wechat-exporter users -"
    "d /srv/wechat-snapshot 0750 root wechat-pull -"
    "d /srv/wechat-snapshot/generations 0750 root wechat-pull -"
  ];

  systemd.services.wechat-exporter-sync = {
    description = "Version-gated local WeChat SQLite exporter";
    after = [ "graphical.target" ];
    wantedBy = [ "graphical.target" ];
    serviceConfig = {
      Type = "simple";
      User = "wechat-exporter";
      Group = "users";
      WorkingDirectory = "/var/lib/wechat-exporter/current";
      Environment = [
        "WX_EXPORT_STATE_DIR=/var/lib/wechat-exporter/state"
        "WX_EXPORT_OUTPUT_DIR=/var/lib/wechat-exporter/state/published"
        "WX_EXPORT_MANAGED_DEPLOYMENT=1"
        "WX_EXPORT_SYNC_INTERVAL=60"
        "PYTHONUNBUFFERED=1"
      ];
      ExecCondition = pkgs.writeShellScript "wechat-exporter-ready" ''
        test -f /var/lib/wechat-exporter/current/sync.py
        test -f /var/lib/wechat-exporter/state/config.local.json
        test -f /var/lib/wechat-exporter/state/keys.json
      '';
      ExecStart = "${pythonEnv}/bin/python3 /var/lib/wechat-exporter/current/sync.py";
      Restart = "on-failure";
      RestartSec = "30s";
      UMask = "0077";
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ReadWritePaths = [
        "/var/lib/wechat-exporter"
        "/home/wechat-exporter/.var/app/com.tencent.WeChat"
      ];
    };
    path = [
      pkgs.ffmpeg
      pkgs.git
      pythonEnv
      pkgs.zstd
    ];
  };

  systemd.services.wechat-snapshot-expose = {
    description = "Integrity-check and expose a complete exporter snapshot";
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      Group = "wechat-pull";
      UMask = "0077";
      ExecStart = lib.escapeShellArgs [
        "${snapshotTool}/bin/wechat-snapshot"
        "publish"
        "--source-glob"
        "/var/lib/wechat-exporter/state/published/published_*.db"
        "--destination"
        "/srv/wechat-snapshot"
        "--owner"
        "root"
        "--group"
        "wechat-pull"
        "--retain"
        "3"
      ];
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      ReadOnlyPaths = [ "/var/lib/wechat-exporter/state/published" ];
      ReadWritePaths = [ "/srv/wechat-snapshot" ];
    };
  };

  systemd.timers.wechat-snapshot-expose = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5min";
      OnUnitActiveSec = "1min";
      Persistent = true;
      Unit = "wechat-snapshot-expose.service";
    };
  };

  security.sudo.extraRules = [
    {
      users = [ "wechat-exporter" ];
      commands = [
        {
          command = "${authorizeOperator}/bin/wechat-authorize-operator";
          options = [ "NOPASSWD" ];
        }
        {
          command = "${authorizePuller}/bin/wechat-authorize-puller";
          options = [ "NOPASSWD" ];
        }
        {
          command = "/run/current-system/sw/bin/systemctl start wechat-exporter-sync.service";
          options = [ "NOPASSWD" ];
        }
        {
          command = "/run/current-system/sw/bin/systemctl restart wechat-exporter-sync.service";
          options = [ "NOPASSWD" ];
        }
        {
          command = "/run/current-system/sw/bin/systemctl stop wechat-exporter-sync.service";
          options = [ "NOPASSWD" ];
        }
        {
          command = "/run/current-system/sw/bin/systemctl status wechat-exporter-sync.service";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];

  system.stateVersion = "26.05";
}
