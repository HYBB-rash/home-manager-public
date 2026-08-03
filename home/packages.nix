{
  lib,
  pkgs,
  pkgsUnstable,
  ...
}:

let
  # Nixpkgs does not currently package CC Switch. Keep the upstream AppImage
  # pinned so upgrades remain reviewable and reversible through Home Manager.
  ccSwitch = pkgs.appimageTools.wrapType2 {
    pname = "cc-switch";
    version = "3.19.1";

    src = pkgs.fetchurl {
      url = "https://github.com/farion1231/cc-switch/releases/download/v3.19.1/CC-Switch-v3.19.1-Linux-x86_64.AppImage";
      hash = "sha256-GZ298Rw/hPyxIZEYco58IheNQmEI6b1Gl5JLjX0RhJ8=";
    };

    meta = {
      description = "Configuration manager for AI coding agents";
      homepage = "https://github.com/farion1231/cc-switch";
      mainProgram = "cc-switch";
      platforms = [ "x86_64-linux" ];
    };
  };
in
{
  # 只放行由 Home Manager 当前包集直接构建的非自由软件。
  nixpkgs.config.allowUnfreePredicate =
    package:
    builtins.elem (lib.getName package) [
      "vscode"
      "1password"
    ];

  # 通过 Home Manager 安装到用户环境的软件包。浏览器、邮件、QQ 和 Codex
  # 属于高频应用，统一由每日更新的 unstable 包集提供。
  home.packages = [
    # 桌面应用
    pkgsUnstable.qq
    pkgsUnstable.thunderbird
    pkgsUnstable.vivaldi
    pkgsUnstable.claude-code
    pkgsUnstable.opencode
    ccSwitch

    # 命令行工具
    pkgs.fastfetch
    pkgs.gh
    pkgsUnstable.codex
  ];
}
