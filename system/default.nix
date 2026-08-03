{ ... }:

{
  imports = [
    ./desktop.nix
    ./networking.nix
    ./services.nix
    ./hardware.nix
    ./hermes-multiuser.nix
    ./packages.nix
    ./users.nix
  ];
}
