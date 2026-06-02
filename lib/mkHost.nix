# lib/mkHost.nix
#
# Turns one entry of `topology.hosts` into a complete NixOS module.
#
# The same function is used in two contexts that differ only by `baseIndex`:
#
#   * real deployment (libvirt / nixos-rebuild): baseIndex = 0, so the first
#     NIC is `eth0`.  Interface names are forced to the predictable ethN scheme
#     via the `net.ifnames=0` kernel parameter.
#
#   * the NixOS integration test: baseIndex = 1, because the test driver wires
#     the first VLAN of a node to `eth1` (it reserves eth0).
#
# Everything else - addressing, routing, firewall, services - is identical, so
# what the test exercises is exactly what gets deployed.
{ lib, topology }:

{ hostName, baseIndex ? 0 }:

{ config, pkgs, ... }:

let
  host = topology.hosts.${hostName};

  # interface name for the i-th entry of host.nets
  ifaceOf = i: "eth${toString (baseIndex + i)}";

  # logical network name -> interface name, e.g. { edge = "eth0"; app = "eth1"; }
  ifaces = lib.listToAttrs (
    lib.imap0 (i: n: { name = n.net; value = ifaceOf i; }) host.nets
  );

  # per-interface IPv4 address configuration
  interfaceAddrs = lib.listToAttrs (
    lib.imap0 (i: n: {
      name = ifaceOf i;
      value.ipv4.addresses = [
        { address = n.address; prefixLength = topology.networks.${n.net}.prefix; }
      ];
    }) host.nets
  );

  hasDefaultGw = host ? defaultGateway && host.defaultGateway != null;

  mkRuleset = import ./firewall.nix { inherit lib topology; };

  isGateway = host.role == "gateway";
in
{
  imports = [
    ../modules/common.nix
    ../modules/roles/${host.role}.nix
  ];

  # Make the resolved topology available to the role module without it having to
  # recompute any of this.
  _module.args.topo = { inherit topology host ifaces hostName; };

  networking.hostName = hostName;
  networking.useDHCP = false;
  networking.interfaces = interfaceAddrs;

  networking.defaultGateway = lib.mkIf hasDefaultGw {
    address = host.defaultGateway;
    interface = ifaceOf 0;
  };

  # Predictable interface names so the topology's "first NIC = eth0" assumption
  # holds on real hardware/qemu too.
  boot.kernelParams = [ "net.ifnames=0" ];

  # Only the gateway routes between segments.
  boot.kernel.sysctl."net.ipv4.ip_forward" = if isGateway then 1 else 0;

  # Replace NixOS' managed firewall with our fully-explicit ruleset.
  networking.firewall.enable = false;
  networking.nftables.enable = true;
  networking.nftables.ruleset = mkRuleset host.role;
}
