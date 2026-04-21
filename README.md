# ft-nixpkgs

Central registry and aggregator for all [FT-nixforge](https://github.com/FT-nixforge) flakes.  
One flake input — every module, package, and overlay included.

---

## Quick start

Add `ft-nixpkgs` as the **only** FT-nixforge input you need:

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url        = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager.url   = "github:nix-community/home-manager";
    ft-nixpkgs.url     = "github:FT-nixforge/ft-nixpkgs";
  };

  outputs = { nixpkgs, home-manager, ft-nixpkgs, ... }: { ... };
}
```

---

## Using modules

### All modules at once (recommended)

```nix
# NixOS configuration
{
  imports = [ ft-nixpkgs.nixosModules.default ];
}

# Home Manager configuration
{
  imports = [ ft-nixpkgs.homeModules.default ];
}
```

### Individual modules

```nix
# Pick only what you need
{
  imports = [
    ft-nixpkgs.nixosModules.nixpalette
    ft-nixpkgs.homeModules.nixprism
  ];
}
```

---

## Using the overlay

```nix
nixpkgs.overlays = [ ft-nixpkgs.overlays.default ];

# Packages are then available as:
#   pkgs.ft-nixpalette
#   pkgs.ft-nixprism
#   pkgs.ft-nixpalette-hyprland
```

---

## Available flakes

| Name | Type | Description | Status |
|------|------|-------------|--------|
| `ft-nixpalette` | library | Base16 color theming engine | stable |
| `ft-nixpalette-hyprland` | bundle | Hyprland theming bundle | stable |
| `ft-nixprism` | module | Rofi app launcher | stable |

Full registry with metadata, dependency graph, and family information: [`registry.yaml`](./registry.yaml)

---

## Adding a new flake

### Bootstrap a new standalone flake repo

For a brand-new flake that lives **outside** this repository, scaffold it next to `ft-nixpkgs`:

```bash
nix run .#create-flake
# or choose an explicit parent directory:
nix run .#create-flake -- --dir ..
```

The scaffold includes:
1. a standalone `flake.nix` with `outputs.meta`
2. starter package/module/lib files based on the selected provides
3. GitHub Actions for check, weekly `flake.lock` updates, and releases from `meta.version` / `meta.status`

### Automated (recommended)

Run the interactive script — it fetches `outputs.meta` from the upstream repo and wires everything up:

```bash
bash scripts/add-flake.sh FT-nixforge/nixbar
# or any public GitHub repo:
bash scripts/add-flake.sh some-org/some-flake
# or just the repo name (assumes FT-nixforge org):
bash scripts/add-flake.sh nixbar
```

The script will:
1. Fetch `outputs.meta` from the upstream repo
2. Create `flakes/<folder>/default.nix`
3. Patch `flake.nix` with the new input
4. Regenerate `registry.json` and `registry.yaml`

Then review, run `nix flake update <name>`, and commit.

### What the upstream repo needs

The upstream repo must export `outputs.meta` from its `flake.nix`:

```nix
meta = {
  name         = "ft-nixbar";
  type         = "module";
  role         = "standalone";
  description  = "Unified status bar for NixOS";
  repo         = "github:FT-nixforge/ft-nixbar";
  provides     = [ "packages" "homeModules" ];
  dependencies = [ "nixpalette" ];
  status       = "stable";
  version      = "0.1.0";
};
```

`status` can now reflect both release channels and lifecycle state: `unstable`, `beta`, `stable`, `experimental`, `wip`, or `deprecated`.

### Version history in registry

The registry automatically collects all upstream version tags from each flake's repository. This enables:

- **Version pinning**: Reference exact releases (e.g., `v1.0.0`, `v1.0.1`)
- **Release channels**: Use floating tags for rolling releases (e.g., `stable`, `beta`, `unstable`)  
- **Latest tracking**: The `main` branch is included when available

Each flake in `registry.json` includes a `versions` array:

```json
{
  "name": "ft-nixpalette",
  "versions": ["v1.0.1", "v1.0.0", "v0.9.0", "stable", "beta", "main"],
  ...
}
```

Consumers can pin to:
- An exact version: `inputs.ft-nixpalette.url = "github:FT-nixforge/ft-nixpalette/v1.0.1";`
- A release channel: `inputs.ft-nixpalette.url = "github:FT-nixforge/ft-nixpalette/stable";`
- The latest development version: `inputs.ft-nixpalette.url = "github:FT-nixforge/ft-nixpalette/main";`

### Family flakes

To add a flake to a family (e.g. a new `ft-nixpalette-*` variant), pass the family explicitly when registering it:

```bash
bash scripts/add-flake.sh --family ft-nixpalette FT-nixforge/nixpalette-hyprland
```

The script will automatically place it under `flakes/ft-nixpalette/<name>/`.

### Manual

1. Copy `flakes/_template` to `flakes/<name>/` (or `flakes/<family>/<name>/`)
2. Fill in the `meta` block including `repo`, `provides`, `dependencies`, etc.
3. Add the input to `flake.nix`
4. Run `bash scripts/gen-registry.sh` to update the registry and refresh changed upstream metadata

---

## Repository layout

```
ft-nixpkgs/
├── flake.nix                  # Entry point; all inputs defined here
├── flakes/                    # Per-flake integration configs
│   ├── ft-nixpalette/         # Family folder
│   │   ├── nixpalette/
│   │   └── nixpalette-hyprland/
│   ├── nixprism/              # Standalone flake
│   └── _template/             # Copy this for new flakes
├── lib/
│   ├── default.nix            # Exports all helpers
│   ├── mkFlake.nix            # Aggregation factory (handles family folders)
│   └── merge.nix              # Merge utilities
├── pkgs/default.nix           # Aggregated package set (shim)
├── modules/
│   ├── nixos/default.nix      # Aggregated NixOS modules (shim)
│   └── home/default.nix       # Aggregated Home Manager modules (shim)
├── overlays/default.nix       # Combined overlay (shim)
├── registry.json              # Generated — do not edit manually
├── registry.yaml              # Generated — do not edit manually
├── registry.nix               # Reads registry.json; exposes filter helpers
└── scripts/
    ├── add-flake.sh           # Interactive: add a flake from any public GitHub repo
    ├── create-flake.sh        # Scaffold a standalone flake repo outside ft-nixpkgs
    ├── gen-registry.sh        # Regenerate registry.json + registry.yaml
    ├── eval-meta.nix          # Nix helper used by gen-registry.sh
    └── ft-nixpkgs.example.json # Legacy metadata example mirroring outputs.meta
```

---

## Accessing the registry from Nix

```nix
# All registered flakes
ft-nixpkgs.lib.registry.flakes

# Filter by type
ft-nixpkgs.lib.registry.byType "library"

# Filter by family
ft-nixpkgs.lib.registry.byFamily "ft-nixpalette"

# Dependency graph edges
ft-nixpkgs.lib.registry.dependencyEdges
```
