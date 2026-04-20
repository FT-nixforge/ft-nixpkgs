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
    in
    lib.mkAggregatedOutputs { inherit flakeConfigs; } // {
      # ft-nixpkgs library surface: registry + all factory helpers
      lib = lib // {
        registry = import ./registry.nix { inherit inputs pkgsLib; };
      };

      # ── Flake apps ──────────────────────────────────────────────────────
      #
      #   nix run .#add-flake -- FT-nixforge/nixbar
      #   nix run .#gen-registry
      #
      # Both apps default the repo root to $PWD so they work when run via
      # `nix run` from within a ft-nixpkgs checkout.
      apps = forAllSystems (system:
        let pkgs = pkgsFor system; in
        {
          # Interactive script to add a public GitHub flake to ft-nixpkgs.
          add-flake = {
            type    = "app";
            program = "${pkgs.writeShellApplication {
              name          = "add-flake";
              runtimeInputs = [ pkgs.curl pkgs.jq pkgs.python3 ];
              text          = ''
                # When run as a flake app, default the repo root to $PWD.
                # The script also honours the FT_REPO_ROOT env var directly.
                FT_REPO_ROOT="''${FT_REPO_ROOT:-$PWD}"
                export FT_REPO_ROOT
                exec bash ${./scripts/add-flake.sh} "$@"
              '';
            }}/bin/add-flake";
          };

          # Scaffold a new Nix flake with TUI-guided metadata collection.
          create-flake = {
            type    = "app";
            program = "${pkgs.writeShellApplication {
              name          = "create-flake";
              runtimeInputs = [ pkgs.git pkgs.jq ];
              text          = ''
                FT_REPO_ROOT="''${FT_REPO_ROOT:-$PWD}"
                export FT_REPO_ROOT
                exec bash ${./scripts/create-flake.sh} "$@"
              '';
            }}/bin/create-flake";
          };

          # Regenerates registry.json and registry.yaml from flakes/*/default.nix.
          gen-registry = {
            type    = "app";
            program = "${pkgs.writeShellApplication {
              name          = "gen-registry";
              runtimeInputs = [
                (pkgs.python3.withPackages (ps: [ ps.pyyaml ]))
                pkgs.nix
              ];
              text = ''
                exec python3 ${./scripts/gen-registry.py} --repo-root "$PWD" "$@"
              '';
            }}/bin/gen-registry";
          };
        });

      # ── Dev shell ────────────────────────────────────────────────────────
      #
      #   nix develop
      #
      # Provides all tools needed to work on ft-nixpkgs scripts without
      # installing anything globally.
      devShells = forAllSystems (system:
        let pkgs = pkgsFor system; in
        {
          default = pkgs.mkShell {
            packages = [
              (pkgs.python3.withPackages (ps: [ ps.pyyaml ]))
              pkgs.jq
              pkgs.curl
              pkgs.nix
            ];
            shellHook = ''
              echo "ft-nixpkgs dev shell — available commands:"
              echo "  python3 scripts/gen-registry.py          # regenerate registry"
              echo "  bash    scripts/add-flake.sh <repo>      # add a new flake"
              echo "  python3 scripts/gen-registry.py --help"
              echo "  bash    scripts/add-flake.sh --help"
            '';
          };
        });
    };
}
