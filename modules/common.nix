# modules/common.nix
#
# Baseline configuration and hardening applied to every VM in the cluster.
# Kept deliberately small: anything role-specific lives in modules/roles/*.
{ config, pkgs, lib, ... }:

{
  # --- Boot / platform -------------------------------------------------------
  # Plain BIOS boot; suitable for libvirt/QEMU guests and the NixOS test VMs.
  boot.loader.grub.enable = lib.mkDefault true;
  boot.loader.grub.device = lib.mkDefault "/dev/vda";

  # --- Localisation ----------------------------------------------------------
  time.timeZone = "Europe/Warsaw";
  i18n.defaultLocale = "en_US.UTF-8";

  # --- Administration --------------------------------------------------------
  # SSH is the only management entry point.  Password and root login are
  # disabled; access is by key only.  The firewall additionally restricts which
  # source addresses may even reach port 22 (see lib/firewall.nix).
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  users.users.admin = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    # Replace with the real operator key(s) before deploying.  An empty list
    # means nobody can log in over SSH, which is the safe default.
    openssh.authorizedKeys.keys = [
      # "ssh-ed25519 AAAA... operator@example"
    ];
  };
  security.sudo.wheelNeedsPassword = lib.mkDefault false;

  # --- Sensible defaults / minimal attack surface ----------------------------
  documentation.enable = false;
  environment.systemPackages = with pkgs; [ vim curl ];

  # Pin a state version per the NixOS convention.
  system.stateVersion = "26.05";
}
