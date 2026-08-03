{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.wechatSnapshotBridge;
  stateDirectory = "wechat-snapshot-publisher";
  statePath = "/var/lib/${stateDirectory}";
  operatorHome = "/home/user";
  operatorState = "${operatorHome}/.local/state/wechat-vm";
  virtualBoxHome = "${operatorHome}/.config/VirtualBox";
  vmDirectory = "${operatorHome}/VirtualBox VMs/${cfg.vmName}";
  rdpUser = "wechat-console";
  vboxManage = "/run/current-system/sw/bin/VBoxManage";

  snapshotTool = pkgs.writeShellApplication {
    name = "wechat-snapshot";
    runtimeInputs = [
      pkgs.openssh
      pkgs.python3
    ];
    text = ''
      exec ${pkgs.python3}/bin/python3 ${./wechat-snapshot.py} "$@"
    '';
  };

  keygen = pkgs.writeShellScript "wechat-snapshot-keygen" ''
    set -euo pipefail
    key=${lib.escapeShellArg "${statePath}/id_ed25519"}
    if [ ! -f "$key" ]; then
      ${pkgs.openssh}/bin/ssh-keygen -q -t ed25519 -N "" -C wechat-snapshot-puller -f "$key"
    fi
    ${pkgs.coreutils}/bin/chown root:vboxusers "$key" "$key.pub"
    ${pkgs.coreutils}/bin/chmod 0600 "$key"
    ${pkgs.coreutils}/bin/chmod 0640 "$key.pub"
  '';

  trustHostKey = pkgs.writeShellScriptBin "wechat-snapshot-trust-host-key" ''
    set -euo pipefail
    if [ "$#" -ne 1 ]; then
      echo "usage: wechat-snapshot-trust-host-key SHA256:fingerprint" >&2
      exit 2
    fi
    expected=$1
    stage="$(${pkgs.coreutils}/bin/mktemp ${statePath}/known-hosts.XXXXXX)"
    trap '${pkgs.coreutils}/bin/rm -f -- "$stage"' EXIT
    scanned="$(${pkgs.coreutils}/bin/mktemp ${statePath}/scanned-key.XXXXXX)"
    trap '${pkgs.coreutils}/bin/rm -f -- "$stage" "$scanned"' EXIT
    ${pkgs.coreutils}/bin/cat >"$scanned"
    [ "$(${pkgs.coreutils}/bin/wc -l <"$scanned")" -eq 1 ] || {
      echo "expected exactly one scanned SSH host key" >&2
      exit 1
    }
    ${pkgs.gawk}/bin/awk 'NF >= 3 { print "wechat-exporter-vm", $2, $3 }' "$scanned" >"$stage"
    actual="$(${pkgs.openssh}/bin/ssh-keygen -lf "$stage" -E sha256 | ${pkgs.gawk}/bin/awk '{print $2}')"
    [ "$actual" = "$expected" ] || {
      echo "SSH host fingerprint mismatch: expected $expected, observed $actual" >&2
      exit 1
    }
    ${pkgs.coreutils}/bin/install -o root -g vboxusers -m 0640 \
      "$stage" ${statePath}/known_hosts
  '';

  configureVm = pkgs.writeShellApplication {
    name = "wechat-vm-configure";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gawk
      pkgs.gnugrep
      pkgs.openssl
    ];
    text = ''
      set -euo pipefail
      export HOME=${lib.escapeShellArg operatorHome}
      export VBOX_USER_HOME=${lib.escapeShellArg virtualBoxHome}
      vm=${lib.escapeShellArg cfg.vmName}
      password_file=${lib.escapeShellArg "${operatorState}/rdp-password"}
      install -d -m 0700 ${lib.escapeShellArg operatorState}
      if [ ! -f "$password_file" ]; then
        stage="$(mktemp ${lib.escapeShellArg "${operatorState}/rdp-password.XXXXXX"})"
        trap 'rm -f -- "$stage"' EXIT
        openssl rand -base64 32 >"$stage"
        chmod 0600 "$stage"
        mv "$stage" "$password_file"
        trap - EXIT
      fi
      chmod 0600 "$password_file"

      ensure_nat_rule() {
        name=$1
        rule=$2
        info="$(${vboxManage} showvminfo "$vm" --machinereadable)"
        if printf '%s\n' "$info" | grep -Fq "$rule"; then
          return
        fi
        if printf '%s\n' "$info" | grep -Fq "$name,tcp,"; then
          echo "VirtualBox NAT rule $name exists with unexpected settings" >&2
          exit 1
        fi
        ${vboxManage} modifyvm "$vm" --natpf1 "$rule"
      }

      ensure_nat_rule wechat-pull 'wechat-pull,tcp,127.0.0.1,${toString cfg.remotePort},,22'
      ensure_nat_rule wechat-operator 'wechat-operator,tcp,127.0.0.1,22223,,22'

      password="$(cat "$password_file")"
      password_hash="$(${vboxManage} internalcommands passwordhash "$password" | awk '/^Password hash:/ { print $3 }')"
      [ -n "$password_hash" ] || {
        echo "VirtualBox did not return an RDP password hash" >&2
        exit 1
      }
      ${vboxManage} modifyvm "$vm" \
        --vrde=on \
        --vrde-extpack=default \
        --vrde-port=${toString cfg.rdpPort} \
        --vrde-address=127.0.0.1 \
        --vrde-auth-type=external \
        --vrde-auth-library=VBoxAuthSimple \
        --vrde-multi-con=off \
        --vrde-reuse-con=on
      ${vboxManage} setextradata "$vm" \
        ${lib.escapeShellArg "VBoxAuthSimple/users/${rdpUser}"} "$password_hash"
    '';
  };

  controlVmService = pkgs.writeShellScriptBin "wechat-vm-service-control" ''
    set -euo pipefail
    [ "$#" -eq 1 ] || { echo "usage: wechat-vm-service-control {start|stop|restart}" >&2; exit 2; }
    case "$1" in
      start|stop|restart)
        exec ${pkgs.systemd}/bin/systemctl "$1" wechat-exporter-vm.service
        ;;
      *)
        echo "unsupported VM service action: $1" >&2
        exit 2
        ;;
    esac
  '';

  repairVmOwnership = pkgs.writeShellScript "wechat-vm-repair-ownership" ''
    set -euo pipefail
    for directory in \
      ${lib.escapeShellArg virtualBoxHome} \
      ${lib.escapeShellArg vmDirectory}; do
      if [ -d "$directory" ]; then
        ${pkgs.coreutils}/bin/chown -hR user:vboxusers "$directory"
        ${pkgs.findutils}/bin/find "$directory" -type d \
          -exec ${pkgs.coreutils}/bin/chmod 0700 '{}' +
        ${pkgs.findutils}/bin/find "$directory" -type f \
          -exec ${pkgs.coreutils}/bin/chmod 0600 '{}' +
      fi
    done
  '';

  stopVm = pkgs.writeShellApplication {
    name = "wechat-vm-stop";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnused
    ];
    text = ''
      set -euo pipefail
      export HOME=${lib.escapeShellArg operatorHome}
      export VBOX_USER_HOME=${lib.escapeShellArg virtualBoxHome}
      vm=${lib.escapeShellArg cfg.vmName}
      wait_for_poweroff() {
        for _ in $(seq 1 30); do
          state="$(${vboxManage} showvminfo "$vm" --machinereadable | sed -n 's/^VMState="\(.*\)"/\1/p')"
          [ "$state" = poweroff ] && return 0
          sleep 1
        done
        return 1
      }
      state="$(${vboxManage} showvminfo "$vm" --machinereadable | sed -n 's/^VMState="\(.*\)"/\1/p')"
      case "$state" in
        poweroff|saved|aborted)
          exit 0
          ;;
        running)
          ${vboxManage} controlvm "$vm" shutdown || true
          wait_for_poweroff && exit 0
          ${vboxManage} controlvm "$vm" acpipowerbutton || true
          wait_for_poweroff && exit 0
          ${vboxManage} controlvm "$vm" savestate
          ;;
        paused)
          ${vboxManage} controlvm "$vm" savestate
          ;;
        *)
          echo "cannot gracefully stop VM from state: $state" >&2
          exit 1
          ;;
      esac
    '';
  };

  vmctl = pkgs.writeShellApplication {
    name = "wechat-vmctl";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.freerdp
      pkgs.git
      pkgs.gnugrep
      pkgs.openssh
    ];
    text = ''
      set -euo pipefail
      export HOME=${lib.escapeShellArg operatorHome}
      export VBOX_USER_HOME=${lib.escapeShellArg virtualBoxHome}
      vm=${lib.escapeShellArg cfg.vmName}
      operator_state=${lib.escapeShellArg operatorState}
      operator_key="$operator_state/operator_ed25519"
      start_service() {
        /run/wrappers/bin/sudo ${controlVmService}/bin/wechat-vm-service-control start
      }
      rdp_args() {
        password="$(cat "$operator_state/rdp-password")"
        printf '%s\n' \
          '/v:127.0.0.1:${toString cfg.rdpPort}' \
          '/u:${rdpUser}' \
          "/p:$password" \
          '/sec:tls' \
          '/cert:ignore' \
          '+dynamic-resolution' \
          '/network:auto' \
          '-clipboard' \
          '/audio-mode:1'
      }
      case "''${1:-}" in
        import)
          [ "$#" -eq 2 ] || { echo "usage: wechat-vmctl import OVA" >&2; exit 2; }
          [ -f "$2" ] || { echo "OVA does not exist: $2" >&2; exit 1; }
          if ${vboxManage} showvminfo "$vm" >/dev/null 2>&1; then
            echo "VirtualBox VM is already registered: $vm" >&2
            exit 1
          fi
          ${vboxManage} import "$2" --vsys 0 --vmname "$vm"
          ${configureVm}/bin/wechat-vm-configure
          ;;
        configure-network)
          /run/wrappers/bin/sudo ${controlVmService}/bin/wechat-vm-service-control stop
          ${configureVm}/bin/wechat-vm-configure
          start_service
          ;;
        start|start-headless)
          start_service
          ;;
        stop)
          /run/wrappers/bin/sudo ${controlVmService}/bin/wechat-vm-service-control stop
          ;;
        status)
          ${vboxManage} showvminfo "$vm"
          ;;
        console)
          start_service
          [ -r "$operator_state/rdp-password" ] || {
            echo "RDP password is not initialized" >&2
            exit 1
          }
          rdp_args | xfreerdp /args-from:stdin
          ;;
        console-check)
          start_service
          [ -r "$operator_state/rdp-password" ] || {
            echo "RDP password is not initialized" >&2
            exit 1
          }
          { rdp_args; printf '%s\n' '+auth-only'; } | xfreerdp /args-from:stdin
          ;;
        pull-key)
          cat ${statePath}/id_ed25519.pub
          ;;
        operator-key)
          install -d -m 0700 "$operator_state"
          if [ ! -f "$operator_key" ]; then
            ssh-keygen -q -t ed25519 -N "" -C wechat-vm-operator -f "$operator_key"
          fi
          chmod 0600 "$operator_key"
          chmod 0644 "$operator_key.pub"
          cat "$operator_key.pub"
          ;;
        deploy)
          [ "$#" -eq 2 ] || { echo "usage: wechat-vmctl deploy EXPORTER_SOURCE" >&2; exit 2; }
          source_dir="$(${pkgs.coreutils}/bin/realpath "$2")"
          [ -d "$source_dir" ] || { echo "exporter source is not a directory: $source_dir" >&2; exit 1; }
          git -C "$source_dir" rev-parse --verify HEAD >/dev/null
          git -C "$source_dir" archive --format=tar HEAD | \
            ssh -p 22223 -o BatchMode=yes -o StrictHostKeyChecking=yes \
              -i "$operator_key" -o IdentitiesOnly=yes \
              -o HostKeyAlias=wechat-exporter-vm \
              -o UserKnownHostsFile=${statePath}/known_hosts \
              wechat-exporter@${lib.escapeShellArg cfg.remoteHost} \
              'set -e; test ! -e /var/lib/wechat-exporter/source; stage=$(mktemp -d /var/lib/wechat-exporter/source.XXXXXX); tar -xf - -C "$stage"; git -C "$stage" init -q; git -C "$stage" config user.name "VM exporter baseline"; git -C "$stage" config user.email "vm-exporter@localhost"; git -C "$stage" add .; git -C "$stage" commit -qm "Import reproducible exporter baseline"; mv "$stage" /var/lib/wechat-exporter/source'
          ;;
        trust-host-key)
          [ "$#" -eq 2 ] || { echo "usage: wechat-vmctl trust-host-key SHA256:fingerprint" >&2; exit 2; }
          ssh-keyscan -t ed25519 -p ${toString cfg.remotePort} ${lib.escapeShellArg cfg.remoteHost} \
            | /run/wrappers/bin/sudo ${trustHostKey}/bin/wechat-snapshot-trust-host-key "$2"
          ;;
        *)
          echo "usage: wechat-vmctl {import OVA|configure-network|start|stop|status|console|console-check|pull-key|operator-key|trust-host-key FINGERPRINT|deploy EXPORTER_SOURCE}" >&2
          exit 2
          ;;
      esac
    '';
  };
in
{
  options.services.wechatSnapshotBridge = {
    enable = lib.mkEnableOption "validated WeChat VM snapshot publication for Second User";

    destination = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/hermes-user2-wechat";
      description = "Root-owned generation store exposed read-only to Second User.";
    };

    readerUser = lib.mkOption {
      type = lib.types.str;
      default = "user2";
    };

    readerGroup = lib.mkOption {
      type = lib.types.str;
      default = "hermes-user2";
    };

    remoteHost = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
    };

    remotePort = lib.mkOption {
      type = lib.types.port;
      default = 22222;
    };

    rdpPort = lib.mkOption {
      type = lib.types.port;
      default = 33890;
      description = "Loopback-only VirtualBox VRDE console port.";
    };

    remoteUser = lib.mkOption {
      type = lib.types.str;
      default = "wechat-pull";
    };

    interval = lib.mkOption {
      type = lib.types.str;
      default = "1min";
    };

    retention = lib.mkOption {
      type = lib.types.ints.positive;
      default = 3;
      description = "Number of complete host generations retained after an atomic switch.";
    };

    enableTimer = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Periodically pull when the VM and trust bootstrap are ready.";
    };

    vmName = lib.mkOption {
      type = lib.types.str;
      default = "wechat-exporter";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = builtins.hasAttr cfg.readerUser config.users.users;
        message = "wechatSnapshotBridge.readerUser must be an existing user.";
      }
      {
        assertion = builtins.hasAttr cfg.readerGroup config.users.groups;
        message = "wechatSnapshotBridge.readerGroup must be an existing group.";
      }
      {
        assertion = builtins.elem cfg.readerGroup config.users.users.${cfg.readerUser}.extraGroups;
        message = "wechatSnapshotBridge.readerUser must belong to readerGroup.";
      }
    ];

    environment.systemPackages = [
      snapshotTool
      trustHostKey
      vmctl
    ];

    systemd.tmpfiles.rules = [
      "d ${cfg.destination} 0750 root ${cfg.readerGroup} -"
      "d ${cfg.destination}/generations 0750 root ${cfg.readerGroup} -"
    ];

    systemd.services.wechat-snapshot-keygen = {
      description = "Create the host-only WeChat snapshot pull identity";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        Group = "vboxusers";
        StateDirectory = stateDirectory;
        StateDirectoryMode = "0750";
        UMask = "0077";
        ExecStart = keygen;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ statePath ];
      };
    };

    systemd.services.wechat-snapshot-pull = {
      description = "Validate and publish the complete WeChat snapshot for Second User";
      requires = [ "wechat-snapshot-keygen.service" ];
      after = [
        "network-online.target"
        "wechat-snapshot-keygen.service"
      ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        # Keep the shared StateDirectory ownership stable across key generation
        # and pulls. The publisher applies readerGroup only to validated output.
        Group = "vboxusers";
        StateDirectory = stateDirectory;
        StateDirectoryMode = "0750";
        UMask = "0077";
        ExecStart = lib.escapeShellArgs [
          "${snapshotTool}/bin/wechat-snapshot"
          "pull"
          "--host"
          cfg.remoteHost
          "--port"
          (toString cfg.remotePort)
          "--user"
          cfg.remoteUser
          "--identity"
          "${statePath}/id_ed25519"
          "--known-hosts"
          "${statePath}/known_hosts"
          "--incoming"
          statePath
          "--destination"
          cfg.destination
          "--owner"
          "root"
          "--group"
          cfg.readerGroup
          "--retain"
          (toString cfg.retention)
        ];
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ReadWritePaths = [
          statePath
          cfg.destination
        ];
      };
    };

    systemd.timers.wechat-snapshot-pull = lib.mkIf cfg.enableTimer {
      description = "Periodically publish a complete WeChat snapshot for Second User";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "10min";
        OnUnitActiveSec = cfg.interval;
        RandomizedDelaySec = "5s";
        Persistent = true;
        Unit = "wechat-snapshot-pull.service";
      };
    };

    systemd.services.wechat-exporter-vm-ownership = {
      description = "Keep the WeChat VM registry owned by its operator";
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        Group = "root";
        ExecStart = repairVmOwnership;
      };
    };

    systemd.services.wechat-exporter-vm = {
      description = "Persistent VirtualBox WeChat exporter VM";
      wantedBy = [ "multi-user.target" ];
      requires = [ "wechat-exporter-vm-ownership.service" ];
      after = [ "wechat-exporter-vm-ownership.service" ];
      serviceConfig = {
        Type = "simple";
        User = "user";
        Group = "vboxusers";
        Environment = [
          "HOME=${operatorHome}"
          "VBOX_USER_HOME=${virtualBoxHome}"
        ];
        # The NixOS wrapper briefly elevates VBoxHeadless for hardened driver
        # setup, then the persistent VM process runs as the operator.
        DevicePolicy = "closed";
        DeviceAllow = [
          "/dev/vboxdrv rw"
          "/dev/vboxdrvu rw"
        ];
        ExecCondition = "${vboxManage} showvminfo ${cfg.vmName}";
        ExecStartPre = "${configureVm}/bin/wechat-vm-configure";
        ExecStart = "/run/wrappers/bin/VBoxHeadless --startvm ${cfg.vmName} --vrde config";
        ExecStop = "${stopVm}/bin/wechat-vm-stop";
        Restart = "always";
        RestartSec = "10s";
        TimeoutStopSec = "2min";
      };
    };

    systemd.services.hermes-user2.serviceConfig.ReadOnlyPaths = [ cfg.destination ];

    security.sudo.extraRules = [
      {
        users = [ "user" ];
        commands = [
          {
            command = "${trustHostKey}/bin/wechat-snapshot-trust-host-key";
            options = [ "NOPASSWD" ];
          }
          {
            command = "${controlVmService}/bin/wechat-vm-service-control";
            options = [ "NOPASSWD" ];
          }
        ];
      }
    ];
  };
}
