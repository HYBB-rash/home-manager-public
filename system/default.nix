{ ... }:

{
  imports = [
    ./desktop.nix
    ./networking.nix
    ./services.nix
    ./hardware.nix
    ./packages.nix
    ./users.nix
  ];
}
