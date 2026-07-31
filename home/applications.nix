{ config, ... }:

let
  monoFontFamily = "Maple Mono NF CN";
  monoSymbolFallback = "Symbols Nerd Font Mono";
  uiFontFamily = "Source Han Sans SC";
  fontPixelSize = 14;
  # Flatpak Thunderbird 的现有配置档案名由 profiles.ini 指定；重建档案后需同步更新这里。
  thunderbirdProfile = ".thunderbird/your-profile.default/user.js";
  onePasswordAgent = "${config.home.homeDirectory}/.1password/agent.sock";
in
{
  programs.vscode = {
    enable = true;
    profiles.default.userSettings = {
      "workbench.colorTheme" = "Solarized Light";
      "git.autofetch" = true;
      "editor.fontFamily" = "'${monoFontFamily}', '${monoSymbolFallback}'";
      "editor.fontSize" = fontPixelSize;
      "terminal.integrated.fontFamily" = "'${monoFontFamily}', '${monoSymbolFallback}'";
      "terminal.integrated.fontSize" = fontPixelSize;
      "debug.console.fontFamily" = "'${monoFontFamily}', '${monoSymbolFallback}'";
      "debug.console.fontSize" = fontPixelSize;
      "markdown.preview.fontFamily" = "'${uiFontFamily}'";
      "markdown.preview.fontSize" = fontPixelSize;
      "notebook.markup.fontFamily" = "'${uiFontFamily}'";
      "notebook.markup.fontSize" = fontPixelSize;
      "notebook.output.fontFamily" = "'${monoFontFamily}', '${monoSymbolFallback}'";
      "notebook.output.fontSize" = fontPixelSize;
      "chat.fontFamily" = "'${uiFontFamily}'";
      "chat.fontSize" = fontPixelSize;
      "chat.editor.fontFamily" = "'${uiFontFamily}'";
      "chat.editor.fontSize" = fontPixelSize;
    };
  };

  # Thunderbird 启动时会读取 user.js；这些是默认字体，不会覆盖邮件作者显式指定的字体。
  home.file."${thunderbirdProfile}/user.js".text = ''
    user_pref("font.default.x-western", "sans-serif");
    user_pref("font.name.monospace.x-western", "${monoFontFamily}");
    user_pref("font.name.sans-serif.x-western", "${uiFontFamily}");
    user_pref("font.name.serif.x-western", "${uiFontFamily}");
    user_pref("font.size.fixed.x-western", ${toString fontPixelSize});
    user_pref("font.size.variable.x-western", ${toString fontPixelSize});
    user_pref("font.default.zh-CN", "sans-serif");
    user_pref("font.name.monospace.zh-CN", "${monoFontFamily}");
    user_pref("font.name.sans-serif.zh-CN", "${uiFontFamily}");
    user_pref("font.name.serif.zh-CN", "${uiFontFamily}");
    user_pref("font.size.fixed.zh-CN", ${toString fontPixelSize});
    user_pref("font.size.variable.zh-CN", ${toString fontPixelSize});
  '';

  # ssh 配置
  home.sessionVariables.SSH_AUTH_SOCK = onePasswordAgent;

  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;
    settings."*" = {
      IdentityAgent = onePasswordAgent;
      ForwardAgent = false;

      AddKeysToAgent = "no";

      ServerAliveInterval = 30;
      ServerAliveCountMax = 5;
    };
  };
}
