{
  config,
  lib,
  pkgs,
  ...
}:

let
  autoUpdate = pkgs.writeShellApplication {
    name = "home-manager-auto-update";
    runtimeInputs = with pkgs; [
      coreutils
      findutils
      git
      gnugrep
      gnused
      nix
      procps
      systemd
      util-linux
    ];
    text = builtins.readFile ./scripts/home-manager-auto-update.sh;
  };

  autoClean = pkgs.writeShellApplication {
    name = "home-manager-auto-clean";
    runtimeInputs = [
      pkgs.nh
      pkgs.util-linux
    ];
    text = ''
      state_root="''${XDG_STATE_HOME:-$HOME/.local/state}/home-manager-auto-update"
      mkdir -p "$state_root"
      exec 9>"$state_root/update.lock"
      if ! flock -n 9; then
        echo "Home Manager 更新事务正在运行，本周清理任务已跳过。"
        exit 0
      fi

      nh clean profile \
        "${config.home.homeDirectory}/.local/state/nix/profiles/home-manager" \
        --keep 1 \
        --keep-since 21d \
        --no-gcroots \
        --no-direnv
    '';
  };
in

{
  home.packages = [
    autoUpdate
    autoClean
  ];

  systemd.user.services.home-manager-auto-update = {
    Unit = {
      Description = "Transactionally update fast-moving Home Manager packages";
      Documentation = [ "file://${config.home.homeDirectory}/.config/home-manager/home/updates.nix" ];
      # 当前主机是配置仓库的唯一写入者；其他主机即使复用该 Home Manager
      # 配置，也不会运行更新和推送事务。
      ConditionHost = "nixos";
    };
    Service = {
      Type = "oneshot";
      ExecStart = lib.getExe autoUpdate;
      Environment = [
        "GIT_TERMINAL_PROMPT=0"
        "HOME_MANAGER_UPDATE_REPOSITORY=${config.home.homeDirectory}/.config/home-manager"
      ];
    };
  };

  systemd.user.timers.home-manager-auto-update = {
    Unit.Description = "Daily fast-moving Home Manager package update";
    Timer = {
      OnCalendar = "*-*-* 04:00:00";
      Persistent = true;
      Unit = "home-manager-auto-update.service";
    };
    Install.WantedBy = [ "timers.target" ];
  };

  systemd.user.services.home-manager-auto-clean = {
    Unit.Description = "Clean Home Manager generations older than 21 days";
    Service = {
      Type = "oneshot";
      ExecStart = lib.getExe autoClean;
    };
  };

  systemd.user.timers.home-manager-auto-clean = {
    Unit.Description = "Weekly Home Manager generation cleanup";
    Timer = {
      OnCalendar = "Sun *-*-* 05:00:00";
      Persistent = true;
      Unit = "home-manager-auto-clean.service";
    };
    Install.WantedBy = [ "timers.target" ];
  };
}
