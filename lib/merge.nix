# Merge helpers for combining outputs across flake configs
{ pkgsLib }:

{
  # Deep-merge two package sets, right-hand side wins on conflict
  mergePackages = a: b: a // b;

  # Merge a list of package sets into one
  mergeAllPackages = pkgsLib.foldl' (acc: ps: acc // ps) {};

  # Merge two module lists (used for building combined nixosModules / homeModules)
  mergeModuleLists = a: b: a ++ b;
}
