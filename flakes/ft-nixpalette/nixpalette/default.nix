{ inputs, system, pkgsLib, ... }:

let
  flake = inputs.nixpalette;
in
{
  meta = {
    name         = "ft-nixpalette";
    type         = "library";   # library | bundle | module | package | app
    role         = "parent";    # parent | child | standalone
    description  = "Base16 color theming engine";
    repo         = "github:FT-nixforge/nixpalette";
    provides     = [ "nixosModules" "homeModules" "lib" ];
    dependencies = [];
    status       = "stable";    # experimental | wip | stable | deprecated
    version      = "1.0.0";
  };

  packages    = flake.packages.${system} or {};
  nixosModule = flake.nixosModules.default or null;
  homeModule  = flake.homeModules.default or null;
  lib         = flake.lib or {};

  overlay = _final: prev: {
    ft-nixpalette = (flake.packages.${prev.system} or {}).default or null;
  };
}
