{ lib, pkgs, ... }:

{
  # 让 nh 在任意工作目录中都默认使用当前 NixOS Flake 仓库。
  programs.nh = {
    enable = true;
    flake = "/home/user/.config/home-manager";
  };

  programs._1password.enable = true;
  programs._1password-gui = {
    enable = true;
    polkitPolicyOwners = [ "user" ];
  };

  # 只允许系统配置实际需要的非自由 1Password 软件包。
  nixpkgs.config.allowUnfreePredicate =
    package:
    builtins.elem (lib.getName package) [
      "1password"
      "1password-cli"
    ];

  # 启用新式 Nix 命令和 flake 支持。
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  # 为面向通用 Linux 发行版构建的动态链接可执行文件提供兼容加载器。
  programs.nix-ld = {
    enable = true;
    libraries = with pkgs; [ ];
  };

  environment.systemPackages = with pkgs; [
    # 基础工具
    vim
    wget
    git

    # 传感器与硬件信息
    lm_sensors
    smartmontools
    btop

    # Wayland 与截图工具
    wl-clipboard
    grim
    slurp

    # 音频、亮度与媒体控制
    pavucontrol
    brightnessctl
    playerctl

    # 桌面文件、图标与归档工具
    adwaita-icon-theme
    papirus-icon-theme
    nautilus
    file-roller
    xrdb

    # 远程桌面
    remmina
    freerdp

    # 容器管理
    podman
  ];

  programs.firefox.enable = true;
}
