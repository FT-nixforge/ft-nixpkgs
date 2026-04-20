# Registry — reads from the generated registry.json (single source of truth).
# registry.json is produced by: python scripts/gen-registry.py
# Never edit registry.json or registry.yaml by hand; edit the meta blocks in
# flakes/*/default.nix and re-run the generator.
{ inputs, pkgsLib }:

let
  # Parse registry.json exactly once — all attrs below close over the same
  # `data` binding so builtins.fromJSON is never called more than once per
  # evaluation.  Keep these three lines together; don't inline the fromJSON call
  # into individual attrs or the parse will be duplicated.
  data     = builtins.fromJSON (builtins.readFile ./registry.json);
  flakes   = data.flakes;
  families = data.families;

  # Emit a trace warning when registry.json was written by an incompatible
  # version of gen-registry.py.  Evaluates to null in both branches so it can
  # be forced with builtins.seq without changing the returned attrset.
  _schemaCheck =
    let ver = data.schemaVersion or 0; in
    if ver != 1
    then builtins.trace
      "ft-nixpkgs: WARNING: registry.json has schemaVersion ${toString ver} (expected 1). Re-run: python scripts/gen-registry.py"
      null
    else null;

  # DFS-based acyclicity check.  Returns a visited-set attrset on success;
  # throws with a descriptive message if a cycle is found.
  # Called lazily: only forced when dependencyEdges is evaluated.
  checkNoCycles =
    let
      depMap = builtins.mapAttrs (_: f: f.dependencies or []) flakes;

      # visit name path visited
      #   name    — node being visited
      #   path    — current DFS path (list), used to reconstruct the cycle
      #   visited — attrset of fully-explored nodes (used as a bool-set)
      # Returns the updated visited-set, or throws on a back-edge.
      visit = name: path: visited:
        if visited ? ${name} then visited          # already fully explored — skip
        else if builtins.elem name path
        then throw
          "ft-nixpkgs: circular dependency detected: ${builtins.concatStringsSep " → " (path ++ [name])}"
        else
          let
            newPath   = path ++ [name];
            depNames  = depMap.${name} or [];
            afterDeps = builtins.foldl'
              # Only follow edges to flakes known in this registry
              (v: dep: if flakes ? ${dep} then visit dep newPath v else v)
              visited
              depNames;
          in
          afterDeps // { ${name} = true; };
    in
    builtins.foldl' (v: name: visit name [] v) {} (builtins.attrNames flakes);

in
# Force the schema-version warning whenever the registry attrset is evaluated.
builtins.seq _schemaCheck
{
  inherit flakes families;

  byType     = type:   pkgsLib.filterAttrs (_: f: f.type   == type)   flakes;
  byFamily   = family: pkgsLib.filterAttrs (_: f: f.family == family) flakes;
  byStatus   = status: pkgsLib.filterAttrs (_: f: f.status == status) flakes;
  standalone = pkgsLib.filterAttrs (_: f: f.role == "standalone")     flakes;

  # Dependency graph as a list of { from, to } edges.
  # Triggers cycle detection — throws if any cycle exists.
  dependencyEdges =
    let
      edges = builtins.concatLists (builtins.attrValues (
        builtins.mapAttrs (_name: f:
          map (dep: { from = dep; to = f.name; }) (f.dependencies or [])
        ) flakes
      ));
    in
    builtins.seq checkNoCycles edges;
}
