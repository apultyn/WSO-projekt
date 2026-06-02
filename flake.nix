{
  description = "Declarative management of VMs and the networks connecting them on NixOS (WSO 2026L)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixos-generators }:
    let
      system = "x86_64-linux";
      lib = nixpkgs.lib;
      pkgs = nixpkgs.legacyPackages.${system};

      # The single source of truth and the host builder.
      topology = import ./lib/topology.nix;
      mkHost = import ./lib/mkHost.nix { inherit lib topology; };

      # Hosts that get deployed for real (the `client` node is test-only).
      deployHosts = [ "gateway" "www" "cache" "db" ];

      # A real libvirt/QEMU guest: role config + disk/boot profile.
      mkSystem = hostName: lib.nixosSystem {
        inherit system;
        modules = [
          (mkHost { inherit hostName; baseIndex = 0; })
          ./modules/libvirt-guest.nix
        ];
      };

      # A bootable qcow2 image for the same host, built with nixos-generators.
      mkImage = hostName: nixos-generators.nixosGenerate {
        inherit system;
        format = "qcow";
        modules = [ (mkHost { inherit hostName; baseIndex = 0; }) ];
      };

      # The libvirt management CLI, packaged with its runtime dependencies.
      vmctl = pkgs.writeShellApplication {
        name = "vmctl";
        runtimeInputs = with pkgs; [ libvirt qemu coreutils gnugrep gnused gawk iproute2 ];
        text = builtins.readFile ./scripts/vmctl.sh;
      };
    in
    {
      # nixos-rebuild switch --flake .#<host> --target-host root@<ip>
      nixosConfigurations = lib.genAttrs deployHosts mkSystem;

      packages.${system} =
        (lib.listToAttrs (map (h: lib.nameValuePair "image-${h}" (mkImage h)) deployHosts))
        // {
          inherit vmctl;
          default = vmctl;
        };

      apps.${system}.vmctl = {
        type = "app";
        program = "${vmctl}/bin/vmctl";
      };

      # nix flake check  /  nix build .#checks.x86_64-linux.integration -L
      checks.${system}.integration =
        import ./tests/integration.nix { inherit pkgs lib topology mkHost; };

      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          libvirt
          qemu
          nmap
          nixpkgs-fmt
          nixos-generators.packages.${system}.default
        ];
      };

      formatter.${system} = pkgs.nixpkgs-fmt;
    };
}
