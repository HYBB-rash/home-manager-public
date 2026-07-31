{ codexDesktopBundle, ... }:

let
  inherit (codexDesktopBundle) icons official wawapi;
in
{
  home.packages = [
    official
    wawapi
  ];

  xdg.dataFile."icons/hicolor/256x256/apps/codex-official.png".source =
    "${icons}/share/icons/hicolor/256x256/apps/codex-official.png";
  xdg.dataFile."icons/hicolor/256x256/apps/codex-wawapi.png".source =
    "${icons}/share/icons/hicolor/256x256/apps/codex-wawapi.png";

  xdg.desktopEntries = {
    codex-official = {
      name = "Codex（官方）";
      genericName = "Official Codex";
      comment = "使用 OpenAI 官方服务的 Codex";

      exec = "${official}/bin/codex-official %u";
      icon = "codex-official";

      terminal = false;
      categories = [ "Development" ];
      mimeType = [
        "x-scheme-handler/codex"
        "x-scheme-handler/codex-browser-sidebar"
      ];
      startupNotify = true;
      settings = {
        Keywords = "codex;openai;ai;coding;";
        StartupWMClass = "codex-official";
        "X-GNOME-WMClass" = "codex-official";
      };
    };

    codex-wawapi = {
      name = "Codex（WawAPI）";
      genericName = "WawAPI Codex";
      comment = "使用 WawAPI 的 Codex";

      exec = "${wawapi}/bin/codex-wawapi";
      icon = "codex-wawapi";

      terminal = false;
      categories = [ "Development" ];
      startupNotify = true;
      settings = {
        Keywords = "codex;wawapi;ai;coding;";
        StartupWMClass = "codex-wawapi";
        "X-GNOME-WMClass" = "codex-wawapi";
      };
    };
  };
}
