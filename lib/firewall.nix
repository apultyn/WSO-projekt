# lib/firewall.nix
#
# Generates a complete, self-contained nftables ruleset for a host, based purely
# on its role and the shared topology.  We deliberately emit the full ruleset
# rather than layering rules on top of NixOS' `networking.firewall`, because for
# a security-focused project the value is in having every accepted packet be
# explainable from a single, auditable document.
#
# Design principles (mirrored in the report):
#   * default-deny on input and forward;
#   * the database additionally has default-deny on *output* (no egress);
#   * services are reachable only from the exact neighbour that needs them
#     (least privilege), matched on source address, not just port;
#   * NAT and inter-tier forwarding live only on the gateway.
{ lib, topology }:

let
  inherit (topology) addr ports adminCidr publicTcpPorts;

  publicPortSet = "{ " + lib.concatMapStringsSep ", " toString publicTcpPorts + " }";

  # Common preamble for the input chain: loopback, conntrack and a single,
  # globally-allowed management service (SSH from the admin range).  ICMP echo
  # is permitted so that the test plan's "ICMP visibility" probes produce
  # meaningful results within a segment; it is never *forwarded* between
  # segments (see the gateway forward chain), so the outside world still cannot
  # ping internal hosts.
  inputPreamble = ''
    iif "lo" accept
    ct state established,related accept
    ct state invalid drop
    ip protocol icmp icmp type echo-request limit rate 5/second accept
    ip saddr ${adminCidr} tcp dport ${toString ports.ssh} accept
  '';

  # A minimal "endpoint" host: default-deny everywhere except its own services,
  # output open (it may initiate connections to the next tier).
  mkEndpoint = { inputRules }: ''
    table inet filter {
      chain input {
        type filter hook input priority 0; policy drop;
        ${inputPreamble}
        ${inputRules}
      }
      chain forward {
        type filter hook forward priority 0; policy drop;
      }
      chain output {
        type filter hook output priority 0; policy accept;
      }
    }
  '';

  rulesets = {
    # -------------------------------------------------------------------------
    # gateway: NAT router and the only node that forwards between segments.
    # -------------------------------------------------------------------------
    gateway = ''
      table inet filter {
        chain input {
          type filter hook input priority 0; policy drop;
          ${inputPreamble}
        }

        chain forward {
          type filter hook forward priority 0; policy drop;
          ct state established,related accept
          ct state invalid drop
          # Only published web traffic may enter from the Internet, and only to
          # the web tier.  Everything else (incl. ICMP) is dropped, so the
          # outside world cannot reach - or even ping - the internal tiers.
          ip daddr ${addr.www} tcp dport ${publicPortSet} accept
          # Allow internal hosts that DO have a default route (the web tier) to
          # reach the Internet for e.g. package updates.
          ip saddr ${addr.www} accept
        }

        chain output {
          type filter hook output priority 0; policy accept;
        }
      }

      table ip nat {
        chain prerouting {
          type nat hook prerouting priority dstnat; policy accept;
          # Publish the web service on the gateway's public address.
          ip daddr ${addr.gatewayWan} tcp dport ${publicPortSet} dnat to ${addr.www}
        }
        chain postrouting {
          type nat hook postrouting priority srcnat; policy accept;
          # Masquerade internal traffic leaving towards the Internet.
          ip saddr ${addr.www} masquerade
        }
      }
    '';

    # -------------------------------------------------------------------------
    # www: public web server.  Accepts HTTP/HTTPS; talks out to the cache.
    # -------------------------------------------------------------------------
    www = mkEndpoint {
      inputRules = ''
        # Reachable on the edge side only; source is the original client,
        # forwarded (and previously DNAT'd) by the gateway.
        tcp dport ${publicPortSet} accept
      '';
    };

    # -------------------------------------------------------------------------
    # cache: redis.  Reachable ONLY from the web tier's app-side address.
    # -------------------------------------------------------------------------
    cache = mkEndpoint {
      inputRules = ''
        ip saddr ${addr.wwwApp} tcp dport ${toString ports.redis} accept
      '';
    };

    # -------------------------------------------------------------------------
    # db: postgres.  Reachable ONLY from the cache tier, and - crucially -
    # default-deny on output, so a compromised database cannot exfiltrate data
    # or call home.  Established/related replies are still allowed.
    # -------------------------------------------------------------------------
    db = ''
      table inet filter {
        chain input {
          type filter hook input priority 0; policy drop;
          ${inputPreamble}
          ip saddr ${addr.cacheData} tcp dport ${toString ports.postgres} accept
        }
        chain forward {
          type filter hook forward priority 0; policy drop;
        }
        chain output {
          type filter hook output priority 0; policy drop;
          oif "lo" accept
          ct state established,related accept
        }
      }
    '';

    # client is a plain host with no inbound services (test-only).
    client = mkEndpoint { inputRules = ""; };
  };

in role: rulesets.${role}
