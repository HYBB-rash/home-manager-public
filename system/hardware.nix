{ pkgs, ... }:

{
  # 使用 systemd-boot 管理 EFI 启动项。
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # 使用 nixpkgs 当前提供的最新内核系列。
  boot.kernelPackages = pkgs.linuxPackages_latest;
  boot.kernelModules = [ "ntsync" ];

  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };

  # 启用 BlueZ；Plasma 会据此安装并使用原生的 Bluedevil 管理界面。
  hardware.bluetooth.enable = true;

  hardware.logitech.wireless.enable = true;
  hardware.logitech.wireless.enableGraphical = true;

  services.logiops = {
    enable = true;

    config.devices = [
      {
        name = "Wireless Mouse MX Master 3";
        dpi = 1500;

        smartshift = {
          on = true;
          threshold = 15;
        };

        hiresscroll = {
          hires = true;
          invert = false;
          target = false;
        };
      }
    ];
  };

  # 从休眠恢复后重启罗技设备服务，避免鼠标功能失效。
  powerManagement.resumeCommands = ''
    ${pkgs.coreutils}/bin/sleep 2
    ${pkgs.systemd}/bin/systemctl restart logid.service
  '';

}
