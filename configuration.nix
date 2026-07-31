{ ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./system
  ];

  # 主机级配置保留在系统入口。
  networking.hostName = "nixos";

  # 此值记录首次安装所基于的 NixOS 版本；升级系统时不要随意修改。
  system.stateVersion = "26.05";
}
