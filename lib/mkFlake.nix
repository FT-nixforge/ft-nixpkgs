# Flake factory — aggregates per-flake configs into unified outputs
{ pkgsLib, inputs }:

let
  # Default systems exposed so callers can extend: lib.defaultSystems ++ [ "aarch64-darwin" ]
  defaultSystems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];

  # Load all flake config functions from flakes/ (skips _template).
  # Supports two levels:
  #   flakes/<name>/default.nix          → standalone flake (key = <name>)
  #   flakes/<family>/<name>/default.nix → family flake    (key = <name>)
  loadFlakeConfigs = flakesDir:
    let
      isFlakeDir = dir: builtins.pathExists (dir + "/default.nix");

      loadEntry = entryName:
        let dir = flakesDir + "/${entryName}"; in
        if isFlakeDir dir
        then [{ name = entryName; value = import (dir + "/default.nix"); }]
        else
          # family folder — recurse one level
          let
            children  = builtins.attrNames (builtins.readDir dir);
            flakeNames = builtins.filter (n:
              n != "_template" && isFlakeDir (dir + "/${n}")
            ) children;
          in
          map (childName: {
            name  = childName;
            value = import (dir + "/${childName}/default.nix");
          }) flakeNames;

      entries  = builtins.attrNames (builtins.readDir flakesDir);
      topLevel = builtins.filter (n: n != "_template") entries;
      pairs    = builtins.concatLists (map loadEntry topLevel);
    in
    builtins.listToAttrs pairs;

  # Call a flake config function and validate the result has the required shape.
  # Throws a descriptive error if required keys are missing.
  callFlakeConfig = name: cfg: args:
    let
      result   = cfg args;
      required = [ "meta" "overlay" ];
      missing  = builtins.filter (k: !(builtins.hasAttr k result)) required;
    in
    if missing != []
    then throw "ft-nixpkgs: config for '${name}' is missing required keys: ${builtins.concatStringsSep ", " missing}"
    else result;

  # Aggregate packages for a single system
  mkPackages = { flakeConfigs, system }:
    pkgsLib.foldl' (acc: nameValue:
      let result = callFlakeConfig nameValue.name nameValue.value { inherit inputs system pkgsLib; };
      in acc // (result.packages or {})
    ) {} (pkgsLib.mapAttrsToList pkgsLib.nameValuePair flakeConfigs);

  # Extract a NixOS module from one config, warning if meta says it should exist
  _getNixosModule = name: cfg:
    let
      result   = callFlakeConfig name cfg { inherit inputs pkgsLib; system = "x86_64-linux"; };
      provides = result.meta.provides or [];
      mod      = result.nixosModule or null;
    in
    if mod == null && builtins.elem "nixosModules" provides
    then builtins.trace
      "ft-nixpkgs: WARNING: '${name}' declares nixosModules in provides but nixosModule is null — check the output attribute name in flakes/${name}/default.nix"
      null
    else mod;

  # Extract a Home Manager module from one config, warning if meta says it should exist
  _getHomeModule = name: cfg:
    let
      result   = callFlakeConfig name cfg { inherit inputs pkgsLib; system = "x86_64-linux"; };
      provides = result.meta.provides or [];
      mod      = result.homeModule or null;
    in
    if mod == null && builtins.elem "homeModules" provides
    then builtins.trace
      "ft-nixpkgs: WARNING: '${name}' declares homeModules in provides but homeModule is null — check the output attribute name in flakes/${name}/default.nix"
      null
    else mod;

  # Aggregate NixOS modules (system-agnostic)
  mkNixosModules = { flakeConfigs }:
    let
      mods = pkgsLib.filterAttrs (_: v: v != null)
        (pkgsLib.mapAttrs _getNixosModule flakeConfigs);
    in
    mods // {
      default = { imports = builtins.attrValues mods; };
    };

  # Aggregate Home Manager modules (system-agnostic)
  mkHomeModules = { flakeConfigs }:
    let
      mods = pkgsLib.filterAttrs (_: v: v != null)
        (pkgsLib.mapAttrs _getHomeModule flakeConfigs);
    in
    mods // {
      default = { imports = builtins.attrValues mods; };
    };

  # Build combined overlay; uses prev.system so it works across architectures
  mkOverlay = { flakeConfigs }:
    final: prev:
      pkgsLib.foldl' (acc: nameValue:
        let result = callFlakeConfig nameValue.name nameValue.value
              { inherit inputs pkgsLib; system = prev.system; };
        in acc // ((result.overlay or (_f: _p: {})) final prev)
      ) {} (pkgsLib.mapAttrsToList pkgsLib.nameValuePair flakeConfigs);

  # Produce the full flake outputs attrset.
  # Pass systems = lib.defaultSystems ++ [ "aarch64-darwin" ] to extend.
  mkAggregatedOutputs = { flakeConfigs, systems ? defaultSystems }:
    {
      packages     = pkgsLib.genAttrs systems (system: mkPackages { inherit flakeConfigs system; });
      nixosModules = mkNixosModules { inherit flakeConfigs; };
      homeModules  = mkHomeModules  { inherit flakeConfigs; };
      overlays.default = mkOverlay  { inherit flakeConfigs; };
    };

in
{
  inherit defaultSystems loadFlakeConfigs callFlakeConfig
          mkPackages mkNixosModules mkHomeModules mkOverlay mkAggregatedOutputs;
}
