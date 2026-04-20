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

1. **Publish the upstream repo** under `github:FT-nixforge/<name>`

2. **Add input** to `flake.nix`:
   ```nix
   # FT-nixforge flakes
   nixbar.url = "github:FT-nixforge/nixbar";
   ```

3. **Create config file** from the template:
   ```bash
   cp -r flakes/_template flakes/nixbar
   # edit flakes/nixbar/default.nix — replace FLAKE_NAME, fill in meta
   ```

4. **Register it** in `registry.nix` and `registry.yaml`

5. Commit and push — ft-nixpkgs picks it up automatically via `loadFlakeConfigs`

---

## Repository layout

```
ft-nixpkgs/
├── flake.nix                  # Entry point; all inputs defined here
├── flakes/                    # Per-flake integration configs
│   ├── nixpalette/
│   ├── nixpalette-hyprland/
│   ├── nixprism/
│   └── _template/             # Copy this for new flakes
├── lib/
│   ├── default.nix            # Exports all helpers
│   ├── mkFlake.nix            # Aggregation factory
│   └── merge.nix              # Merge utilities
├── pkgs/default.nix           # Aggregated package set (shim)
├── modules/
│   ├── nixos/default.nix      # Aggregated NixOS modules (shim)
│   └── home/default.nix       # Aggregated Home Manager modules (shim)
├── overlays/default.nix       # Combined overlay (shim)
├── registry.nix               # Machine-readable registry (Nix)
└── registry.yaml              # Human-readable registry (YAML / Docusaurus)
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
