{ inputs, system, pkgsLib, ... }:

let
  flake = inputs.ft-nixpalette or {};
in
{
  meta = {
    name         = "ft-nixpalette";
    type         = "library";    # library | bundle | module | package | app
    role         = "parent";     # parent | child | standalone
    description  = "Base16 color theming engine";
    repo         = "github:FT-nixforge/ft-nixpalette";
    provides     = [ "nixosModules" "homeModules" "lib" ];
    dependencies = [];
    status       = "stable";     # unstable | beta | stable | experimental | wip | deprecated
    version      = "1.0.1";
    versions     = [
      "stable"
      "v1.0.1"
      "v1.1.0"
    ];
  };

  packages    = {};
  nixosModule = flake.nixosModules.default or null;
  homeModule  = flake.homeModules.default or flake.homeManagerModules.default or null;
  lib         = flake.lib or {};

  overlay = _final: _prev: {};
}
