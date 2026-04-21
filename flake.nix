{
  description = "FT-nixforge package registry — curated flakes for the ecosystem";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # ── FT-nixforge flakes ──────────────────────────────────────────────────
    nixpalette.url          = "github:FT-nixforge/nixpalette";
    nixpalette-hyprland.url = "github:FT-nixforge/nixpalette-hyprland";
    nixprism.url            = "github:FT-nixforge/nixprism";

    # ── Planned (uncomment when the repo is published) ──────────────────────
    # nixui.url     = "github:FT-nixforge/nixui";
    # nixbar.url    = "github:FT-nixforge/nixbar";
    # nixlock.url   = "github:FT-nixforge/nixlock";
    # nixnotify.url = "github:FT-nixforge/nixnotify";
    # nixvault.url  = "github:FT-nixforge/nixvault";
    # nixcast.url   = "github:FT-nixforge/nixcast";
    # nixswitch.url = "github:FT-nixforge/nixswitch";
    # nixterm.url   = "github:FT-nixforge/nixterm";
    # nixfont.url   = "github:FT-nixforge/nixfont";
    # nixsync.url   = "github:FT-nixforge/nixsync";
    # nixdev.url    = "github:FT-nixforge/nixdev";
  };

  outputs = inputs:
    let
      pkgsLib      = inputs.nixpkgs.lib;
      lib          = import ./lib { inherit pkgsLib inputs; };
      flakeConfigs = lib.loadFlakeConfigs ./flakes;

      forAllSystems = pkgsLib.genAttrs lib.defaultSystems;
      pkgsFor       = system: import inputs.nixpkgs { inherit system; };

      # Build the create-flake tool package for a given system.
      # Exposed as packages.${system}.create-flake so it can be installed
      # globally via environment.systemPackages or home.packages.
      mkCreateFlake = system:
        let pkgs = pkgsFor system; in
        pkgs.writeShellApplication {
          name          = "create-flake";
          runtimeInputs = [ pkgs.git pkgs.jq pkgs.gum ];
          text          = builtins.readFile ./scripts/create-flake.sh;
        };
    in
    # recursiveUpdate deep-merges packages.${system} so the create-flake tool
    # sits alongside the registry packages aggregated from flakes/.
    pkgsLib.recursiveUpdate (lib.mkAggregatedOutputs { inherit flakeConfigs; }) {
      # ft-nixpkgs library surface: registry + all factory helpers
      lib = lib // {
        registry = import ./registry.nix { inherit inputs pkgsLib; };
      };

      # ── Tool packages ────────────────────────────────────────────────────
      #
      #   Install globally on NixOS:
      #     environment.systemPackages = [
      #       inputs.ft-nixpkgs.packages.x86_64-linux.create-flake
      #     ];
      #
      #   Or with home-manager:
      #     home.packages = [ inputs.ft-nixpkgs.packages.x86_64-linux.create-flake ];
      #
      packages = forAllSystems (system: {
        create-flake = mkCreateFlake system;
      });

      # ── Flake apps ──────────────────────────────────────────────────────────
      #
      #   nix run .#create-flake
      #   nix run .#add-flake -- FT-nixforge/nixbar
      #   nix run .#gen-registry
      #
      apps = forAllSystems (system:
        let pkgs = pkgsFor system; in
        {
          # Scaffold a new Nix flake with gum-powered TUI.
          # Sets FT_REPO_ROOT to $PWD so family/dep selectors are populated
          # from this checkout when invoked via `nix run`.
          create-flake = {
            type    = "app";
            program = "${pkgs.writeShellApplication {
              name          = "create-flake-app";
              runtimeInputs = [ pkgs.git pkgs.jq pkgs.gum ];
              text          = ''
                FT_REPO_ROOT="''${FT_REPO_ROOT:-$PWD}"
                export FT_REPO_ROOT
                exec ${mkCreateFlake system}/bin/create-flake "$@"
              '';
            }}/bin/create-flake-app";
          };

          # Interactive script to add a public GitHub flake to ft-nixpkgs.
          add-flake = {
            type    = "app";
            program = "${pkgs.writeShellApplication {
              name          = "add-flake";
              runtimeInputs = [ pkgs.curl pkgs.jq pkgs.python3 ];
              text          = ''
                FT_REPO_ROOT="''${FT_REPO_ROOT:-$PWD}"
                export FT_REPO_ROOT
                exec bash ${./scripts/add-flake.sh} "$@"
              '';
            }}/bin/add-flake";
          };

          # Regenerates registry.json and registry.yaml from flakes/*/default.nix.
          gen-registry = {
            type    = "app";
            program = "${pkgs.writeShellApplication {
              name          = "gen-registry";
              runtimeInputs = [ pkgs.nix pkgs.jq ];
              text = ''
                exec bash ${./scripts/gen-registry.sh} --repo-root "$PWD" "$@"
              '';
            }}/bin/gen-registry";
          };
        });

      # ── Dev shell ────────────────────────────────────────────────────────────
      #
      #   nix develop
      #
      devShells = forAllSystems (system:
        let pkgs = pkgsFor system; in
        {
          default = pkgs.mkShell {
            packages = [
              (pkgs.python3.withPackages (ps: [ ps.pyyaml ]))
              pkgs.jq
              pkgs.curl
              pkgs.nix
              pkgs.gum
            ];
            shellHook = ''
              echo "ft-nixpkgs dev shell — available commands:"
              echo "  create-flake [name]                      # scaffold a new flake"
              echo "  bash scripts/add-flake.sh <repo>         # add a flake to the registry"
              echo "  bash scripts/gen-registry.sh             # regenerate registry"
            '';
          };
        });
    };
}
