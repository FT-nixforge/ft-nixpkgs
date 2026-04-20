# ft-nixpkgs — Ideas & Improvement Backlog

Collected analysis of potential improvements: new features and architectural
ideas. Roughly ordered by impact within each section.

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
