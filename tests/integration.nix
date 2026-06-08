# tests/integration.nix
#
# Implements the concept's test plan ("ICMP visibility" + "nmap port checks")
# as an automated NixOS integration test.  The whole daisy chain is booted in
# QEMU, wired together exactly as the topology prescribes, and then probed to
# prove BOTH that the intended paths work AND that every other path is blocked.
#
# Run with:   nix build .#checks.x86_64-linux.integration -L
#         or: nix flake check
#
# The nodes are built from the *same* lib/mkHost.nix used for real deployment;
# only `baseIndex` differs (the test driver wires the first VLAN to eth1).
{ pkgs, lib, topology, mkHost }:

pkgs.testers.runNixOSTest {
  name = "daisy-chain-segmentation";

  nodes = builtins.mapAttrs (name: host: { ... }: {
    imports = [ (mkHost { hostName = name; baseIndex = 1; }) ];

    # Wire each node onto the VLANs of the networks it belongs to, in order.
    virtualisation.vlans = map (n: topology.networks.${n.net}.vlan) host.nets;

    # Probing tools used by the test script.
    environment.systemPackages = with pkgs; [ nmap netcat curl ];
  }) topology.hosts;

  testScript = ''
    start_all()

    # --- everything boots and the firewall is up ---------------------------
    for m in [gateway, www, cache, db, client]:
        m.wait_for_unit("multi-user.target")
        m.wait_for_unit("nftables.service")

    www.wait_for_unit("nginx.service")
    www.wait_for_open_port(80)
    www.wait_for_open_port(443)
    cache.wait_for_open_port(6379)
    db.wait_for_unit("postgresql.service")
    db.wait_for_open_port(5432)

    # --- the service works end to end through the public address -----------
    with subtest("public web is reachable through the gateway (DNAT)"):
        client.wait_until_succeeds("curl -fsS http://192.0.2.1/", timeout=60)
        out = client.succeed("curl -fsS http://192.0.2.1/")
        assert "www tier ok" in out, f"unexpected body: {out!r}"

    # --- intended internal paths are permitted -----------------------------
    with subtest("each tier can reach the next one"):
        www.succeed("nc -z -w 5 10.20.0.10 6379")        # www  -> cache:redis
        cache.succeed("nc -z -w 5 10.30.0.10 5432")      # cache -> db:postgres
        www.succeed("ping -c1 -W2 10.20.0.10")           # adjacency: www  <-> cache
        cache.succeed("ping -c1 -W2 10.30.0.10")         # adjacency: cache <-> db

    # --- the Internet cannot touch the internal tiers ----------------------
    with subtest("outside world cannot reach internal tiers directly"):
        client.fail("nc -z -w 3 10.10.0.10 80")      # web not reachable by its real IP
        client.fail("nc -z -w 3 10.20.0.10 6379")    # cache invisible
        client.fail("nc -z -w 3 10.30.0.10 5432")    # db invisible
        client.fail("ping -c1 -W2 10.30.0.10")       # not even ICMP is forwarded

    # --- no tier may skip the chain ----------------------------------------
    with subtest("tiers cannot bypass their neighbour"):
        www.fail("nc -z -w 3 10.30.0.10 5432")       # web cannot reach db
        client.fail("nc -z -w 3 10.20.0.10 6379")    # internet cannot reach cache

    # --- the database has no way out ---------------------------------------
    with subtest("database egress is denied"):
        db.fail("ping -c1 -W2 10.30.0.1")            # db-initiated traffic is dropped

    # --- nmap: only the published ports are visible from the Internet -------
    with subtest("nmap from the Internet sees only 80/443"):
        scan = client.succeed("nmap -Pn -p 22,80,443,5432,6379 192.0.2.1")
        assert "80/tcp   open" in scan, "HTTP port not visible"
        assert "443/tcp  open" in scan, "HTTPS port not visible"
        assert scan.count("open") == 2, \
            f"Unexpected numer of open ports from the Internet (not 2):\n{scan}"
  '';
}
