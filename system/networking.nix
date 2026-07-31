{ ... }:

{
  # 此桌面通过 NetworkManager 管理网络，并关闭 Wi-Fi 省电以提高连接稳定性。
  networking.networkmanager = {
    enable = true;
    wifi.powersave = false;
  };
  networking.firewall.allowedTCPPorts = [ ];
}
