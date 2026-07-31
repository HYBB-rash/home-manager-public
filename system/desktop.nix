{ lib, pkgs, ... }:

let
  monoFontFamily = "Maple Mono NF CN";
  monoSymbolFallback = "Symbols Nerd Font Mono";
  uiFontFamily = "Source Han Sans SC";
in

{
  time.timeZone = "Asia/Shanghai";

  i18n.defaultLocale = "en_US.UTF-8";
  i18n.extraLocaleSettings = {
    LC_ADDRESS = "zh_CN.UTF-8";
    LC_IDENTIFICATION = "zh_CN.UTF-8";
    LC_MEASUREMENT = "zh_CN.UTF-8";
    LC_MONETARY = "zh_CN.UTF-8";
    LC_NAME = "zh_CN.UTF-8";
    LC_NUMERIC = "zh_CN.UTF-8";
    LC_PAPER = "zh_CN.UTF-8";
    LC_TELEPHONE = "zh_CN.UTF-8";
    LC_TIME = "zh_CN.UTF-8";
  };

  i18n.inputMethod = {
    enable = true;
    type = "fcitx5";

    fcitx5 = {
      waylandFrontend = true;
      addons = with pkgs; [
        (fcitx5-rime.override {
          # 通过 fcitx5-rime 的正式接口提供雾凇拼音数据，确保插件读取的就是这套词库。
          rimeDataPkgs = [ rime-ice ];
        })
        fcitx5-material-color
      ];
    };
  };

  fonts.packages = with pkgs; [
    maple-mono.NF-CN
    source-han-sans
    material-symbols
    nerd-fonts.jetbrains-mono
    nerd-fonts.symbols-only
  ];

  # 自定义字体排在 Plasma 的 Noto/Hack 后备字体之前，同时保留后备字体以覆盖更多字符。
  fonts.fontconfig.defaultFonts = {
    monospace = lib.mkBefore [
      monoFontFamily
      monoSymbolFallback
    ];
    sansSerif = lib.mkBefore [ uiFontFamily ];
    serif = lib.mkBefore [ uiFontFamily ];
    emoji = lib.mkBefore [ "Noto Color Emoji" ];
  };

  # SDL 和 GLFW 尚不能统一使用 Wayland 输入法协议；GTK、Qt 与 XIM 变量由
  # waylandFrontend 对应的 NixOS 模块按正确方式管理。
  environment.variables = {
    SDL_IM_MODULE = "fcitx";
    GLFW_IM_MODULE = "fcitx";
  };

  # 当前只使用 Plasma Wayland 会话，不启用传统 X11 会话。
  services.xserver.enable = false;
  services.displayManager.sddm.enable = true;
  services.desktopManager.plasma6.enable = true;
}
