{ inputs, system, pkgsLib, ... }:

let
  flake = inputs.ft-nixpalette or {};
  hasAttr = attrSet: attrName: builtins.hasAttr attrName attrSet;
in
{
  meta = {
    name         = "ft-nixpalette";
    type         = "library";
    role         = "parent";
    description  = "Base16 color theming engine";
    repo         = "github:FT-nixforge/ft-nixpalette";
    provides     = [ "nixosModules" "lib" ];
    dependencies = [];
    status       = "stable";
    version      = "1.5.1";
    versions     = [ "v1.5.1" "v1.5.0" "v1.4.0" "v1.3.0" "v1.2.0" "v1.1.0" "v1.0.1" ];
  };

  packages    = {};
  nixosModule = if hasAttr flake "nixosModules" then flake.nixosModules.default or null else null;
  homeModule  = null;
  lib         = if hasAttr flake "lib" then flake.lib else {};

  overlay = _final: _prev: {};
}
