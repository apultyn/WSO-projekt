# modules/roles/client.nix
#
# Test-only node that stands in for an arbitrary host on the Internet.  It runs
# no services; the integration test uses it to probe what the outside world can
# actually reach.  It is never built for real deployment.
{ pkgs, ... }:
{
  environment.systemPackages = [ pkgs.nmap ];
}
