{
  config,
  lib,
  pkgs,
  ...
}:

let
  monoFontFamily = "Maple Mono NF CN";
  monoSymbolFallback = "Symbols Nerd Font Mono";
  uiFontFamily = "Source Han Sans SC";
  uiFontPointSize = 10.5;
  monoFontPointSize = 11;
  smallFontPointSize = 9;
  plasmaFont = family: size: "${family},${toString size},-1,5,400,0,0,0,0,0,0,0,0,0,0,1,,0,0";
in

{
  home.sessionVariables = {
    BROWSER = "vivaldi";
    EDITOR = "vim";
    TERMINAL = "kitty";
    # 让 GTK 2 同时读取 Plasma 生成的基础配置和下方声明的字体覆盖。
    GTK2_RC_FILES = lib.concatStringsSep ":" [
      "${config.home.homeDirectory}/.gtkrc-2.0"
      "${config.xdg.configHome}/gtk-2.0/ui-font.rc"
    ];
  };

  # 同时安装 xdg-terminal-exec 并声明 Kitty，供遵循该桌面规范的程序调用。
  xdg.terminal-exec = {
    enable = true;
    settings.default = [ "kitty.desktop" ];
  };

  # 保留 MIME 文件中由桌面设置管理的其他关联，只更新默认浏览器和 Telegram 私有协议。
  home.activation.setDefaultApplications = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    PATH="${lib.makeBinPath [ pkgs.kdePackages.qtbase ]}:$PATH" \
      ${pkgs.xdg-utils}/bin/xdg-mime default vivaldi-stable.desktop text/html
    PATH="${lib.makeBinPath [ pkgs.kdePackages.qtbase ]}:$PATH" \
      ${pkgs.xdg-utils}/bin/xdg-mime default vivaldi-stable.desktop application/xhtml+xml
    PATH="${lib.makeBinPath [ pkgs.kdePackages.qtbase ]}:$PATH" \
      ${pkgs.xdg-utils}/bin/xdg-mime default vivaldi-stable.desktop x-scheme-handler/http
    PATH="${lib.makeBinPath [ pkgs.kdePackages.qtbase ]}:$PATH" \
      ${pkgs.xdg-utils}/bin/xdg-mime default vivaldi-stable.desktop x-scheme-handler/https
    PATH="${lib.makeBinPath [ pkgs.kdePackages.qtbase ]}:$PATH" \
      ${pkgs.xdg-utils}/bin/xdg-mime default org.telegram.desktop.desktop x-scheme-handler/tg
    PATH="${lib.makeBinPath [ pkgs.kdePackages.qtbase ]}:$PATH" \
      ${pkgs.xdg-utils}/bin/xdg-mime default org.telegram.desktop.desktop x-scheme-handler/tonsite
  '';

  fonts.fontconfig = {
    enable = true;
    antialiasing = true;
    hinting = "slight";
    subpixelRendering = "none";

    defaultFonts = {
      monospace = [
        monoFontFamily
        monoSymbolFallback
      ];
      sansSerif = [ uiFontFamily ];
      serif = [ uiFontFamily ];
      emoji = [ "Noto Color Emoji" ];
    };
  };

  # 为仍读取 Xresources 的 X11 应用指定 HiDPI 缩放基准。
  xresources.properties."xft.dpi" = 196;

  # Plasma 及其 GTK 兼容层会保存优先级高于 fontconfig 的显式字体设置。
  # 这里只更新字体相关键，不接管桌面的其他配置。
  qt.kde.settings = {
    kdeglobals = {
      General = {
        fixed = plasmaFont monoFontFamily monoFontPointSize;
        font = plasmaFont uiFontFamily uiFontPointSize;
        menuFont = plasmaFont uiFontFamily uiFontPointSize;
        smallestReadableFont = plasmaFont uiFontFamily smallFontPointSize;
        toolBarFont = plasmaFont uiFontFamily uiFontPointSize;
      };
      WM.activeFont = plasmaFont uiFontFamily uiFontPointSize;
    };

    "gtk-3.0/settings.ini".Settings."gtk-font-name" = "${uiFontFamily} ${toString uiFontPointSize}";
    "gtk-4.0/settings.ini".Settings."gtk-font-name" = "${uiFontFamily} ${toString uiFontPointSize}";
    "Trolltech.conf".qt.font = "\"${plasmaFont uiFontFamily uiFontPointSize}\"";
    konsolerc."Desktop Entry".DefaultProfile = "Maple.profile";
  };

  # 为读取 GNOME 接口设置的应用同步相同的界面字体。
  dconf.settings."org/gnome/desktop/interface" = {
    "font-name" = "${uiFontFamily} ${toString uiFontPointSize}";
    "document-font-name" = "${uiFontFamily} ${toString uiFontPointSize}";
    "monospace-font-name" = "${monoFontFamily} ${toString monoFontPointSize}";
  };

  # GTK 2 没有与 KConfig 兼容的 Home Manager 单键选项，因此在 Plasma 现有的
  # GTK 2 设置之后加载这份最小化声明式覆盖。
  xdg.configFile."gtk-2.0/ui-font.rc".text = ''
    gtk-font-name = "${uiFontFamily} ${toString uiFontPointSize}"
  '';

  # 以声明式方式管理 Fcitx 用户级经典界面设置。此文件优先于 /etc/xdg，
  # 因此直接指定界面字体族，不依赖通用的 Sans 别名。
  xdg.configFile."fcitx5/conf/classicui.conf".text = ''
    Vertical Candidate List=False
    WheelForPaging=True
    Font="${uiFontFamily} ${toString uiFontPointSize}"
    MenuFont="${uiFontFamily} ${toString uiFontPointSize}"
    TrayFont="${uiFontFamily} Bold ${toString uiFontPointSize}"
    TrayOutlineColor=#000000
    TrayTextColor=#ffffff
    PreferTextIcon=False
    ShowLayoutNameInIcon=True
    UseInputMethodLanguageToDisplayText=True
    Theme=Material-Color-deepPurple
    DarkTheme=Material-Color-black
    UseDarkTheme=True
    UseAccentColor=True
    PerScreenDPI=False
    ForceWaylandDPI=0
    EnableFractionalScale=True
  '';

  # Konsole 随 Plasma 安装；这里显式指定终端字体，不只依赖桌面的通用等宽字体角色。
  xdg.dataFile."konsole/Maple.profile".text = ''
    [Appearance]
    Font=${plasmaFont monoFontFamily monoFontPointSize}

    [General]
    Name=Maple
    Parent=FALLBACK/
  '';

  programs.kitty = {
    enable = true;

    font = {
      name = monoFontFamily;
      size = monoFontPointSize;
    };

    settings = {
      background = "#fdf6e3";
      foreground = "#839496";

      selection_background = "#073642";
      selection_foreground = "#93a1a1";

      cursor = "#93a1a1";
      cursor_text_color = "#002b36";

      color0 = "#073642";
      color1 = "#dc322f";
      color2 = "#859900";
      color3 = "#b58900";
      color4 = "#268bd2";
      color5 = "#d33682";
      color6 = "#2aa198";
      color7 = "#eee8d5";

      color8 = "#002b36";
      color9 = "#cb4b16";
      color10 = "#586e75";
      color11 = "#657b83";
      color12 = "#839496";
      color13 = "#6c71c4";
      color14 = "#93a1a1";
      color15 = "#fdf6e3";
    };
  };

  programs.alacritty = {
    enable = true;
    settings = {
      window = {
        decorations = "None";
        padding = {
          x = 12;
          y = 12;
        };
        opacity = 1.0;
      };

      # 限制终端回滚缓冲区，最多保留 3023 行历史输出。
      scrolling.history = 3023;

      font = {
        size = monoFontPointSize;
        normal.family = monoFontFamily;
        bold.family = monoFontFamily;
        italic.family = monoFontFamily;
        bold_italic.family = monoFontFamily;
      };

      cursor = {
        style = {
          shape = "Block";
          blinking = "On";
        };
        blink_interval = 500;
        unfocused_hollow = true;
      };

      mouse.hide_when_typing = true;
      selection.save_to_clipboard = false;
      bell.duration = 0;

      # 原主题文件已内联，避免配置依赖仓库外的可变文件。
      colors = {
        primary = {
          background = "#ffffff";
          foreground = "#2a2a2a";
        };
        selection = {
          text = "#2a2a2a";
          background = "#d6d7dc";
        };
        cursor = {
          text = "#ffffff";
          cursor = "#2b303c";
        };
        normal = {
          black = "#2a2a2a";
          red = "#793044";
          green = "#215f2a";
          yellow = "#999326";
          blue = "#2c313f";
          magenta = "#60636a";
          cyan = "#2b303c";
          white = "#222223";
        };
        bright = {
          black = "#6e6f71";
          red = "#b26377";
          green = "#3f8c4a";
          yellow = "#a5a031";
          blue = "#747a8c";
          magenta = "#60636a";
          cyan = "#42464e";
          white = "#bbbcbf";
        };
      };

      keyboard.bindings = [
        {
          key = "C";
          mods = "Control|Shift";
          action = "Copy";
        }
        {
          key = "V";
          mods = "Control|Shift";
          action = "Paste";
        }
        {
          key = "N";
          mods = "Control|Shift";
          action = "SpawnNewInstance";
        }
        {
          key = "Equals";
          mods = "Control|Shift";
          action = "IncreaseFontSize";
        }
        {
          key = "Minus";
          mods = "Control";
          action = "DecreaseFontSize";
        }
        {
          key = "Key0";
          mods = "Control";
          action = "ResetFontSize";
        }
        {
          key = "Enter";
          mods = "Shift";
          chars = "\n";
        }
      ];
    };
  };

  programs.foot = {
    enable = true;
    settings.main.font = "${monoFontFamily}:size=${toString monoFontPointSize}";
  };

}
