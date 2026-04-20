# Convenience shim: returns the combined overlay for all ft-nixforge packages.
# Usage in flake outputs: overlays.default = import ./overlays { inherit inputs pkgsLib; };
{ inputs, pkgsLib }:

let
  lib = import ../lib { inherit pkgsLib inputs; };
  flakeConfigs = lib.loadFlakeConfigs ../flakes;
in
lib.mkOverlay { inherit flakeConfigs; }
