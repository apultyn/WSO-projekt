# modules/libvirt-guest.nix
#
# Extra configuration needed only when a host is built as a *real* libvirt/QEMU
# guest (as opposed to a node inside the NixOS test driver, which supplies its
# own disk/boot setup).  Imported by the flake's nixosConfigurations and image
# builders, not by the integration test.
{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [ "${modulesPath}/profiles/qemu-guest.nix" ];

  # Single virtio disk, partitioned with a root filesystem labelled "nixos".
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
    autoResize = true;
  };
  boot.growPartition = true;
  boot.loader.grub.device = lib.mkForce "/dev/vda";

  # Serial console so `virsh console <vm>` works.
  boot.kernelParams = [ "console=ttyS0,115200n8" ];
  systemd.services."serial-getty@ttyS0".enable = true;

  # virtio drivers in the initrd for disk + network.
  boot.initrd.availableKernelModules = [ "virtio_pci" "virtio_blk" "virtio_net" "virtio_scsi" ];
}
