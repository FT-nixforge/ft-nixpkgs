# Convenience shim: returns aggregated package set for a given system.
# Usage (imperative Nix):
#   pkgs = import ./pkgs { inherit inputs system pkgsLib; };
{ inputs, system, pkgsLib }:

let
  lib = import ../lib { inherit pkgsLib inputs; };
  flakeConfigs = lib.loadFlakeConfigs ../flakes;
in
lib.mkPackages { inherit flakeConfigs system; }
