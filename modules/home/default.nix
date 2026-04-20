# Convenience shim: returns all aggregated Home Manager modules.
# The `default` key imports every individual module at once.
{ inputs, pkgsLib }:

let
  lib = import ../../lib { inherit pkgsLib inputs; };
  flakeConfigs = lib.loadFlakeConfigs ../../flakes;
in
lib.mkHomeModules { inherit flakeConfigs; }
