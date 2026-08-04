{ pkgs, ... }:
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
