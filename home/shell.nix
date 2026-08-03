{ lib, pkgs, ... }:

{
  # 自动清理远端已删除的分支，并让首次推送的新分支自动关联同名远端分支。
  programs.git = {
    enable = true;
    lfs.enable = true;
    settings = {
      user = {
        name = "example-user";
        email = "public@example.invalid";
      };
      init.defaultBranch = "main";
      core.editor = "vim";
      fetch.prune = true;
      pull.rebase = false;
      push = {
        default = "simple";
        autoSetupRemote = true;
      };
      # GitHub HTTPS 操作统一通过 gh 的凭据存储；自动更新服务也复用此通道。
      credential."https://github.com".helper = "!${lib.getExe pkgs.gh} auth git-credential";
      # 此仓库没有 LFS 文件，不让无关的锁 API 可用性阻塞配置更新推送。
      lfs."https://github.com/example-user/home-manager.git/info/lfs".locksverify = false;
    };
    signing = {
      key = "ssh-ed25519 REPLACE_WITH_YOUR_PUBLIC_KEY";
      format = "ssh";
      signer = lib.getExe' pkgs._1password-gui "op-ssh-sign";
      signByDefault = true;
    };
  };

  programs.fish = {
    enable = true;

    shellAliases = {
      ll = "eza -lah";
      la = "eza -la";
      gs = "git status";
      nr = "nh os switch";
      hms = "nh home switch";
    };

    interactiveShellInit = ''
      set fish_greeting
      # Solarized Fish 配色
      set -g fish_color_autosuggestion 93a1a1
      set -g fish_color_cancel --reverse
      set -g fish_color_command 586e75
      set -g fish_color_comment 93a1a1
      set -g fish_color_cwd green
      set -g fish_color_cwd_root red
      set -g fish_color_end 268bd2
      set -g fish_color_error dc322f
      set -g fish_color_escape 00a6b2
      set -g fish_color_gray
      set -g fish_color_history_current --bold
      set -g fish_color_host --reset
      set -g fish_color_host_remote yellow
      set -g fish_color_keyword
      set -g fish_color_normal --reset
      set -g fish_color_operator 00a6b2
      set -g fish_color_option
      set -g fish_color_param 657b83
      set -g fish_color_quote 839496
      set -g fish_color_redirection 6c71c4
      set -g fish_color_search_match bryellow --bold --background=white
      set -g fish_color_selection white --bold --background=brblack
      set -g fish_color_status red
      set -g fish_color_user brgreen
      set -g fish_color_valid_path --underline=single

      set -g fish_pager_color_background
      set -g fish_pager_color_completion green
      set -g fish_pager_color_description B3A06D
      set -g fish_pager_color_prefix cyan --underline=single
      set -g fish_pager_color_progress brwhite --bold --background=cyan
      set -g fish_pager_color_secondary_background
      set -g fish_pager_color_secondary_completion
      set -g fish_pager_color_secondary_description
      set -g fish_pager_color_secondary_prefix
      set -g fish_pager_color_selected_background --background=white
      set -g fish_pager_color_selected_completion
      set -g fish_pager_color_selected_description
      set -g fish_pager_color_selected_prefix
    '';
  };

  programs.bash.enable = true;

  programs.starship.enable = true;
  programs.fzf.enable = true;
  programs.zoxide.enable = true;
  programs.eza.enable = true;

  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };
}
