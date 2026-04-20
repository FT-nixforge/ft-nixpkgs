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
      pkgsLib     = inputs.nixpkgs.lib;
      lib         = import ./lib { inherit pkgsLib inputs; };
      flakeConfigs = lib.loadFlakeConfigs ./flakes;
    in
    lib.mkAggregatedOutputs { inherit flakeConfigs; } // {
      # ft-nixpkgs library surface: registry + all factory helpers
      lib = lib // {
        registry = import ./registry.nix { inherit inputs pkgsLib; };
      };
    };
}
