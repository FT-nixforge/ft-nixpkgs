{ inputs, system, pkgsLib, ... }:

let
  flake = inputs.ft-nixpalette;
in
{
  meta = {
    name         = "ft-nixpalette";
    type         = "library";    # library | bundle | module | package | app
    role         = "standalone";    # parent | child | standalone
    description  = "Base16 color theming engine";
    repo         = "github:FT-nixforge/ft-nixpalette";
    provides     = [ "nixosModules" "lib" ];
    dependencies = [  ];
    version      = "1.5.1";
  };

  packages    = {};
  nixosModule = flake.nixosModules.default or null;
  homeModule  = null;
  lib         = flake.lib or {};

  overlay = _final: prev: {
    ft-nixpalette = (flake.packages.${prev.system} or {}).default or null;
  };
}
