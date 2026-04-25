{
  description = "FT-nixforge package registry — curated flakes for the ecosystem";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # ── FT-nixforge flakes ──────────────────────────────────────────────────
    ft-nixpalette.url = "github:FT-nixforge/ft-nixpalette";

    #ft-nixlaunch.url = "github:FT-nixforge/ft-nixlaunch";
    ft-nixlaunch.url = "github:FT-nixforge/ft-nixlaunch";
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

      # ── Flake apps ──────────────────────────────────────────────────────────
      #
      #   nix run .#add-flake -- FT-nixforge/ft-nixpalette
      #   nix run .#gen-registry
      #
      apps = forAllSystems (system:
        let pkgs = pkgsFor system; in
        {
          # Add a public GitHub flake to ft-nixpkgs.
          # Prefer using the GitHub Actions workflow instead:
          #   .github/workflows/add-flake.yml
          add-flake = {
            type    = "app";
            program = "${pkgs.writeShellApplication {
              name          = "add-flake";
              runtimeInputs = [ pkgs.curl pkgs.jq pkgs.python3 pkgs.nix ];
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

          # Scaffold a standalone flake repository next to the ft-nixpkgs checkout.
          create-flake = {
            type    = "app";
            program = "${pkgs.writeShellApplication {
              name          = "create-flake";
              runtimeInputs = [ pkgs.git pkgs.jq pkgs.gum ];
              text          = ''
                FT_REPO_ROOT="''${FT_REPO_ROOT:-$PWD}"
                export FT_REPO_ROOT
                exec bash ${./scripts/create-flake.sh} "$@"
              '';
            }}/bin/create-flake";
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
              pkgs.gum
              pkgs.git
              pkgs.nix
            ];
            shellHook = ''
              echo "ft-nixpkgs dev shell — available commands:"
              echo "  bash scripts/add-flake.sh <repo>     # add a flake (or use the GH Actions workflow)"
              echo "  bash scripts/gen-registry.sh         # regenerate registry"
              echo "  bash scripts/create-flake.sh         # scaffold a standalone flake repo"
            '';
          };
        });
    };
}
