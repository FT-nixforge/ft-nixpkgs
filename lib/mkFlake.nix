# Flake factory — aggregates per-flake configs into unified outputs
{ pkgsLib, inputs }:

let
  # Load all flake config functions from flakes/ (skips _template).
  # Supports two levels:
  #   flakes/<name>/default.nix          → standalone flake (key = <name>)
  #   flakes/<family>/<name>/default.nix → family flake    (key = <name>)
  loadFlakeConfigs = flakesDir:
    let
      isFlakeDir = dir: builtins.pathExists (dir + "/default.nix");

      # Load one top-level entry: either a flake or a family folder
      loadEntry = entryName:
        let dir = flakesDir + "/${entryName}"; in
        if isFlakeDir dir
        then [{ name = entryName; value = import (dir + "/default.nix"); }]
        else
          # family folder — recurse one level
          let
            children = builtins.attrNames (builtins.readDir dir);
            flakeNames = builtins.filter (n:
              n != "_template" && isFlakeDir (dir + "/${n}")
            ) children;
          in
          map (childName: {
            name  = childName;
            value = import (dir + "/${childName}/default.nix");
          }) flakeNames;

      entries = builtins.attrNames (builtins.readDir flakesDir);
      topLevel = builtins.filter (n: n != "_template") entries;
      pairs    = builtins.concatLists (map loadEntry topLevel);
    in
    builtins.listToAttrs pairs;

  # Aggregate packages for a single system
  mkPackages = { flakeConfigs, system }:
    pkgsLib.foldl' (acc: cfg:
      acc // ((cfg { inherit inputs system pkgsLib; }).packages or {})
    ) {} (builtins.attrValues flakeConfigs);

  # Aggregate NixOS modules (system-agnostic; use x86_64-linux as dummy for evaluation)
  mkNixosModules = { flakeConfigs }:
    let
      mods = pkgsLib.filterAttrs (_: v: v != null)
        (pkgsLib.mapAttrs (_name: cfg:
          (cfg { inherit inputs pkgsLib; system = "x86_64-linux"; }).nixosModule or null
        ) flakeConfigs);
    in
    mods // {
      default = { imports = builtins.attrValues mods; };
    };

  # Aggregate Home Manager modules (system-agnostic)
  mkHomeModules = { flakeConfigs }:
    let
      mods = pkgsLib.filterAttrs (_: v: v != null)
        (pkgsLib.mapAttrs (_name: cfg:
          (cfg { inherit inputs pkgsLib; system = "x86_64-linux"; }).homeModule or null
        ) flakeConfigs);
    in
    mods // {
      default = { imports = builtins.attrValues mods; };
    };

  # Build combined overlay; uses prev.system so it works across architectures
  mkOverlay = { flakeConfigs }:
    final: prev:
      pkgsLib.foldl' (acc: cfg:
        let result = cfg { inherit inputs pkgsLib; system = prev.system; };
        in acc // ((result.overlay or (_f: _p: {})) final prev)
      ) {} (builtins.attrValues flakeConfigs);

  # Produce the full flake outputs attrset
  mkAggregatedOutputs = { flakeConfigs, systems ? [ "x86_64-linux" "aarch64-linux" ] }:
    {
      packages    = pkgsLib.genAttrs systems (system: mkPackages { inherit flakeConfigs system; });
      nixosModules = mkNixosModules { inherit flakeConfigs; };
      homeModules  = mkHomeModules  { inherit flakeConfigs; };
      overlays.default = mkOverlay { inherit flakeConfigs; };
    };

in
{
  inherit loadFlakeConfigs mkPackages mkNixosModules mkHomeModules mkOverlay mkAggregatedOutputs;
}
