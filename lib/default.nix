# ft-nixpkgs library — re-exports all helpers
{ pkgsLib, inputs }:

let
  mkFlake = import ./mkFlake.nix { inherit pkgsLib inputs; };
  merge   = import ./merge.nix   { inherit pkgsLib; };
in
mkFlake // merge
