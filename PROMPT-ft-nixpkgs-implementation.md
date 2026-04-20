# Prompt: Implementiere ft-nixpkgs für FT-nixforge

## Kontext

Ich betreibe eine GitHub Organisation namens **FT-nixforge** (https://github.com/FT-nixforge) mit mehreren eigenen Nix Flakes. Jedes Flake hat sein eigenes Repository.

### Existierende Flakes (eigene Repos)

| Flake | Repo | Type | Status | Beschreibung |
|-------|------|------|--------|-------------|
| ft-nixpalette | github:FT-nixforge/nixpalette | Library | ✅ Done | Base16 color theming engine |
| ft-nixpalette-hyprland | github:FT-nixforge/nixpalette-hyprland | Bundle | ✅ Done | Hyprland theming bundle |
| ft-nixprism | github:FT-nixforge/nixprism | Module | ✅ Done | Rofi app launcher |

### Geplante Flakes (Roadmap)

- ft-nixui — Shared UI Component Library
- ft-nixbar — Unified Status Bar
- ft-nixlock — Advanced Lock Screen
- ft-nixnotify — Notification Daemon
- ft-nixvault — Password Manager Launcher
- ft-nixcast — Screen Capture Tool
- ft-nixswitch — Desktop Profile Switcher
- ft-nixterm — Unified Terminal Experience
- ft-nixfont — Font Management System
- ft-nixsync — Config Synchronization
- ft-nixdev — Project Environment Bootstrapper

### Philosophy

> No flake depends on a "sub-flake" that is specific to a single DE/compositor.
> Bundle flakes (like ft-nixpalette-hyprland) are config-specific conveniences, not libraries.

---

## Ziel

Erstelle ein **ft-nixpkgs** Repository/Flake, das als zentrale Registry für alle FT-nixforge Flakes dient — ähnlich wie nixpkgs, aber nur für unsere eigenen Flakes.

### Anforderungen

1. **Zentrale Registry** — Ein einziges Flake, das alle anderen aggregiert
2. **Eigene GitHub Org** — Jedes Flake hat sein eigenes Repo unter github:FT-nixforge
3. **Discovery** — Man kann alle verfügbaren Flakes, Module und Packages entdecken
4. **Konsistenz** — Einheitliche Struktur, Versionierung, Dokumentation
5. **Binary Cache** (später) — Pre-built packages via Cachix
6. **Docusaurus Integration** — Die Doku-Site (github:FT-nixforge/community) soll ft-nixpkgs als Quelle nutzen
7. **Modulare Struktur** — Inputs und Flake-Configs in separate Dateien/Ordner

---

## Gewünschte Struktur

```
ft-nixpkgs/                    # Eigenes Repo: github:FT-nixforge/ft-nixpkgs
├── flake.nix                  # Haupt-Flake, importiert inputs & outputs
├── flake.lock
│
├── inputs.nix                 # ALLE flake inputs zentral definiert
│                              # (nixpkgs, home-manager, + alle ft-* flakes)
│
├── flakes/                    # Jede Flake hat EIGENEN Ordner mit Config
│   ├── nixpalette/
│   │   ├── default.nix        # nixpalette-spezifische Outputs
│   │   ├── packages.nix       # packages export
│   │   ├── nixos-module.nix   # nixosModule wrapper
│   │   ├── home-module.nix    # homeModule wrapper
│   │   └── overlay.nix        # overlay definition
│   │
│   ├── nixpalette-hyprland/
│   │   ├── default.nix
│   │   ├── packages.nix
│   │   ├── nixos-module.nix
│   │   ├── home-module.nix
│   │   └── overlay.nix
│   │
│   ├── nixprism/
│   │   ├── default.nix
│   │   ├── packages.nix
│   │   ├── home-module.nix
│   │   └── overlay.nix
│   │
│   └── _template/             # Template für neue Flakes
│       ├── default.nix
│       ├── packages.nix
│       ├── nixos-module.nix
│       ├── home-module.nix
│       └── overlay.nix
│
├── lib/
│   ├── default.nix            # Helper functions
│   ├── mkFlake.nix            # Flake-Factory (generiert outputs aus flakes/)
│   └── merge.nix              # Merge-Helpers für packages/modules
│
├── pkgs/
│   └── default.nix            # Aggregated package set
│
├── modules/
│   ├── nixos/
│   │   └── default.nix        # Alle NixOS Modules aggregiert
│   └── home/
│       └── default.nix        # Alle Home Manager Modules aggregiert
│
├── overlays/
│   └── default.nix            # Combined overlay
│
├── registry.nix               # Machine-readable Flake Registry
├── registry.yaml              # Human-readable Registry (für Doku)
│
├── docs/
│   └── ...                    # Docusaurus-kompatible Docs
│
└── README.md
```

---

## inputs.nix

Alle Inputs zentral in einer Datei:

```nix
# inputs.nix — zentrale Input-Definition
{
  nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  home-manager.url = "github:nix-community/home-manager";

  # FT-nixforge Flakes
  nixpalette.url = "github:FT-nixforge/nixpalette";
  nixpalette-hyprland.url = "github:FT-nixforge/nixpalette-hyprland";
  nixprism.url = "github:FT-nixforge/nixprism";

  # Geplante Flakes (auskommentiert bis verfügbar)
  # nixui.url = "github:FT-nixforge/nixui";
  # nixbar.url = "github:FT-nixforge/nixbar";
  # ...
}
```

---

## flake.nix (Hauptdatei — schlank)

```nix
{
  description = "FT-nixforge package registry — curated flakes for the ecosystem";

  # Inputs werden aus externer Datei geladen
  inputs = builtins.fromJSON (builtins.readFile ./inputs.json);
  # ODER: inputs = import ./inputs.nix;

  outputs = inputs:
    let
      lib = import ./lib { inherit inputs; };
      
      # Alle Flake-Configs aus flakes/ laden
      flakeConfigs = lib.loadFlakeConfigs ./flakes;
      
      # Aggregierte Outputs generieren
      aggregated = lib.mkAggregatedOutputs {
        inherit inputs flakeConfigs;
        systems = [ "x86_64-linux" "aarch64-linux" ];
      };
    in
    aggregated // {
      # Registry für Discovery
      lib.registry = import ./registry.nix { inherit inputs; };
      
      # Overlays
      overlays.default = import ./overlays { inherit inputs flakeConfigs; };
    };
}
```

---

## flakes/nixpalette/default.nix

```nix
# flakes/nixpalette/default.nix
# Definiert wie ft-nixpalette in ft-nixpkgs integriert wird

{ inputs, system, lib, ... }:

let
  flake = inputs.nixpalette;
in
{
  # Metadaten
  meta = {
    name = "ft-nixpalette";
    type = "library";
    family = "ft-nixpalette";
    description = "Base16 color theming engine";
  };

  # Packages
  packages = flake.packages.${system} or {};

  # NixOS Module
  nixosModule = flake.nixosModules.default or null;

  # Home Manager Module
  homeModule = flake.homeModules.default or null;

  # Lib
  lib = flake.lib or {};

  # Overlay
  overlay = final: prev: {
    ft-nixpalette = flake.packages.${prev.system}.default or null;
  };
}
```

---

## flakes/nixprism/default.nix

```nix
# flakes/nixprism/default.nix

{ inputs, system, lib, ... }:

let
  flake = inputs.nixprism;
in
{
  meta = {
    name = "ft-nixprism";
    type = "module";
    family = null;  # standalone
    description = "Rofi app launcher";
  };

  packages = flake.packages.${system} or {};
  homeModule = flake.homeManagerModules.default or null;
  nixosModule = null;  # nixprism hat kein NixOS Module

  overlay = final: prev: {
    ft-nixprism = flake.packages.${prev.system}.default or null;
  };
}
```

---

## lib/mkFlake.nix (Flake-Factory)

```nix
# lib/mkFlake.nix — Generiert Outputs aus allen Flake-Configs

{ inputs, lib }:

let
  # Lädt alle .nix Dateien aus flakes/ (außer _template)
  loadFlakeConfigs = flakesDir:
    let
      entries = builtins.attrNames (builtins.readDir flakesDir);
      flakeNames = builtins.filter (n: n != "_template" && n != "default.nix") entries;
    in
    builtins.listToAttrs (map (name: {
      inherit name;
      value = import (flakesDir + "/${name}/default.nix");
    }) flakeNames);

  # Aggregiert packages aus allen Flakes
  mkPackages = { flakeConfigs, system }:
    lib.foldl' (acc: cfg: acc // (cfg { inherit inputs system lib; }).packages or {}) {} 
      (builtins.attrValues flakeConfigs);

  # Aggregiert NixOS Modules
  mkNixosModules = { flakeConfigs }:
    let
      configs = builtins.mapAttrs (name: cfg: 
        let result = cfg { inherit inputs system lib; };
        in if result.nixosModule != null then { ${name} = result.nixosModule; } else {}
      ) flakeConfigs;
    in
    lib.foldl' (acc: mods: acc // mods) {} (builtins.attrValues configs);

  # Aggregiert Home Manager Modules
  mkHomeModules = { flakeConfigs }:
    let
      configs = builtins.mapAttrs (name: cfg:
        let result = cfg { inherit inputs system lib; };
        in if result.homeModule != null then { ${name} = result.homeModule; } else {}
      ) flakeConfigs;
    in
    lib.foldl' (acc: mods: acc // mods) {} (builtins.attrValues configs);

  # Kombiniert alles zu finalen Outputs
  mkAggregatedOutputs = { inputs, flakeConfigs, systems }:
    let
      forAllSystems = lib.genAttrs systems;
    in
    {
      packages = forAllSystems (system: mkPackages { inherit flakeConfigs system; });
      
      nixosModules = mkNixosModules { inherit flakeConfigs; } // {
        default = { imports = builtins.attrValues (mkNixosModules { inherit flakeConfigs; }); };
      };
      
      homeModules = mkHomeModules { inherit flakeConfigs; } // {
        default = { imports = builtins.attrValues (mkHomeModules { inherit flakeConfigs; }); };
      };
      
      overlays.default = final: prev: 
        lib.foldl' (acc: cfg: acc // (cfg { inherit inputs system lib; }).overlay final prev) {} 
          (builtins.attrValues flakeConfigs);
    };

in {
  inherit loadFlakeConfigs mkPackages mkNixosModules mkHomeModules mkAggregatedOutputs;
}
```

---

## registry.nix

```nix
# registry.nix — Machine-readable Flake Registry

{ inputs }:

{
  flakes = {
    nixpalette = {
      name = "ft-nixpalette";
      type = "library";
      family = "ft-nixpalette";
      role = "parent";  # parent | child | standalone
      repo = "github:FT-nixforge/nixpalette";
      description = "Base16 color theming engine";
      provides = [ "nixosModules" "homeModules" "lib" ];
      dependencies = [];
      status = "stable";
      version = "1.0.0";
      path = "flakes/nixpalette";  # Pfad in ft-nixpkgs
    };

    nixpalette-hyprland = {
      name = "ft-nixpalette-hyprland";
      type = "bundle";
      family = "ft-nixpalette";
      role = "child";
      parent = "nixpalette";
      repo = "github:FT-nixforge/nixpalette-hyprland";
      description = "Hyprland-specific theming bundle";
      provides = [ "nixosModules" "homeModules" ];
      dependencies = [ "nixpalette" ];
      status = "stable";
      version = "1.0.0";
      path = "flakes/nixpalette-hyprland";
    };

    nixprism = {
      name = "ft-nixprism";
      type = "module";
      family = null;
      role = "standalone";
      repo = "github:FT-nixforge/nixprism";
      description = "Rofi app launcher";
      provides = [ "packages" "homeManagerModules" ];
      dependencies = [ "nixpalette" ];
      status = "stable";
      version = "1.0.0";
      path = "flakes/nixprism";
    };
  };

  families = {
    ft-nixpalette = {
      parent = "nixpalette";
      children = [ "nixpalette-hyprland" ];
      description = "Theming and color management";
    };
  };

  # Hilfsfunktionen
  lib = {
    # Alle Flakes eines bestimmten Typs
    byType = type: builtins.filter (f: f.type == type) (builtins.attrValues flakes);
    
    # Alle Flakes einer Family
    byFamily = family: builtins.filter (f: f.family == family) (builtins.attrValues flakes);
    
    # Alle standalone Flakes
    standalone = builtins.filter (f: f.role == "standalone") (builtins.attrValues flakes);
    
    # Dependency Graph als Edges
    dependencyEdges = 
      let
        mkEdges = flake: map (dep: { from = dep; to = flake.name; }) flake.dependencies;
      in
      builtins.concatLists (builtins.attrValues (builtins.mapAttrs (name: flake: mkEdges flake) flakes));
  };
}
```

---

## Docusaurus Integration

Die community-Doku-Site (github:FT-nixforge/community) soll:

1. **registry.yaml** aus ft-nixpkgs lesen
2. **Dependency Graph** automatisch generieren
3. **Flake Registry** Tabelle aktualisieren
4. **Family-Struktur** visualisieren

### Sync-Script

```bash
# In community repo
nix run github:FT-nixforge/ft-nixpkgs#sync-docs -- --output docs/docs/ft-nixpkgs/
```

---

## Workflow: Neue Flake hinzufügen

1. **Neues Repo erstellen** (z.B. github:FT-nixforge/nixbar)
2. **In ft-nixpkgs:**
   ```bash
   # 1. Input hinzufügen
   # inputs.nixbar = "github:FT-nixforge/nixbar";
   
   # 2. Ordner erstellen
   mkdir -p flakes/nixbar
   
   # 3. Config schreiben (aus Template kopieren)
   cp flakes/_template/* flakes/nixbar/
   # + anpassen
   
   # 4. Registry aktualisieren
   # registry.nix + registry.yaml
   
   # 5. Commit & Push
   ```

---

## Was implementiert werden muss

### Phase 1: Grundstruktur
- [ ] Neues Repo: github:FT-nixforge/ft-nixpkgs
- [ ] `flake.nix` (schlank, importiert inputs & outputs)
- [ ] `inputs.nix` — alle existierenden Flakes als Inputs
- [ ] `flakes/` Ordner mit je einem Unterordner pro Flake
- [ ] `flakes/_template/` — Template für neue Flakes
- [ ] `lib/mkFlake.nix` — Flake-Factory
- [ ] Aggregated `packages`, `nixosModules`, `homeModules`
- [ ] `registry.nix` mit allen Flakes
- [ ] `registry.yaml` für Doku
- [ ] `README.md` mit Usage-Beispielen

### Phase 2: Integration
- [ ] Community-Doku aktualisieren (ft-nixpkgs als Quelle)
- [ ] Dependency Graph Generator auf registry.nix umstellen
- [ ] Auto-Sync Script (ft-nixpkgs → community docs)

### Phase 3: Erweiterung
- [ ] Binary Cache (Cachix)
- [ ] CI/CD für automatische Updates
- [ ] Version pinning / Release channels
- [ ] Package search interface

---

## Wichtige Design-Entscheidungen

1. **Jedes Flake bleibt eigenes Repo** — ft-nixpkgs aggregiert nur
2. **Inputs zentral** — `inputs.nix` enthält ALLE Inputs
3. **Flake-Configs modular** — Jede Flake hat eigenen Ordner in `flakes/`
4. **Family-System** — Parent-Child Beziehungen explizit deklariert
5. **Type-System** — Library, Bundle, Module, Package, App
6. **Status-Tracking** — experimental, wip, stable, deprecated
7. **Auto-Discovery** — Registry wird aus `flakes/` Ordnern generiert

---

## Aktueller Stand

- Docusaurus-Site existiert unter github:FT-nixforge/community
- 3 Flakes sind fertig (nixpalette, nixpalette-hyprland, nixprism)
- Dependency Graph wird bereits auto-generiert (aus Dateien geparst)
- ft-nixpkgs ist in der Doku als "In Progress" dokumentiert

---

## Ziel-Output

1. Ein funktionierendes `github:FT-nixforge/ft-nixpkgs` Repository
2. Ein `flake.nix` das alle existierenden Flakes aggregiert
3. Eine `inputs.nix` mit zentralen Input-Definitionen
4. Ein `flakes/` Ordner mit je einem Unterordner pro Flake
5. Eine `registry.nix` mit vollständigen Metadaten
6. Ein Sync-Mechanismus zur Community-Doku
7. Aktualisierte Docusaurus-Doku die ft-nixpkgs als Quelle nutzt

---

*Dieser Prompt sollte an eine Planning-KI übergeben werden, die einen detaillierten Implementierungsplan erstellt.*
