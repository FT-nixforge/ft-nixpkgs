# Convenience shim: returns all aggregated NixOS modules.
# The `default` key imports every individual module at once.
{ inputs, pkgsLib }:

let
  lib = import ../../lib { inherit pkgsLib inputs; };
  flakeConfigs = lib.loadFlakeConfigs ../../flakes;
in
lib.mkNixosModules { inherit flakeConfigs; }
