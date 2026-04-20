{ inputs, system, pkgsLib, ... }:

let
  flake = inputs.nixpalette-hyprland;
in
{
  meta = {
    name         = "ft-nixpalette-hyprland";
    type         = "bundle";    # library | bundle | module | package | app
    role         = "child";     # parent | child | standalone
    description  = "Hyprland-specific theming bundle for ft-nixpalette";
    repo         = "github:FT-nixforge/nixpalette-hyprland";
    provides     = [ "nixosModules" "homeModules" ];
    dependencies = [ "nixpalette" ];
    status       = "stable";    # experimental | wip | stable | deprecated
    version      = "1.0.0";
  };

  packages    = flake.packages.${system} or {};
  nixosModule = flake.nixosModules.default or null;
  homeModule  = flake.homeModules.default or null;

  overlay = _final: prev: {
    ft-nixpalette-hyprland = (flake.packages.${prev.system} or {}).default or null;
  };
}
