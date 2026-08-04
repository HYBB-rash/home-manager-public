{ pkgs, ... }:

let
  wechatZtDailyDigest = pkgs.writeShellScript "wechat-zt-daily-digest" ''
    set -euo pipefail
    bundle=/var/lib/hermes-user2-wechat/bundle-current/bundle/wechat-consumer-zt
    snapshot=/var/lib/hermes-user2-wechat/current/snapshot.db
    export WECHAT_SNAPSHOT_DB="$snapshot"
    case "''${1:-}" in
      --check-only)
        [ "$#" -eq 1 ] || exit 2
        exec "$bundle/bin/wx-check" --db "$snapshot"
        ;;
      *)
        if [ "$#" -eq 0 ]; then
          exec "$bundle/bin/wx-daily-digest" --db "$snapshot" --text
        fi
        echo "unsupported managed wrapper argument" >&2
        exit 2
        ;;
    esac
  '';
in
{

  services.gnome.gnome-keyring.enable = true;
  services.printing.enable = true;

  # 使用 PipeWire 提供音频，并保留 32 位 ALSA 应用兼容。
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  # 为迁移 Windows 微信数据的虚拟机提供 VirtualBox 宿主支持。
  virtualisation.virtualbox.host = {
    enable = true;
    enableExtensionPack = true;
  };

  # Pull only completed, integrity-checked VM snapshots into Second User's read-only view.
  services.wechatSnapshotBridge = {
    enable = true;
    # Keep the pre-bridge VM registered and saved as a rollback target while
    # the service manages the rebuilt guest with the LAN firewall policy.
    vmName = "wechat-exporter-lan-secure";
    remoteUser = "wechat-exporter";
    pullTransport = "restricted-tar";
  };

  # 使用 LXC 在 Plasma Wayland 会话中运行 Android 应用。
  virtualisation.waydroid = {
    enable = true;
    # 新内核不再提供 legacy ip_tables 模块，直接使用原生 nftables 网络脚本。
    package = pkgs.waydroid-nftables;
  };


  services.gvfs.enable = true;
  services.udisks2.enable = true;
  services.flatpak.enable = true;

  # ssh 配置
  services.openssh = {
    enable = true;

    openFirewall = true;

    ports = [ 22 ];

    settings = {
      PermitRootLogin = "no";

      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PubkeyAuthentication = true;

      AllowUsers = [ "user" ];

      MaxAuthTries = 5;
    };

  };

  users.users.user.openssh.authorizedKeys.keys = [
    "ssh-ed25519 REPLACE_WITH_YOUR_PUBLIC_KEY"
  ];

}
