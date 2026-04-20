# ft-nixpkgs — Ideas & Improvement Backlog

Collected analysis of potential improvements: bug fixes, stability hardening,
new features, and architectural ideas. Roughly ordered by impact within each section.

---

## Bug Fixes (should be done soon)

### `collect_manual_meta` is never defined in `add-flake.sh`
The script offers manual metadata entry if `ft-nixpkgs.json` is not found, but
calls a function that doesn't exist. The script would crash on that code path.
Fix: implement the function with `read` prompts for each field, or remove the option
and tell the user to create `ft-nixpkgs.json` themselves.

### Shell injection in the `add-flake.sh` Nix template
The description, name, and version fields from `ft-nixpkgs.json` are interpolated
directly into a Nix heredoc without escaping. A description like `"foo's "bar""` or
one containing `${...}` would produce invalid or exploitable Nix.
Fix: escape all user-supplied strings (strip/escape quotes and `${}` sequences) before
writing them into the Nix template.

### `nix eval` fails silently on bad meta blocks in `gen-registry.py`
One broken `default.nix` aborts the whole script. The script calls `sys.exit(1)` on
eval failure with no recovery path, leaving `registry.json` unchanged but also not
reporting which flake caused the error clearly.
Fix: collect per-flake errors, report them all at the end, and still write a partial
registry for the flakes that did succeed (with a non-zero exit code to signal CI failure).

### Non-atomic file writes in `gen-registry.py`
`registry.json` and `registry.yaml` are written directly. A crash mid-write leaves a
corrupt file that will break `registry.nix` (which does `builtins.readFile` at eval time).
Fix: write to a temp file then `os.replace()` (atomic rename) into the final path.

### `flake.nix` input patch falls through silently in `add-flake.sh`
If the `# ── Planned` marker is missing (e.g. user already cleaned it up), the regex
fallback tries to find `  };` before `  outputs` — but any formatting variation silently
fails and the input is never added. The script reports success anyway.
Fix: after patching, grep the result for the new input and fail loudly if not found.

---

## Stability & Correctness

### Multi-system support — remove the hardcoded systems list
`mkAggregatedOutputs` hardcodes `[ "x86_64-linux" "aarch64-linux" ]`. Users on
`aarch64-darwin` (Apple Silicon) or `x86_64-darwin` get no packages. The systems
list should be an overridable parameter:
```nix
mkAggregatedOutputs = { flakeConfigs, systems ? defaultSystems }:
```
And expose `defaultSystems` so callers can extend it:
```nix
lib.mkAggregatedOutputs { inherit flakeConfigs; systems = lib.defaultSystems ++ [ "x86_64-darwin" ]; }
```

### Validate flake config return values in `mkFlake.nix`
`cfg { ... }` is called with no guarantee the result has the expected shape. A typo
in a `default.nix` produces a cryptic Nix eval error deep in aggregation code.
Fix: after calling `cfg`, assert the result is an attrset and that at least `meta` and
`overlay` are present. Use `lib.warn` to surface missing optional keys instead of
silently returning `null`.

### Warn on null module instead of silently dropping it
`mkNixosModules` and `mkHomeModules` filter out nulls without logging. If a flake's
module is null because of a typo in the output attribute name, the module disappears
from the aggregated set with no indication of why.
Fix: if `meta.provides` says a module should exist but the value is null, emit a
`builtins.warn` or `lib.warn` to surface the mismatch.

### Circular dependency detection in the registry
`dependencyEdges` builds the graph but never validates acyclicity. A cycle (A → B → A)
would cause infinite loops in tools that consume the graph.
Fix: add a `checkNoCycles` function in `registry.nix` that implements a DFS and
throws if a cycle is detected. Call it lazily (only when the edges attr is accessed).

### Validate required fields in `ft-nixpkgs.json` inside `add-flake.sh`
The script reads `name`, `type`, `role`, etc. but never checks they are non-empty or
within the allowed value sets. An upstream repo with `"type": "wrongvalue"` would
silently produce a bad `default.nix`.
Fix: after fetching and parsing JSON, validate each field against its allowed values
and fail with a clear message listing what's wrong.

### Schema version field for forward compatibility
Neither `registry.json` nor `ft-nixpkgs.json` have a schema version. If the format
needs to change, there is no way to detect or migrate old files.
Fix: add `"$schema": "1"` (or similar) to both formats. `gen-registry.py` and
`add-flake.sh` can check this field and warn if a version mismatch is detected.

---

## Performance

### Parallelize `nix eval` calls in `gen-registry.py`
Each flake's meta is evaluated by spawning a separate `nix eval` process sequentially.
With 10+ flakes this becomes noticeably slow. Since each call is independent, they can
be parallelized with `concurrent.futures.ThreadPoolExecutor` (or `ProcessPoolExecutor`).
Expected speedup: near-linear with the number of flakes.

### Skip unchanged flakes in `gen-registry.py` (incremental mode)
Track a checksum (e.g. SHA256 of `default.nix`) per flake in a sidecar file
(`.registry-cache.json`). On re-run, skip `nix eval` for flakes whose files haven't
changed. This makes local iteration fast and reduces CI time.

### Cache the parsed registry in `registry.nix`
`registry.nix` calls `builtins.fromJSON (builtins.readFile ./registry.json)` on every
access. Nix's evaluator does memoize `import`, but explicit lazy `let` binding makes the
intent clearer and avoids accidental double-parses:
```nix
let
  data = builtins.fromJSON (builtins.readFile ./registry.json);
  flakes = data.flakes;
  families = data.families;
in { ... }  # all attrs close over the same parsed data
```
(This is mostly already done; document it explicitly so future edits don't accidentally
split the `fromJSON` call.)

### Lazy overlay application
Currently `mkOverlay` applies all flake overlays eagerly using `foldl'`. If only one
package from the overlay is needed, all overlays still run. Consider returning a list
of overlays instead of composing them, letting nixpkgs compose them lazily:
```nix
overlays = pkgsLib.mapAttrsToList (_: cfg: (cfg {...}).overlay or (_f: _p: {})) flakeConfigs;
```
Downstream users can then pick individual overlays instead of the composed one.

---

## Developer Experience

### `nix run .#add-flake` — expose the script as a flake app
Wrap `add-flake.sh` as a proper flake output so users can run it without cloning the repo:
```bash
nix run github:FT-nixforge/ft-nixpkgs#add-flake -- FT-nixforge/nixbar
```
In `flake.nix`:
```nix
apps.x86_64-linux.add-flake = {
  type = "app";
  program = "${pkgs.writeShellApplication { name = "add-flake"; ... }}/bin/add-flake";
};
```

### `nix run .#gen-registry` — expose the registry generator as a flake app
Same idea: users and CI can run `nix run .#gen-registry` without needing Python or
PyYAML installed globally — the flake provides the right environment.

### Dev shell with all tooling
Add a `devShells.default` to `flake.nix` that includes:
```nix
devShells.default = pkgs.mkShell {
  packages = [ pkgs.python3Packages.pyyaml pkgs.jq pkgs.curl pkgs.nix ];
};
```
Then contributors just run `nix develop` and everything needed for scripts is available.

### `--dry-run` flag for `add-flake.sh`
Before making any file changes, let the user preview what would happen: which files
would be created, what the input line looks like, what the registry would contain.
Useful for verifying behaviour against unknown repos before committing.

### Verbose/debug mode for `gen-registry.py` and `add-flake.sh`
Add a `-v` / `--verbose` flag that prints the full `nix eval` commands being run,
the raw JSON being parsed, and the exact file writes being performed. Invaluable for
debugging a broken flake config without guessing.

### Better error messages from `mkFlake.nix`
Nix's default error messages for missing attributes are opaque. Add explicit `throw`
with context:
```nix
cfg or (throw "ft-nixpkgs: no config found for flake '${name}'")
```
And when a config doesn't return the expected shape, surface the flake name in the error.

---

## New Features

### Dependency validation at eval time
The registry tracks `dependencies` per flake. `mkFlake.nix` could validate at load time
that every declared dependency is also present as a flake config. If nixprism declares a
dependency on `nixpalette` but `nixpalette` is missing from the configs, raise an error
early rather than discovering a broken module deep in a NixOS rebuild.

### Family-aware `default` modules
Currently `nixosModules.default` imports every module from every flake. Users who only
want one family (e.g. all `ft-nixpalette-*` modules) have no convenient handle.
Idea: generate per-family defaults:
```nix
nixosModules.ft-nixpalette = { imports = [ ...all nixpalette family modules... ]; };
homeModules.ft-nixpalette  = { ... };
```
`loadFlakeConfigs` already has family information; it just needs to be threaded into
`mkNixosModules` and `mkHomeModules`.

### `provides`-aware module key naming
Currently all modules are keyed by their short flake name (e.g. `nixpalette`). If two
families both have a flake named `core`, they'd collide. Namespace them:
```nix
nixosModules."ft-nixpalette/nixpalette" = ...;
# plus convenient aliases
nixosModules.nixpalette = nixosModules."ft-nixpalette/nixpalette";
```

### Conflict detection for overlays
When two flakes define the same package name in their overlays, the last one silently wins.
Add a detection pass in `mkOverlay` that collects all overlay keys before merging and
warns (via `builtins.trace` or `lib.warn`) about conflicts:
```nix
duplicates = lib.intersectAttrs (overlay1 final prev) (overlay2 final prev);
warnings = lib.mapAttrsToList (k: _: "overlay conflict: ${k}") duplicates;
```

### Changelog / release notes integration
Each flake's `ft-nixpkgs.json` could include a `changelog` URL or embed a `breaking`
boolean to signal breaking changes. `gen-registry.py` could output a `CHANGELOG.md`
section when a flake bumps its version, giving ft-nixpkgs a coherent release story.

### `registry diff` tool
A small script (or flake app) that compares two versions of `registry.json` and reports:
- newly added flakes
- removed flakes
- version bumps
- status changes (e.g. `wip → stable`)
Useful for PR reviews and release notes generation.

### Status-based output filtering
Don't expose `experimental` or `wip` flakes in the default aggregated outputs.
`mkAggregatedOutputs` could accept a `minStatus` parameter:
```nix
mkAggregatedOutputs { inherit flakeConfigs; minStatus = "stable"; }
```
So the `default` module only imports stable flakes, while `unstable` or `all` includes
everything. Prevents half-done flakes from breaking a user's NixOS config on import.

### `check` output for registry integrity
Add a `checks` output that runs on `nix flake check`:
- Validates registry.json schema
- Checks no circular dependencies
- Verifies every flake in the registry has a matching config in `flakes/`
- Verifies every input in `flake.nix` has a matching config in `flakes/`
This surfaces mismatches early in CI.

### Automatic `nix flake update` in CI
After `gen-registry.py` runs and commits new flake configs, trigger a second job that
runs `nix flake update` for newly added inputs and commits the updated `flake.lock`.
This makes adding a flake fully automated (merge a PR → CI adds it to the lock file).

---

## Architecture

### Move `registry.json` out of the tracked tree
`registry.json` is generated output that happens to be committed for `builtins.readFile`
to work. This creates noise in git history (every registry update = a commit).
Alternative: generate `registry.nix` directly (a plain Nix attrset file) instead of
going through JSON. Then the registry is always a proper Nix file, readable without
`fromJSON`, and diffs are clean Nix diffs rather than JSON diffs.

### Separate "wiring" from "metadata" in `default.nix` files
Each `default.nix` currently does two things: declare metadata (who I am) and wire up
outputs (how to integrate me). These could be split:
- `meta.nix` — pure data, what the script reads via `nix eval`
- `default.nix` — wiring only, imports `./meta.nix`

This makes the eval-meta step faster (only loads `meta.nix`, not the whole wiring) and
makes each file's purpose obvious.

### Replace `scripts/eval-meta.nix` with a proper Nix check
Instead of a shell script calling `nix eval` on each file individually, expose a single
Nix expression that loads all configs and returns all metas as a JSON attrset.
`gen-registry.py` then calls `nix eval` once for the entire registry, not N times.
This is faster and eliminates per-flake subprocess overhead.

### Support pinned versions / release channels
Currently all flakes follow `nixos-unstable`. Add a channel concept:
- `ft-nixpkgs/stable` — only flakes with `status = "stable"`, pinned to a specific nixpkgs rev
- `ft-nixpkgs/unstable` — everything, follows nixos-unstable

Implemented via a `release.nix` that selects a filtered view of the configs:
```nix
nix flake show github:FT-nixforge/ft-nixpkgs/stable
```

### Cachix binary cache integration
All packages in the aggregated set could be pushed to a Cachix cache in CI.
Add a GitHub Actions job that runs `nix build .#packages.x86_64-linux.*` for all
packages and pushes results. Users add `substituters = https://ft-nixforge.cachix.org`
to get pre-built binaries without compiling.
The `README.md` should document the cache URL and public key.

---

## Tooling & CI

### Validate `ft-nixpkgs.json` in upstream repos via a reusable workflow
Publish a GitHub Actions reusable workflow that FT-nixforge repos can call to
validate their `ft-nixpkgs.json` against a JSON schema on every push. This shifts
validation left — catching bad metadata before `add-flake.sh` ever runs.

### `nix flake check` in CI for ft-nixpkgs itself
Add a CI job that runs `nix flake check` on ft-nixpkgs after registry updates.
This catches broken inputs or aggregation logic before it reaches users.

### Notify on stale registry
Add a scheduled workflow (e.g. weekly) that checks if any flake in the registry has a
newer commit than what's recorded in `flake.lock`. If so, open a PR that updates the
lock and bumps the version. Keeps the registry fresh automatically.

### JSON schema for `ft-nixpkgs.json`
Publish a JSON Schema (e.g. at `scripts/ft-nixpkgs.schema.json`) that upstream repos
can reference with `"$schema": "..."`. IDEs then validate the metadata file as users
type, and `add-flake.sh` / the CI reusable workflow can validate against it with `ajv`.

---

## Documentation

### Docusaurus integration spec
The community site (`github:FT-nixforge/community`) is intended to consume `registry.yaml`.
Define the exact contract:
- Which YAML keys map to which Docusaurus doc fields
- How family grouping maps to sidebar categories
- How `dependencyEdges` is turned into a Mermaid dependency graph
- Sync frequency (on every `registry.yaml` commit vs. scheduled)

### Per-flake generated docs in `docs/`
Each upstream flake's NixOS/Home Manager module options could be extracted with
`nixosOptionsDoc` and placed in `docs/<name>/options.md`. Combined with Docusaurus,
this gives a browsable options reference for all ft-nixforge modules in one place,
similar to the NixOS manual.

### `CONTRIBUTING.md` for upstream flake authors
A guide for authors who want their flake to be ft-nixpkgs-compatible:
- How to write `ft-nixpkgs.json`
- Which flake output names are expected (`nixosModules.default`, `homeModules.default`, etc.)
- How to declare dependencies
- How to request inclusion (open an issue / run `add-flake.sh`)
- Family conventions and naming

---

## Security

### Integrity check on fetched `ft-nixpkgs.json`
`add-flake.sh` fetches JSON from an arbitrary GitHub repo over HTTPS. While TLS provides
transport security, the repo could be compromised or the file could contain carefully
crafted strings that abuse the Nix template generation.
Fix: after download, run the JSON through the schema validator before using any fields.
Also sanitise all string values (strip control chars, limit length) before interpolating
into Nix.

### Read-only confirmation prompt for external (non-FT-nixforge) repos
When the target repo is outside the `FT-nixforge` organisation, show an extra warning:
```
WARNING: This repo is not part of the FT-nixforge organisation.
         You are trusting metadata from an external source.
Continue? [y/N]
```
This makes the risk visible without blocking legitimate use.

---

*Generated from codebase audit — 2026-04-20*
