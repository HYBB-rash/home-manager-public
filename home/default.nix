{ ... }:

{
  imports = [
    ./applications/codex-desktop
    ./packages.nix
    ./shell.nix
    ./desktop.nix
    ./applications.nix
    ./flatpak.nix
    ./updates.nix
  ];

  # Home Manager 需要知道要管理的用户及其主目录。
  home.username = "user";
  home.homeDirectory = "/home/user";

  # 此值决定当前配置与哪个 Home Manager 版本兼容，用于避免新版引入不向后兼容的
  # 默认行为时破坏现有环境。
  #
  # 即使升级 Home Manager 也不应随意修改；确实需要更新时，请先阅读对应版本的发行说明。
  home.stateVersion = "26.05"; # 修改前请先阅读上方说明。

  # 让 Home Manager 安装并管理自身。
  programs.home-manager.enable = true;
}
