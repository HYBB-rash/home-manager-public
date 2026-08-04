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
  user2ProjectInbox = "${operatorState}/user2-project-inbox";
  virtualBoxHome = "${operatorHome}/.config/VirtualBox";
  vmDirectory = "${operatorHome}/VirtualBox VMs/${cfg.vmName}";
  rdpUser = "wechat-console";
  vboxManage = "/run/current-system/sw/bin/VBoxManage";

  zeroTouchBinding = pkgs.writeText "wechat-zero-touch-binding.json" (
    builtins.toJSON {
      binding_version = 1;
      descriptor_ref = "descriptor.json";
      consumer_mode = "bundle";
      plane_bindings = {
        vm = {
          runtime_user = "wechat-exporter";
          managed_root = "/var/lib/wechat-exporter";
          release_select = {
            current = "current";
            previous = "previous";
          };
          state_root = "/var/lib/wechat-exporter/state";
          capabilities = {
            "vm.pkg" = "/var/lib/wechat-exporter/releases";
            "vm.state" = "/var/lib/wechat-exporter/state";
            "vm.published" = "/var/lib/wechat-exporter/state/published";
            "vm.wx_root" = "runtime-discovered";
          };
          units.sync-daemon.service = "wechat-exporter-sync.service";
        };
        host = {
          transport = {
            ssh_command = "wechat-snapshot-read-v1";
            tool = "restricted-tar";
            bridge = "system/wechat-snapshot-bridge.nix";
            validator = "system/wechat-snapshot.py";
          };
          units.pull = {
            service = "wechat-snapshot-pull.service";
            timer = "wechat-snapshot-pull.timer";
          };
          snapshot_contract_version = 1;
          pull_interval = cfg.interval;
          snapshot_retention = cfg.retention;
        };
        user2 = {
          runtime_user = cfg.readerUser;
          runtime_group = cfg.readerGroup;
          service = "hermes-user2.service";
          home = "/var/lib/hermes-user2/home";
          capabilities = {
            "user2.snapshot_db" = "${cfg.destination}/current/snapshot.db";
            "user2.scripts" = "/var/lib/hermes-user2/home/scripts";
          };
          cron = {
            managed_name_prefix = "wechat-zt:";
            inventory_path = "/var/lib/hermes-user2/home/runtime/wechat-zt-owned-jobs.json";
            profile = "user2";
          };
        };
      };
    }
  );

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
    # ssh-keyscan writes an informational banner as a comment before the
    # actual record. Count only syntactically complete ED25519 key records.
    ${pkgs.gawk}/bin/awk '$1 !~ /^#/ && NF == 3 && $2 == "ssh-ed25519" { print }' \
      "$scanned" >"$stage"
    [ "$(${pkgs.coreutils}/bin/wc -l <"$stage")" -eq 1 ] || {
      echo "expected exactly one scanned ED25519 SSH host key" >&2
      exit 1
    }
    actual="$(${pkgs.openssh}/bin/ssh-keygen -lf "$stage" -E sha256 | ${pkgs.gawk}/bin/awk '{print $2}')"
    [ "$actual" = "$expected" ] || {
      echo "SSH host fingerprint mismatch: expected $expected, observed $actual" >&2
      exit 1
    }
    ${pkgs.gawk}/bin/awk '{ print "wechat-exporter-vm", $2, $3 }' "$stage" >"$scanned"
    ${pkgs.coreutils}/bin/install -o root -g vboxusers -m 0640 \
      "$scanned" ${statePath}/known_hosts
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

  installSecond UserProject = pkgs.writeShellApplication {
    name = "wechat-user2-project-install";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      set -euo pipefail
      [ "$#" -eq 2 ] || { echo "usage: wechat-user2-project-install RELEASE ARCHIVE_NAME" >&2; exit 2; }
      release=$1
      archive_name=$2
      case "$release" in
        *[!0-9a-f]*) echo "invalid release id" >&2; exit 2 ;;
      esac
      [ "''${#release}" -eq 40 ] || { echo "release id must contain 40 hex characters" >&2; exit 2; }
      [ "$archive_name" = "$release.tar" ] || { echo "archive name must match release id" >&2; exit 2; }
      inbox=${lib.escapeShellArg user2ProjectInbox}
      archive="$inbox/$archive_name"
      [ -f "$archive" ] && [ ! -L "$archive" ] || { echo "release archive is not a regular file" >&2; exit 1; }
      exec ${pkgs.python3}/bin/python3 ${./wechat-project-release.py} \
        --archive "$archive" \
        --root ${lib.escapeShellArg cfg.destination} \
        --release "$release" \
        --owner root \
        --group ${lib.escapeShellArg cfg.readerGroup} \
        --expected-archive-owner user
    '';
  };

  codeReleaseInstaller = pkgs.writeShellApplication {
    name = "wechat-code-release-install";
    runtimeInputs = [ pkgs.python3 ];
    text = ''
      exec ${pkgs.python3}/bin/python3 ${./wechat-project-release.py} "$@"
    '';
  };

  cronReconciler = pkgs.writeShellApplication {
    name = "wechat-cron-reconcile";
    runtimeInputs = [ pkgs.python3 ];
    text = ''
      exec ${pkgs.python3}/bin/python3 ${./wechat-cron-reconcile.py} "$@"
    '';
  };

  zeroTouchRoot = pkgs.writeShellApplication {
    name = "wechat-zt-root";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.python3
      pkgs.systemd
      pkgs.util-linux
    ];
    text = ''
      case "''${1:-}" in
        preflight)
          [ "$#" -eq 1 ] || { echo "REFUSED R-111: invalid root preflight arguments" >&2; exit 2; }
          ;;
        reconcile)
          [ "$#" -eq 3 ] && [ "$2" = "--release-dir" ] || {
            echo "REFUSED R-111: invalid root reconcile arguments" >&2
            exit 2
          }
          ;;
        *)
          echo "REFUSED R-111: unsupported root operation" >&2
          exit 2
          ;;
      esac
      exec ${pkgs.python3}/bin/python3 ${./wechat-zero-touch.py} \
        --binding ${zeroTouchBinding} \
        --state-root /var/lib/wechat-zero-touch \
        --vmctl ${vmctl}/bin/wechat-vmctl \
        --installer ${codeReleaseInstaller}/bin/wechat-code-release-install \
        --cron-reconciler ${cronReconciler}/bin/wechat-cron-reconcile \
        --hermes-cli /run/current-system/sw/bin/hermes-user2-cli \
        --user2-wrapper /var/lib/hermes-user2/home/scripts/wechat-zt-daily-digest.sh \
        --user2-home /var/lib/hermes-user2/home \
        --user2-workspace /var/lib/hermes-user2/workspace \
        --user2-release-root ${lib.escapeShellArg cfg.destination} \
        --snapshot-db ${lib.escapeShellArg "${cfg.destination}/current/snapshot.db"} \
        --systemctl ${pkgs.systemd}/bin/systemctl \
        --runuser ${pkgs.util-linux}/bin/runuser \
        --id ${pkgs.coreutils}/bin/id \
        "$@"
    '';
  };

  zeroTouch = pkgs.writeShellApplication {
    name = "wechat-zt";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.git
      pkgs.nix
      pkgs.python3
      pkgs.gnused
    ];
    text = ''
      set -euo pipefail
      project="''${WX_PROJECT_DIR:-/home/user/Projects/Hermes/wechat-linux-decrypt-demo}"
      case "''${1:-release}" in
        release)
          [ "$#" -le 2 ] || { echo "usage: wechat-zt release [PROJECT_DIR]" >&2; exit 2; }
          if [ "$#" -eq 2 ]; then
            project=$2
          fi
          project="$(realpath "$project")"
          [ -d "$project/.git" ] || { echo "not a Git project: $project" >&2; exit 2; }
          [ -z "$(git -C "$project" status --porcelain)" ] || { echo "REFUSED R-100: project worktree is dirty" >&2; exit 1; }
          evidence="$(mktemp -t wechat-zt-evidence.XXXXXX.json)"
          trap 'rm -f -- "$evidence"' EXIT
          /run/wrappers/bin/sudo -n ${zeroTouchRoot}/bin/wechat-zt-root preflight \
            | sed -n 's/^OK: //p' >"$evidence"
          [ -s "$evidence" ] || { echo "REFUSED R-110: preflight produced no evidence" >&2; exit 1; }
          nix develop "$project" --command make -C "$project" test
          output="$(python3 "$project/tools/build_release.py" build \
            --repo "$project" --ready --evidence "$evidence")"
          printf '%s\n' "$output"
          release_dir="$(printf '%s\n' "$output" | ${pkgs.gawk}/bin/awk '/^OK: release / { print $5; exit }')"
          [ -n "$release_dir" ] || { echo "REFUSED R-100: builder returned no release path" >&2; exit 1; }
          /run/wrappers/bin/sudo -n ${zeroTouchRoot}/bin/wechat-zt-root reconcile \
            --release-dir "$release_dir" </dev/null
          ${vmctl}/bin/wechat-vmctl deploy-project "$project"
          ;;
        preflight)
          [ "$#" -eq 1 ] || { echo "usage: wechat-zt preflight" >&2; exit 2; }
          exec /run/wrappers/bin/sudo -n ${zeroTouchRoot}/bin/wechat-zt-root preflight </dev/null
          ;;
        *)
          echo "usage: wechat-zt {release [PROJECT_DIR]|preflight}" >&2
          exit 2
          ;;
      esac
    '';
  };

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
      pkgs.gnused
      pkgs.openssh
      pkgs.gnutar
    ];
    text = ''
      set -euo pipefail
      export HOME=${lib.escapeShellArg operatorHome}
      export VBOX_USER_HOME=${lib.escapeShellArg virtualBoxHome}
      vm=${lib.escapeShellArg cfg.vmName}
      operator_state=${lib.escapeShellArg operatorState}
      operator_key="$operator_state/operator_ed25519"
      operator_known_hosts=${lib.escapeShellArg "${statePath}/known_hosts"}
      user2_project_inbox=${lib.escapeShellArg user2ProjectInbox}
      bridge_interface=${lib.escapeShellArg cfg.bridgeInterface}
      bridge_mac=${lib.escapeShellArg cfg.bridgeMac}
      start_service() {
        /run/wrappers/bin/sudo ${controlVmService}/bin/wechat-vm-service-control start
      }
      stop_service() {
        /run/wrappers/bin/sudo ${controlVmService}/bin/wechat-vm-service-control stop
      }
      vm_state() {
        ${vboxManage} showvminfo "$vm" --machinereadable | sed -n 's/^VMState="\(.*\)"/\1/p'
      }
      bridge_settings() {
        ${vboxManage} showvminfo "$vm" --machinereadable | \
          ${pkgs.gawk}/bin/awk -F= '/^(nic2|bridgeadapter2|cableconnected2)=/ { gsub(/"/, "", $2); print $1 "=" $2 }'
      }
      bridge_mode() {
        bridge_settings | ${pkgs.gawk}/bin/awk -F= -v interface="$bridge_interface" '
          $1 == "nic2" { nic = $2 }
          $1 == "bridgeadapter2" { adapter = $2 }
          $1 == "cableconnected2" { cable = $2 }
          END {
            if (nic == "nat" && cable == "off") print "disabled"
            else if (nic == "bridged" && adapter == interface && cable == "on") print "enabled"
            else print "unexpected"
          }
        '
      }
      bridge_status() {
        state="$(vm_state)"
        mode="$(bridge_mode)"
        case "$mode" in
          enabled)
            printf 'LAN bridge: enabled (%s, NIC2)\n' "$bridge_interface"
            ;;
          disabled)
            printf 'LAN bridge: disabled (NIC2)\n'
            ;;
          unexpected)
            printf 'LAN bridge: unexpected NIC2 configuration\n' >&2
            bridge_settings >&2
            return 1
            ;;
        esac
        printf 'VM state: %s\n' "$state"
      }
      reconfigure_bridge() {
        requested_mode=$1
        current_mode="$(bridge_mode)"
        if [ "$current_mode" = "$requested_mode" ]; then
          printf 'LAN bridge is already %s.\n' "$requested_mode"
          return 0
        fi

        service_was_active=0
        if ${pkgs.systemd}/bin/systemctl is-active --quiet wechat-exporter-vm.service; then
          service_was_active=1
        fi

        state="$(vm_state)"
        if [ "$state" = running ] && [ "$service_was_active" -eq 1 ]; then
          case "$requested_mode" in
            enabled)
              ${vboxManage} controlvm "$vm" nic2 bridged "$bridge_interface"
              ${vboxManage} controlvm "$vm" setlinkstate2 on
              ;;
            disabled)
              ${vboxManage} controlvm "$vm" setlinkstate2 off
              ${vboxManage} controlvm "$vm" nic2 nat
              ;;
          esac
        elif [ "$state" = poweroff ] || [ "$state" = aborted ]; then
          case "$requested_mode" in
            enabled)
              ${vboxManage} modifyvm "$vm" \
                --nic2 bridged \
                --bridgeadapter2 "$bridge_interface" \
                --macaddress2 "$bridge_mac" \
                --cableconnected2 on
              ;;
            disabled)
              ${vboxManage} modifyvm "$vm" --nic2 nat --cableconnected2 off
              ;;
          esac
        elif [ "$state" = saved ]; then
          echo "VM is saved; start the managed service first, then retry the bridge command." >&2
          exit 1
        else
          echo "VM is in unsupported state for NIC2 reconfiguration: $state" >&2
          exit 1
        fi
        bridge_status
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
      operator_ssh() {
        ssh -p 22223 -o BatchMode=yes -o StrictHostKeyChecking=yes \
          -i "$operator_key" -o IdentitiesOnly=yes \
          -o HostKeyAlias=wechat-exporter-vm \
          -o UserKnownHostsFile="$operator_known_hosts" \
          wechat-exporter@${lib.escapeShellArg cfg.remoteHost} "$@"
      }
      configure_rootless_pull() {
        pull_key="$(${pkgs.coreutils}/bin/base64 -w0 <${statePath}/id_ed25519.pub)"
        operator_ssh bash -s -- "$pull_key" <<'REMOTE'
          set -euo pipefail
          key="$(printf '%s' "$1" | base64 -d)"
          case "$key" in
            'ssh-ed25519 '*) ;;
            *) exit 2 ;;
          esac
          root=/var/lib/wechat-exporter
          helper="$root/state/snapshot-read-v1"
          stage="$(mktemp "$root/state/.snapshot-read-v1.XXXXXX")"
          printf '%s\n' \
            '#!/bin/sh' \
            'set -eu' \
            '[ "''${SSH_ORIGINAL_COMMAND:-}" = "wechat-snapshot-read-v1" ] || exit 126' \
            'dir=/var/lib/wechat-exporter/state/published' \
            'set -- "$dir"/published_*.db' \
            '[ "$#" -eq 1 ] && [ -f "$1" ] || exit 1' \
            'base=''${1##*/}' \
            'exec /run/current-system/sw/bin/tar -C "$dir" --transform="s|^$base$|snapshot.db|" -cf - "$base"' \
            >"$stage"
          chmod 0700 "$stage"
          mv -f "$stage" "$helper"
          install -d -m 0700 "$HOME/.ssh"
          touch "$HOME/.ssh/authorized_keys"
          chmod 0600 "$HOME/.ssh/authorized_keys"
          entry="restrict,command=\"$helper\" $key"
          authorized_stage="$(mktemp "$HOME/.ssh/.authorized_keys.XXXXXX")"
          grep -Fv "restrict,command=\"$helper\" " "$HOME/.ssh/authorized_keys" >"$authorized_stage" || true
          printf '%s\n' "$entry" >>"$authorized_stage"
          chmod 0600 "$authorized_stage"
          mv -f "$authorized_stage" "$HOME/.ssh/authorized_keys"
      REMOTE
      }
      install_user2_project() {
        release=$1
        archive=$2
        install -d -m 0700 "$user2_project_inbox"
        inbox_archive="$user2_project_inbox/$release.tar"
        install -m 0600 "$archive" "$inbox_archive"
        if ! /run/wrappers/bin/sudo ${installSecond UserProject}/bin/wechat-user2-project-install \
            "$release" "$release.tar"; then
          rm -f -- "$inbox_archive"
          return 1
        fi
        rm -f -- "$inbox_archive"
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
          stop_service
          ${configureVm}/bin/wechat-vm-configure
          start_service
          ;;
        bridge)
          [ "$#" -eq 2 ] || { echo "usage: wechat-vmctl bridge {enable|disable|status}" >&2; exit 2; }
          case "$2" in
            enable)
              reconfigure_bridge enabled
              ;;
            disable)
              reconfigure_bridge disabled
              ;;
            status)
              bridge_status
              ;;
            *)
              echo "usage: wechat-vmctl bridge {enable|disable|status}" >&2
              exit 2
              ;;
          esac
          ;;
        start|start-headless)
          start_service
          ;;
        stop)
          stop_service
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
        configure-rootless-pull)
          [ "$#" -eq 1 ] || { echo "usage: wechat-vmctl configure-rootless-pull" >&2; exit 2; }
          configure_rootless_pull
          ;;
        deploy)
          remove_archive=0
          if [ "$#" -eq 5 ] && [ "$2" = "--artifact" ]; then
            release=$3
            case "$release" in
              *[!0-9a-f]*) echo "invalid source release" >&2; exit 2 ;;
            esac
            [ "''${#release}" -eq 40 ] || { echo "source release must be a full Git SHA-1" >&2; exit 2; }
            archive="$(${pkgs.coreutils}/bin/realpath "$4")"
            [ -f "$archive" ] && [ ! -L "$archive" ] || { echo "VM artifact is not a regular file" >&2; exit 1; }
            expected_sha=$5
            actual_sha="sha256:$(${pkgs.coreutils}/bin/sha256sum "$archive" | ${pkgs.gawk}/bin/awk '{print $1}')"
            [ "$actual_sha" = "$expected_sha" ] || { echo "VM artifact digest mismatch" >&2; exit 1; }
            release_short="''${release:0:12}"
          else
            [ "$#" -eq 2 ] || { echo "usage: wechat-vmctl deploy EXPORTER_SOURCE | deploy --artifact SOURCE_SHA ARCHIVE SHA256" >&2; exit 2; }
            source_dir="$(${pkgs.coreutils}/bin/realpath "$2")"
            [ -d "$source_dir" ] || { echo "exporter source is not a directory: $source_dir" >&2; exit 1; }
            release="$(git -C "$source_dir" rev-parse --verify HEAD)"
            release_short="$(git -C "$source_dir" rev-parse --short=12 "$release")"
            archive="$(mktemp -t "wechat-exporter-$release_short.XXXXXX.tar")"
            remove_archive=1
            git -C "$source_dir" archive --format=tar --output="$archive" "$release"
          fi
          artifact_sha="sha256:$(${pkgs.coreutils}/bin/sha256sum "$archive" | ${pkgs.gawk}/bin/awk '{print $1}')"
          if [ "$remove_archive" -eq 1 ]; then
            trap 'rm -f -- "$archive"' EXIT
          fi
          scp -P 22223 -o BatchMode=yes -o StrictHostKeyChecking=yes \
            -i "$operator_key" -o IdentitiesOnly=yes \
            -o HostKeyAlias=wechat-exporter-vm \
            -o UserKnownHostsFile="$operator_known_hosts" \
            "$archive" wechat-exporter@${lib.escapeShellArg cfg.remoteHost}:"/var/lib/wechat-exporter/.incoming-''${release}.tar"
          operator_ssh bash -s -- "$release" "$artifact_sha" <<'REMOTE'
            set -euo pipefail
            release=$1
            artifact_sha=$2
            root=/var/lib/wechat-exporter
            releases="$root/releases"
            state="$root/state"
            incoming="$root/.incoming-$release.tar"
            mkdir -p "$releases" "$state"
            stage="$(mktemp -d "$releases/.stage.$release.XXXXXX")"
            cleanup() {
              test -z "$stage" || rm -rf -- "$stage"
              rm -f -- "$incoming"
            }
            trap cleanup EXIT

            test -f "$incoming"
            if test ! -e "$state/published" && test -e "$root/published" && ! test -L "$root/published"; then
              mv "$root/published" "$state/published"
            fi
            mkdir -p "$state/published"

            # The previous one-shot layout stored account state beside source.
            # Move it once, then leave compatibility symlinks for the old unit.
            mkdir -p "$root/source"
            for name in config.local.json keys.json decrypted; do
              if test ! -e "$state/$name" && test -e "$root/source/$name" && ! test -L "$root/source/$name"; then
                mv "$root/source/$name" "$state/$name"
              fi
              if test -e "$state/$name" && ! test -L "$root/source/$name"; then
                rm -rf -- "$root/source/$name"
                ln -s "$state/$name" "$root/source/$name"
              fi
            done
            if ! test -L "$root/published"; then
              rm -rf -- "$root/published"
              ln -s "$state/published" "$root/published"
            fi

            tar -xf "$incoming" -C "$stage"
            test -f "$stage/sync.py"
            printf '%s\n' "$artifact_sha" >"$stage/.artifact-sha256"
            if test -d "$stage/tests"; then
              test_state="$(mktemp -d "$stage/.test-state.XXXXXX")"
              WX_EXPORT_STATE_DIR="$test_state" \
                WX_EXPORT_OUTPUT_DIR="$test_state/published" \
                WX_EXPORT_MANAGED_DEPLOYMENT=1 \
                /run/current-system/sw/bin/python3 -m unittest discover -s "$stage/tests"
              rm -rf -- "$test_state"
            else
              /run/current-system/sw/bin/python3 -m py_compile "$stage"/*.py
            fi

            if test -d "$releases/$release"; then
              test -f "$releases/$release/.artifact-sha256"
              test "$(cat "$releases/$release/.artifact-sha256")" = "$artifact_sha"
            else
              mv "$stage" "$releases/$release"
              stage=
            fi
            old_current=
            if test -L "$root/current"; then
              old_current="$(readlink "$root/current")"
            fi
            next="$root/.current.$release"
            ln -s "releases/$release" "$next"
            mv -Tf "$next" "$root/current"
            if test -n "$old_current"; then
              next_previous="$root/.previous.$release"
              ln -s "$old_current" "$next_previous"
              mv -Tf "$next_previous" "$root/previous"
            fi

            # Existing imported guests still execute source/sync.py. Keep this
            # tiny forwarder until their next declarative image migration.
            if ! systemctl cat wechat-exporter-sync.service 2>/dev/null | grep -Fq '/var/lib/wechat-exporter/current/sync.py'; then
              launcher="$root/source/.sync.py.$release"
              printf '%s\n' \
                'import os, sys' \
                'root = "/var/lib/wechat-exporter"' \
                'env = os.environ.copy()' \
                'env["WX_EXPORT_STATE_DIR"] = root + "/state"' \
                'env["WX_EXPORT_OUTPUT_DIR"] = root + "/state/published"' \
                'env["WX_EXPORT_MANAGED_DEPLOYMENT"] = "1"' \
                'env["PATH"] = "/run/current-system/sw/bin:" + env.get("PATH", "")' \
                'env["LC_ALL"] = "C"' \
                'os.execve(sys.executable, [sys.executable, root + "/current/sync.py"], env)' \
                >"$launcher"
              chmod 0700 "$launcher"
              mv -f "$launcher" "$root/source/sync.py"
            fi

            if test -f "$state/config.local.json" && test -f "$state/keys.json"; then
              sudo systemctl stop wechat-exporter-sync.service
              if ! WX_EXPORT_STATE_DIR="$state" \
                  WX_EXPORT_OUTPUT_DIR="$state/published" \
                  WX_EXPORT_MANAGED_DEPLOYMENT=1 \
                  /run/current-system/sw/bin/python3 "$root/current/sync.py" \
                    --full --once; then
                if test -n "$old_current"; then
                  rollback="$root/.rollback.$release"
                  ln -s "$old_current" "$rollback"
                  mv -Tf "$rollback" "$root/current"
                fi
                sudo systemctl start wechat-exporter-sync.service
                echo "release $release failed mandatory full rebuild; restored previous release" >&2
                exit 1
              fi
              sudo systemctl start wechat-exporter-sync.service
              published="$(find "$state/published" -maxdepth 1 -type f -name 'published_*.db' -print -quit)"
              if test -n "$published" && \
                WX_EXPORT_STATE_DIR="$state" WX_EXPORT_OUTPUT_DIR="$state/published" \
                WX_EXPORT_MANAGED_DEPLOYMENT=1 \
                /run/current-system/sw/bin/python3 "$root/current/sync.py" \
                  --health --db "$published" --max-age 180; then
                printf 'deployed release %s after mandatory full rebuild and verified exporter health\n' "$release"
                exit 0
              fi
              if test -n "$old_current"; then
                rollback="$root/.rollback.$release"
                ln -s "$old_current" "$rollback"
                mv -Tf "$rollback" "$root/current"
                sudo systemctl restart wechat-exporter-sync.service
              fi
              echo "release $release failed post-rebuild health verification; restored previous release" >&2
              exit 1
            fi
            printf 'deployed release %s; bootstrap remains: config.local.json and keys.json\n' "$release"
      REMOTE
          if [ "$remove_archive" -eq 1 ]; then
            trap - EXIT
            rm -f -- "$archive"
          fi
          ;;
        deploy-project)
          [ "$#" -eq 2 ] || { echo "usage: wechat-vmctl deploy-project EXPORTER_SOURCE" >&2; exit 2; }
          source_dir="$(${pkgs.coreutils}/bin/realpath "$2")"
          [ -d "$source_dir" ] || { echo "exporter source is not a directory: $source_dir" >&2; exit 1; }
          [ -z "$(git -C "$source_dir" status --porcelain)" ] || { echo "project worktree is dirty" >&2; exit 1; }
          release="$(git -C "$source_dir" rev-parse --verify HEAD)"
          release_short="$(git -C "$source_dir" rev-parse --short=12 "$release")"
          archive="$(mktemp -t "wechat-user2-project-$release_short.XXXXXX.tar")"
          trap 'rm -f -- "$archive"' EXIT
          git -C "$source_dir" archive --format=tar --output="$archive" "$release"
          install_user2_project "$release" "$archive"
          printf 'deployed Second User project release %s\n' "$release"
          ;;
        rollback)
          [ "$#" -eq 1 ] || { echo "usage: wechat-vmctl rollback" >&2; exit 2; }
          # shellcheck disable=SC2016
          operator_ssh 'set -euo pipefail; root=/var/lib/wechat-exporter; test -L "$root/current"; current=$(readlink "$root/current"); if test -L "$root/previous"; then previous=$(readlink "$root/previous"); next="$root/.rollback"; ln -s "$previous" "$next"; mv -Tf "$next" "$root/current"; next="$root/.previous"; ln -s "$current" "$next"; mv -Tf "$next" "$root/previous"; sudo systemctl restart wechat-exporter-sync.service; printf "restored %s\\n" "$previous"; else rm "$root/current"; sudo systemctl stop wechat-exporter-sync.service; printf "removed first code release; state preserved\\n"; fi'
          ;;
        release-status)
          [ "$#" -eq 1 ] || { echo "usage: wechat-vmctl release-status" >&2; exit 2; }
          # shellcheck disable=SC2016
          operator_ssh 'set -eu; root=/var/lib/wechat-exporter; for link in current previous; do if test -L "$root/$link"; then printf "%s: %s\\n" "$link" "$(readlink "$root/$link")"; else printf "%s: absent\\n" "$link"; fi; done; systemctl is-active wechat-exporter-sync.service || true; find "$root/state/published" -maxdepth 1 -type f -name "sync_health_*.json" -printf "health: %f\\n" 2>/dev/null || true'
          for link in project-current project-previous; do
            if [ -L ${lib.escapeShellArg cfg.destination}/"$link" ]; then
              printf 'user2-%s: %s\n' "$link" "$(readlink ${lib.escapeShellArg cfg.destination}/"$link")"
            else
              printf 'user2-%s: absent\n' "$link"
            fi
          done
          ;;
        trust-host-key)
          [ "$#" -eq 2 ] || { echo "usage: wechat-vmctl trust-host-key SHA256:fingerprint" >&2; exit 2; }
          ssh-keyscan -t ed25519 -p ${toString cfg.remotePort} ${lib.escapeShellArg cfg.remoteHost} \
            | /run/wrappers/bin/sudo ${trustHostKey}/bin/wechat-snapshot-trust-host-key "$2"
          ;;
        *)
          echo "usage: wechat-vmctl {import OVA|configure-network|bridge {enable|disable|status}|start|stop|status|console|console-check|pull-key|operator-key|configure-rootless-pull|trust-host-key FINGERPRINT|deploy EXPORTER_SOURCE|deploy --artifact SOURCE_SHA ARCHIVE SHA256|deploy-project EXPORTER_SOURCE|rollback|release-status}" >&2
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

    pullTransport = lib.mkOption {
      type = lib.types.enum [
        "sftp"
        "restricted-tar"
      ];
      default = "sftp";
      description = "Guest snapshot transport used by the host pull service.";
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

    bridgeInterface = lib.mkOption {
      type = lib.types.str;
      default = "wlp0s20f3";
      description = "Host interface used by the opt-in bridged NIC2.";
    };

    bridgeMac = lib.mkOption {
      type = lib.types.str;
      default = "080027A11CE2";
      description = "Fixed NIC2 MAC matched by the guest firewall policy.";
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
      zeroTouch
    ];

    systemd.tmpfiles.rules = [
      "d ${cfg.destination} 0750 root ${cfg.readerGroup} -"
      "d ${cfg.destination}/generations 0750 root ${cfg.readerGroup} -"
      "d ${cfg.destination}/bundle-releases 0750 root ${cfg.readerGroup} -"
      "d ${cfg.destination}/project-releases 0750 root ${cfg.readerGroup} -"
      "d /var/lib/wechat-zero-touch 0700 root root -"
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
          "--transport"
          cfg.pullTransport
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
          {
            command = "${zeroTouchRoot}/bin/wechat-zt-root";
            options = [ "NOPASSWD" ];
          }
          {
            command = "${installSecond UserProject}/bin/wechat-user2-project-install";
            options = [ "NOPASSWD" ];
          }
        ];
      }
    ];
  };
}
