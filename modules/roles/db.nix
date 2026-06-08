# modules/roles/db.nix
#
# Data tier: PostgreSQL holding the "ordinary" data of the concept's scenario.
#
# Defences, layered like the cache tier:
#   1. Network:  firewall admits only the cache tier on 5432, and the db has
#      NO egress at all (lib/firewall.nix `db` - output policy drop).
#   2. Service:  Postgres listens only on its data-side interface, and
#      pg_hba.conf restricts client certs/addresses to the data subnet.
#
# This is the tier the concept singles out as the candidate for "critical data"
# when the chain later grows into a tree; it is therefore the most isolated.
{ config, pkgs, lib, topo, ... }:

{
  services.postgresql = {
    enable = true;
    enableTCPIP = true;
    settings.listen_addresses = lib.mkForce "127.0.0.1,${topo.topology.addr.db}";

    # Only the cache tier's data-side address may connect, and only to the
    # application database.  scram-sha-256 password auth on top of that.
    authentication = lib.mkForce ''
      local all all                        trust
      host  app  appuser ${topo.topology.addr.cacheData}/32  scram-sha-256
    '';

    ensureDatabases = [ "app" ];
    ensureUsers = [
      {
        name = "app";
        ensureDBOwnership = true;
      }
    ];
  };
  services.postgresql.settings.password_encryption = "scram-sha-256";
}
