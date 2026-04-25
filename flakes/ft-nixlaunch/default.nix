{ inputs, system, pkgsLib, ... }:

let
  flake = inputs.ft-nixlaunch or {};
  hasAttr = attrSet: attrName: builtins.hasAttr attrName attrSet;
  safePackages = if hasAttr flake "packages" then flake.packages else {};
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

  packages    = if hasAttr safePackages system then safePackages.${system} else {};
  nixosModule = null;
  homeModule  = if hasAttr flake "homeModules" then flake.homeModules.default or null else null;

  overlay = _final: prev: {
    ft-nixlaunch = if hasAttr safePackages prev.system then (safePackages.${prev.system}.default or null) else null;
  };
}
