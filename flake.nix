{
  description = "VMware guest-host clipboard bridge for Wayland";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    zig-overlay.url = "github:mitchellh/zig-overlay";
    zls-overlay.url = "github:zigtools/zls";
    zigdoc-nix.url = "github:uzaaft/zigdoc-nix";
    ziglint-nix.url = "github:uzaaft/ziglint-nix";
  };

  outputs = {
    self,
    nixpkgs,
    zig-overlay,
    zls-overlay,
    zigdoc-nix,
    ziglint-nix,
    ...
  }: let
    allSystems = ["x86_64-linux"];
    forAllSystems = f:
      nixpkgs.lib.genAttrs allSystems (system:
        f {
          pkgs = nixpkgs.legacyPackages.${system};
          inherit system;
        });
  in {
    packages = forAllSystems ({
      pkgs,
      system,
    }: let
      zig = zig-overlay.packages.${system}.master;
    in {
      default = pkgs.stdenv.mkDerivation {
        name = "scoville";
        src = ./.;
        nativeBuildInputs = [zig];

        buildPhase = ''
          export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
          export ZIG_LOCAL_CACHE_DIR=$TMPDIR/zig-cache
          zig build -Doptimize=ReleaseSafe --prefix $out
        '';

        dontInstall = true;
      };
    });

    devShells = forAllSystems ({
      pkgs,
      system,
    }: let
      zig = zig-overlay.packages.${system}.master;
      zls = zls-overlay.packages.${system}.zls;
      zigdoc = zigdoc-nix.packages.${system}.default;
      ziglint = ziglint-nix.packages.${system}.default;
    in {
      default = pkgs.mkShell {
        buildInputs = [
          zig
          zls
          zigdoc
          ziglint
        ];
      };
    });

    nixosModules.default = {
      config,
      lib,
      pkgs,
      ...
    }: let
      cfg = config.services.scoville;
    in {
      options.services.scoville = {
        enable = lib.mkEnableOption "Scoville VMware clipboard bridge for Wayland";
      };

      config = lib.mkIf cfg.enable {
        # Ensure the VMware guest kernel modules are loaded
        virtualisation.vmware.guest.enable = true;

        # TODO: add a systemd user service that runs the scoville daemon
        # once the binary is functional
      };
    };
  };
}
