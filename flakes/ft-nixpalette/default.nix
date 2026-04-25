{ inputs, system, pkgsLib, ... }:

let
  flake = inputs.ft-nixpalette or {};
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
    version      = "1.5.0";
    versions     = [ "stable" "v1.5.0" "v1.1.0" "v1.0.1" ];
  };

  packages    = {};
  nixosModule = flake.nixosModules.default or null;
  # NOTE: ft-nixpalette is NixOS-only as of v1.5.0.
  # Stylix runs system-wide and auto-propagates to HM via
  # stylix.homeManagerIntegration. No separate HM module.
  homeModule  = null;
  lib         = flake.lib or {};

  overlay = _final: _prev: {};
}
