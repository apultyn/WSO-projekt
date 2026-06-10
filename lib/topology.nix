# lib/topology.nix
#
# Single source of truth for the whole project.
#
# Every other part of the codebase (host networking, nftables rulesets, the
# integration test, the libvirt management CLI and the report figures) is
# derived from the data structure defined here.  Changing the topology in one
# place changes it everywhere, which is the entire point of the declarative,
# Nix-driven approach described in the project concept.
#
# The service is a "daisy chain": gateway -> www -> cache -> db.  Each link
# between two tiers is a *separate* layer-2 segment, so that traffic between
# tiers can only ever pass through a node that is explicitly attached to both
# segments.  There is no shared broadcast domain in which, for example, the
# database could be reached directly from the public web server.
#
#   Internet ─ wan ─ gateway ─ edge ─ www ─ app ─ cache ─ data ─ db
#
rec {
  # ---------------------------------------------------------------------------
  # Networks (one attribute per layer-2 segment).
  #
  #   vlan   - VLAN id used by the NixOS test driver to wire nodes together.
  #            Re-used as a stable identifier for libvirt networks as well.
  #   cidr   - network address in CIDR form.
  #   prefix - prefix length, kept separately because several consumers need it
  #            as an integer.
  # ---------------------------------------------------------------------------
  networks = {
    # "Internet".  Uses the RFC 5737 documentation range so it can never clash
    # with a real network and is obviously non-routable in the report.
    wan  = { vlan = 9; cidr = "192.0.2.0/24"; prefix = 24; };

    edge = { vlan = 1; cidr = "10.10.0.0/24"; prefix = 24; }; # gw <-> www
    app  = { vlan = 2; cidr = "10.20.0.0/24"; prefix = 24; }; # www <-> cache
    data = { vlan = 3; cidr = "10.30.0.0/24"; prefix = 24; }; # cache <-> db
  };

  # ---------------------------------------------------------------------------
  # Hosts.
  #
  # `nets` is an *ordered* list.  The order defines which physical interface a
  # given address is bound to: the first entry becomes the host's first NIC,
  # the second entry the second NIC, and so on.  Keeping it ordered is what lets
  # us deterministically map a logical network ("app") to an interface name
  # ("eth1") both inside the NixOS test and on the real libvirt host.
  #
  # `defaultGateway` is intentionally *absent* on the cache and db tiers: they
  # have no route off their own segments and therefore cannot reach the
  # Internet at all.  This is a security property, not an oversight - see the
  # report's security analysis.
  # ---------------------------------------------------------------------------
  hosts = {
    gateway = {
      role = "gateway";
      nets = [
        { net = "wan"; address = "192.0.2.1"; }
        { net = "edge"; address = "10.10.0.1"; }
      ];
    };

    www = {
      role = "www";
      nets = [
        { net = "edge"; address = "10.10.0.10"; }
        { net = "app"; address = "10.20.0.1"; }
      ];
      # Replies to external clients and (optional) package updates leave through
      # the gateway.
      defaultGateway = "10.10.0.1";
    };

    cache = {
      role = "cache";
      nets = [
        { net = "app"; address = "10.20.0.10"; }
        { net = "data"; address = "10.30.0.1"; }
      ];
      # No default route on purpose: the cache tier is unreachable from, and
      # cannot reach, the Internet.
    };

    db = {
      role = "db";
      nets = [
        { net = "data"; address = "10.30.0.10"; }
      ];
      # No default route: the database tier is fully isolated.
    };

    # Test-only node standing in for an arbitrary host on the Internet.  It is
    # used by the integration test to probe what the outside world can see; it
    # is not deployed to the real server.
    client = {
      role = "client";
      nets = [
        { net = "wan"; address = "192.0.2.10"; }
      ];
    };
  };

  # ---------------------------------------------------------------------------
  # Named addresses and ports.
  #
  # The firewall rulesets reference these instead of hard-coding literals, so
  # the allow-matrix and the topology can never drift apart.
  # ---------------------------------------------------------------------------
  addr = {
    gatewayWan = "192.0.2.1"; # public IP that DNAT is published on
    www = "10.10.0.10"; # web server, edge side
    wwwApp = "10.20.0.1"; # web server, app side  (source of redis traffic)
    cache = "10.20.0.10"; # redis, app side
    cacheData = "10.30.0.1"; # redis, data side   (source of postgres traffic)
    db = "10.30.0.10"; # postgres, data side
    client = "192.0.2.10";
  };

  ports = {
    ssh = 22;
    http = 80;
    https = 443;
    redis = 6379;
    postgres = 5432;
  };

  # Management range allowed to reach SSH on every node.  On the real server
  # this should be tightened to a jump host / admin VPN; see the README.
  adminCidr = "10.0.0.0/8";

  # TCP ports published to the Internet (DNAT'd by the gateway to the web tier).
  publicTcpPorts = [ ports.http ports.https ];
}
