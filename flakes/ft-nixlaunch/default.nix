{ inputs, system, pkgsLib, ... }:

let
  flake = inputs.ft-nixlaunch or {};
in
{
  meta = {
    name         = "ft-nixlaunch";
    type         = "module";
    role         = "standalone";
    description  = "Modern, polished Rofi application launcher for NixOS and Wayland";
    repo         = "github:FT-nixforge/ft-nixlaunch";
    provides     = [ "packages" "homeModules" "overlays" ];
    dependencies = [ "ft-nixpalette" ];
    status       = "stable";
    version      = "1.0.0";
    versions     = [ "v1.0.0" "v0.1.0" ];
  };

  packages    = {};
  nixosModule = null;
  homeModule  = flake.homeModules.default or null;

  overlay = _final: prev: {};
}
