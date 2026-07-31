{
  pkgs,
  codexDesktop,
  codexCli,
}:

let
  codexLinuxIdentityBootstrap = pkgs.writeText "codex-linux-identity-bootstrap.js" (
    builtins.readFile ./bootstrap.js
  );

  codexDesktopRuntimeIdentity = pkgs.symlinkJoin {
    name = "codex-desktop-runtime-identity-${codexDesktop.version}";
    paths = [ codexDesktop ];
    nativeBuildInputs = [ pkgs.asar ];
    postBuild = ''
      electron_path="$out/opt/codex-desktop/electron"
      resources_dir="$out/opt/codex-desktop/resources"
      extracted_dir="$TMPDIR/app-extracted"

      # Electron resolves its default resources directory from the real
      # executable path. Keep a real executable in this output so it loads
      # the identity-aware app.asar below instead of the upstream one.
      cp --reflink=auto --remove-destination \
        "${codexDesktop}/opt/codex-desktop/electron" \
        "$electron_path"

      asar extract "$resources_dir/app.asar" "$extracted_dir"
      install -Dm0644 \
        "${codexLinuxIdentityBootstrap}" \
        "$extracted_dir/codex-linux-identity-bootstrap.js"
      substituteInPlace "$extracted_dir/package.json" \
        --replace-fail \
          '"main": ".vite/build/early-bootstrap.js"' \
          '"main": "codex-linux-identity-bootstrap.js"'

      main_bundle="$(grep -l -- \
        'n.setToolTip(l.app.getName())' \
        "$extracted_dir"/.vite/build/main-*.js)"
      if [ ! -f "$main_bundle" ]; then
        echo "Expected exactly one Codex Desktop main bundle with the tray tooltip pattern" >&2
        exit 1
      fi
      substituteInPlace "$main_bundle" \
        --replace-fail \
          'i=l.nativeImage.createFromPath(l.app.isPackaged?' \
          'i=process.env.CODEX_LINUX_TRAY_ICON?l.nativeImage.createFromPath(process.env.CODEX_LINUX_TRAY_ICON):l.nativeImage.createFromPath(l.app.isPackaged?' \
        --replace-fail \
          'n.setToolTip(l.app.getName())' \
          'n.setToolTip(process.env.CODEX_LINUX_APP_DISPLAY_NAME||l.app.getName())'

      rm -f "$resources_dir/app.asar"
      rm -rf "$resources_dir/app.asar.unpacked"
      (cd "$extracted_dir" && find . -type f | LC_ALL=C sort | sed 's#^\./##') \
        > "$TMPDIR/app.asar.ordering"
      asar pack "$extracted_dir" "$resources_dir/app.asar" \
        --ordering "$TMPDIR/app.asar.ordering" \
        --unpack "{*.node,*.so,*.dylib}"
    '';
  };

  codexDesktopIcons =
    pkgs.runCommand "codex-desktop-icons" { nativeBuildInputs = [ pkgs.imagemagick ]; }
      ''
        source_icon="${codexDesktop}/share/icons/hicolor/256x256/apps/codex-desktop.png"
        icon_dir="$out/share/icons/hicolor/256x256/apps"
        font="${pkgs.dejavu_fonts}/share/fonts/truetype/DejaVuSans-Bold.ttf"
        tray_mask="$TMPDIR/codex-tray-logo-mask.png"
        tray_logo="$TMPDIR/codex-tray-logo-white.png"
        mkdir -p "$icon_dir"

        magick "$source_icon" \
          -fill '#10a37f' -stroke white -strokewidth 6 -draw 'circle 202,202 202,150' \
          -fill white -stroke none -font "$font" -pointsize 60 -gravity southeast \
          -annotate +15+5 'O' "$icon_dir/codex-official.png"

        magick "$source_icon" \
          -fill '#e4572e' -stroke white -strokewidth 6 -draw 'circle 202,202 202,150' \
          -fill white -stroke none -font "$font" -pointsize 60 -gravity southeast \
          -annotate +10+5 'W' "$icon_dir/codex-wawapi.png"

        # Tray icons are rendered around 22px, so use the full surface for
        # the color distinction instead of shrinking the desktop badge.
        magick "$source_icon" -resize 240x240! \
          -background white -alpha remove -alpha off -colorspace Gray \
          -threshold 65% -negate "$tray_mask"
        magick -size 240x240 xc:white "$tray_mask" \
          -alpha off -compose CopyOpacity -composite "$tray_logo"
        magick -size 240x240 canvas:none \
          -fill '#10a37f' -draw 'roundrectangle 8,8 232,232 48,48' \
          "$tray_logo" -compose over -composite \
          "$icon_dir/codex-official-tray.png"
        magick -size 240x240 canvas:none \
          -fill '#e4572e' -draw 'roundrectangle 8,8 232,232 48,48' \
          "$tray_logo" -compose over -composite \
          "$icon_dir/codex-wawapi-tray.png"
      '';

  mkCodexDesktopVariant =
    {
      appId,
      displayName,
    }:
    pkgs.symlinkJoin {
      name = "${appId}-${codexDesktop.version}";
      paths = [ codexDesktopRuntimeIdentity ];
      postBuild = ''
        cp --remove-destination \
          "${codexDesktopRuntimeIdentity}/opt/codex-desktop/start.sh" \
          "$out/opt/codex-desktop/start.sh"
        chmod u+w "$out/opt/codex-desktop/start.sh"
        substituteInPlace "$out/opt/codex-desktop/start.sh" \
          --replace-fail 'CODEX_LINUX_APP_ID=codex-desktop' 'CODEX_LINUX_APP_ID=${appId}' \
          --replace-fail 'CODEX_LINUX_APP_DISPLAY_NAME=ChatGPT' \
            "CODEX_LINUX_APP_DISPLAY_NAME=${pkgs.lib.escapeShellArg displayName}"

        cp --remove-destination \
          "${codexDesktopRuntimeIdentity}/bin/codex-desktop" \
          "$out/bin/codex-desktop"
        chmod u+w "$out/bin/codex-desktop"
        substituteInPlace "$out/bin/codex-desktop" \
          --replace-fail \
            "${codexDesktop}/opt/codex-desktop/start.sh" \
            "$out/opt/codex-desktop/start.sh"

        rm -f \
          "$out/share/applications/codex-desktop.desktop" \
          "$out/share/icons/hicolor/256x256/apps/codex-desktop.png"
        install -Dm0644 \
          "${codexDesktopIcons}/share/icons/hicolor/256x256/apps/${appId}.png" \
          "$out/opt/codex-desktop/.codex-linux/${appId}.png"
        install -Dm0644 \
          "${codexDesktopIcons}/share/icons/hicolor/256x256/apps/${appId}-tray.png" \
          "$out/opt/codex-desktop/.codex-linux/${appId}-tray.png"
        mkdir -p "$out/opt/codex-desktop/.codex-linux/env.d"
        printf '%s\n' \
          "CODEX_LINUX_TRAY_ICON=$out/opt/codex-desktop/.codex-linux/${appId}-tray.png" \
          > "$out/opt/codex-desktop/.codex-linux/env.d/50-tray-identity"
      '';
    };

  mkCodexLauncher =
    {
      name,
      desktopPackage,
      codexHome,
      webviewPort,
    }:
    let
      launchCommand = pkgs.lib.escapeShellArgs [ "${desktopPackage}/bin/codex-desktop" ];
    in
    pkgs.writeShellApplication {
      inherit name;

      text = ''
        export CODEX_HOME="$HOME/${codexHome}"
        export CODEX_CLI_PATH="${codexCli}"
        export CODEX_WEBVIEW_PORT="${toString webviewPort}"

        exec ${pkgs.direnv}/bin/direnv exec "$HOME/Agent/Codex" ${launchCommand} "$@"
      '';
    };

  codexOfficialDesktop = mkCodexDesktopVariant {
    appId = "codex-official";
    displayName = "Codex (Official)";
  };

  codexWawapiDesktop = mkCodexDesktopVariant {
    appId = "codex-wawapi";
    displayName = "Codex (WawAPI)";
  };
in
{
  official = mkCodexLauncher {
    name = "codex-official";
    desktopPackage = codexOfficialDesktop;
    codexHome = ".codex";
    webviewPort = 5175;
  };

  wawapi = mkCodexLauncher {
    name = "codex-wawapi";
    desktopPackage = codexWawapiDesktop;
    codexHome = ".codex-wawapi";
    webviewPort = 5185;
  };

  icons = codexDesktopIcons;
}
