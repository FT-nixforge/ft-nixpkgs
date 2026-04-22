# Template for a new ft-nixforge flake integration.
#
# Workflow for standalone flakes:
#   1. Add upstream input in flake.nix: nixbar.url = "github:FT-nixforge/nixbar";
#   2. Copy this folder:  cp -r flakes/_template flakes/nixbar
#   3. Fill in every TODO in this file
#   4. Run: nix run .#gen-registry
#
# Workflow for family flakes:
#   1. Same as above but place folder inside the family dir, e.g. flakes/ft-nixpalette/nixbar/
#   2. The script auto-detects the family from the parent folder name

{ inputs, system, pkgsLib, ... }:

let
  # Replace FLAKE_NAME with the input attribute name defined in flake.nix
  flake = inputs.FLAKE_NAME;
in
{
  meta = {
    name         = "ft-FLAKE_NAME";
    type         = "module";    # library | bundle | module | package | app
    role         = "standalone"; # parent | child | standalone
    description  = "TODO: one-line description";
    repo         = "github:FT-nixforge/FLAKE_NAME";
    provides     = [ "packages" "homeModules" ];  # adjust as needed
    dependencies = [];
    status       = "unstable"; # unstable | beta | stable | experimental | wip | deprecated
    version      = "0.1.0";
    versions     = [];
  };

  packages    = flake.packages.${system} or {};
  nixosModule = flake.nixosModules.default or null;
  homeModule  = flake.homeModules.default or null;

  overlay = _final: _prev: {};
}
