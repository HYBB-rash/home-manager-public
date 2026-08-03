{ pkgs, ... }:

{
  # Fish 同时作为系统可用 Shell 和 User 的默认登录 Shell。
  programs.fish.enable = true;

  users.users.user = {
    isNormalUser = true;
    description = "user";
    extraGroups = [
      "networkmanager"
      "wheel"
      "vboxusers"
      "docker"
    ];
    shell = pkgs.fish;
  };

  security.sudo.extraRules = [
    {
      users = [ "user" ];
      commands = [
        {
          command = "/run/current-system/sw/bin/podman";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];
}
