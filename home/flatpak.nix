{
  config,
  lib,
  pkgs,
  ...
}:

let
  flatpak = lib.getExe pkgs.flatpak;
  mkFontFamilies =
    families: lib.concatMapStringsSep "\n" (family: "      <family>${family}</family>") families;
  # Flatpak 会导出宿主机字体文件，但不会导出宿主机的 fontconfig 规则。
  # 因此只在运行时配置之上重建可移植的字体族优先级。
  flatpakFontconfig = pkgs.writeText "flatpak-fonts.conf" ''
    <?xml version="1.0"?>
    <!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
    <fontconfig>
      <include ignore_missing="no">/etc/fonts/fonts.conf</include>

      <alias binding="same">
        <family>sans-serif</family>
        <prefer>
    ${mkFontFamilies config.fonts.fontconfig.defaultFonts.sansSerif}
        </prefer>
      </alias>

      <alias binding="same">
        <family>serif</family>
        <prefer>
    ${mkFontFamilies config.fonts.fontconfig.defaultFonts.serif}
        </prefer>
      </alias>

      <alias binding="same">
        <family>monospace</family>
        <prefer>
    ${mkFontFamilies config.fonts.fontconfig.defaultFonts.monospace}
        </prefer>
      </alias>

      <alias binding="same">
        <family>emoji</family>
        <prefer>
    ${mkFontFamilies config.fonts.fontconfig.defaultFonts.emoji}
        </prefer>
      </alias>
    </fontconfig>
  '';
in

{

  # 这些应用独立且频繁发布，因此由 Flathub 更新，不与固定的 nixpkgs 修订绑定。
  services.flatpak = {
    enable = true;
    packages = [
      "com.discordapp.Discord"
      "com.tencent.WeChat"
      "com.tradingview.tradingview"
      "com.usebottles.bottles"
      "com.vysp3r.ProtonPlus"
      "io.typora.Typora"
      "org.telegram.desktop"
      "com.super_productivity.SuperProductivity"
    ];

    update.auto = {
      enable = true;
      # 每天由用户级定时任务检查并安装 Flatpak 更新。
      onCalendar = "daily";
    };

    # 保留手动安装的 Flatpak，但清理已不被任何应用引用的运行时。
    uninstallUnmanaged = false;
    uninstallUnused = true;

    overrides = {
      # 只向沙箱暴露生成的可移植规则文件，而不是完整的宿主机 fontconfig 目录。
      # 直接指向 store 路径，也能避开目标在沙箱内不可见的 Home Manager 符号链接。
      global.Context.filesystems = [ "${flatpakFontconfig}:ro" ];
      global.Environment = {
        FONTCONFIG_FILE = "${flatpakFontconfig}";
        # 让 GTK、Qt 和传统 XIM 应用统一使用 Fcitx 输入法。
        GTK_IM_MODULE = "fcitx";
        QT_IM_MODULE = "fcitx";
        XMODIFIERS = "@im=fcitx";
        XCURSOR_PATH = "/run/host/user-share/icons:/run/host/share/icons";
      };
    };
  };
}
