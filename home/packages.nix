{
  lib,
  pkgs,
  pkgsUnstable,
  ...
}:

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

    # 命令行工具
    pkgs.fastfetch
    pkgs.gh
    pkgsUnstable.codex
  ];
}
