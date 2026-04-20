# Registry — reads from the generated registry.json (single source of truth).
# registry.json is produced by: python scripts/gen-registry.py
# Never edit registry.json or registry.yaml by hand; edit the meta blocks in
# flakes/*/default.nix and re-run the generator.
{ inputs, pkgsLib }:

let
  data    = builtins.fromJSON (builtins.readFile ./registry.json);
  flakes  = data.flakes;
  families = data.families;
in
{
  inherit flakes families;

  byType     = type:   pkgsLib.filterAttrs (_: f: f.type   == type)   flakes;
  byFamily   = family: pkgsLib.filterAttrs (_: f: f.family == family) flakes;
  byStatus   = status: pkgsLib.filterAttrs (_: f: f.status == status) flakes;
  standalone = pkgsLib.filterAttrs (_: f: f.role == "standalone")     flakes;

  # Dependency graph as a list of { from, to } edges
  dependencyEdges =
    builtins.concatLists (builtins.attrValues (
      builtins.mapAttrs (_name: f:
        map (dep: { from = dep; to = f.name; }) (f.dependencies or [])
      ) flakes
    ));
}
