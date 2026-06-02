# modules/roles/gateway.nix
#
# The gateway carries no application service.  Its job - NAT and inter-segment
# forwarding - is expressed entirely as networking/firewall in lib/mkHost.nix
# and lib/firewall.nix.  This module exists so every role has a module and to
# document that the gateway is intentionally service-free (smaller attack
# surface on the one node exposed to the Internet).
{ ... }:
{
  # Nothing to add: see lib/firewall.nix `gateway` ruleset (DNAT + masquerade)
  # and lib/mkHost.nix (ip_forward = 1).
}
