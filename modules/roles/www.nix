# modules/roles/www.nix
#
# Public web tier: nginx serving a tiny demo page over HTTP and HTTPS.  In a
# real deployment this is where the application that consumes the cache and the
# database would live; for demonstrating the network/firewall design a static
# vhost is enough to give the test (and nmap) real open ports to find.
{ config, pkgs, lib, topo, ... }:

let
  # Self-signed certificate generated at build time, purely so the web tier has
  # a real TLS listener on 443.  A production deployment would use ACME or a
  # provisioned certificate instead.
  snakeoil = pkgs.runCommand "www-snakeoil" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir -p $out
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
      -subj "/CN=www" -keyout $out/key.pem -out $out/cert.pem
  '';
in
{
  services.nginx = {
    enable = true;
    virtualHosts."_" = {
      default = true;
      addSSL = true;
      sslCertificate = "${snakeoil}/cert.pem";
      sslCertificateKey = "${snakeoil}/key.pem";
      locations."/".return = ''200 "www tier ok\n"'';
      extraConfig = "default_type text/plain;";
    };
  };

  # nginx listens on 80 and 443; the firewall (lib/firewall.nix `www`) makes
  # them reachable, and only the gateway forwards/DNATs traffic to them.
}
