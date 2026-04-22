{ inputs, system, pkgsLib, ... }:

let
  flake = inputs.ft-nixlaunch or {};
in
{
  meta = {
    name         = "ft-nixlaunch";
    type         = "module";    # library | bundle | module | package | app
    role         = "standalone";    # parent | child | standalone
    description  = "Modern, polished Rofi application launcher for NixOS and Wayland";
    repo         = "github:FT-nixforge/ft-nixlaunch";
    provides     = [ "packages" "homeModules" "overlays" ];
    dependencies = [ "ft-nixpalette" ];
    status       = "stable";  # unstable | beta | stable | experimental | wip | deprecated
    version      = "1.0.0";
    versions     = [
      "v0.1.0"
      "v1.0.0"
    ];
  };

  packages    = flake.packages.${system} or {};
  nixosModule = null;
  homeModule  = flake.homeModules.default or flake.homeManagerModules.default or null;

  overlay = _final: prev: {
    ft-nixlaunch = (flake.packages.${prev.system} or {}).default or null;
  };
}
