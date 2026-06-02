# modules/roles/cache.nix
#
# Cache tier: Redis.
#
# Two defences are layered here, on purpose:
#   1. Network:  the firewall only admits the web tier's app-side address on
#      6379 (lib/firewall.nix `cache`).
#   2. Service:  Redis is bound to its app-side interface (never the data side
#      or a wildcard) AND requires a password.
#
# Point 2 matters because Redis ships with *no authentication* by default and
# its `protected-mode` is easily defeated once it is bound to a routable
# address.  An exposed, password-less Redis is one of the most common real
# breaches; binding + auth + the firewall together make that mistake hard.
{ config, pkgs, lib, topo, ... }:

{
  services.redis.servers."" = {
    enable = true;
    bind = "127.0.0.1 ${topo.topology.addr.cache}";
    port = topo.topology.ports.redis;
    # Demo credential.  On the real server provide this out-of-band, e.g. via
    # `requirePassFile`, and never commit it.
    requirePass = "change-me-redis";
  };
}
