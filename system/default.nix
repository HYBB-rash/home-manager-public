{ ... }:

{
  imports = [
    ./desktop.nix
    ./networking.nix
    ./services.nix
    ./hardware.nix
    ./hermes-multiuser.nix
    ./wechat-snapshot-bridge.nix
    ./packages.nix
    ./users.nix
  ];
}
