{ inputs, system, pkgsLib, ... }:

let
  flake = inputs.nixprism;
in
{
  meta = {
    name         = "ft-nixprism";
    type         = "module";    # library | bundle | module | package | app
    role         = "standalone"; # parent | child | standalone
    description  = "Rofi app launcher";
    repo         = "github:FT-nixforge/nixprism";
    provides     = [ "packages" "homeModules" ];
    dependencies = [ "nixpalette" ];
    status       = "stable";    # unstable | beta | stable | experimental | wip | deprecated
    version      = "1.0.0";
  };

  packages = flake.packages.${system} or {};

  # nixprism ships no NixOS module
  nixosModule = null;

  # nixprism uses homeManagerModules (not homeModules) as its output attr
  homeModule = flake.homeManagerModules.default or null;

  overlay = _final: prev: {
    ft-nixprism = (flake.packages.${prev.system} or {}).default or null;
  };
}
