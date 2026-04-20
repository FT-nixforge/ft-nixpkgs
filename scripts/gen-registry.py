#!/usr/bin/env python3
"""
gen-registry.py — Generate registry.yaml and registry.json from the flakes/ folder.

Folder conventions:
  flakes/<name>/default.nix              → standalone flake (no family)
  flakes/<family>/<name>/default.nix     → family member flake

The script uses `nix eval` + scripts/eval-meta.nix to extract the `meta`
attrset from each default.nix without needing real flake inputs.

Generated files (written to the repo root):
  registry.json   — machine-readable; consumed by registry.nix
  registry.yaml   — human-readable; consumed by Docusaurus community site

Usage:
  python scripts/gen-registry.py [--repo-root PATH]
"""

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

EXCLUDED = {"_template"}
SCHEMA_VERSION = 1


# ── Nix evaluation ────────────────────────────────────────────────────────────

def eval_meta(flake_path: Path, eval_nix: Path) -> "tuple[dict | None, str | None]":
    """
    Extract the meta attrset from a flake config file via `nix eval`.
    Returns (meta_dict, None) on success or (None, error_message) on failure.
    Does NOT exit — lets the caller decide how to handle errors.
    """
    result = subprocess.run(
        [
            "nix", "eval", "--json",
            "--file", str(eval_nix),
            "--arg", "flakePath", str(flake_path.resolve()),
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return None, result.stderr.strip() or f"nix eval exited with code {result.returncode}"
    try:
        return json.loads(result.stdout), None
    except json.JSONDecodeError as e:
        return None, f"invalid JSON from nix eval: {e}"


# ── Folder scanning ───────────────────────────────────────────────────────────

def scan_flakes(
    flakes_dir: Path, eval_nix: Path
) -> "tuple[dict, dict, list[str]]":
    """
    Walk flakes_dir and return (flakes_dict, families_dict, errors).

    flakes_dict   — keyed by short name (e.g. "nixpalette"), values are meta + family
    families_dict — keyed by family name (e.g. "ft-nixpalette")
    errors        — list of human-readable error strings for failed flakes
    """
    flakes: dict[str, dict] = {}
    families: dict[str, dict] = {}
    errors: list[str] = []

    for entry in sorted(flakes_dir.iterdir()):
        if not entry.is_dir() or entry.name in EXCLUDED:
            continue

        default_nix = entry / "default.nix"

        if default_nix.exists():
            # ── Standalone flake ──────────────────────────────────────────
            flake_name = entry.name
            print(f"  [{flake_name}] standalone")
            meta, err = eval_meta(default_nix, eval_nix)
            if err:
                errors.append(f"[{flake_name}] eval failed: {err}")
                continue
            meta["family"] = None
            flakes[flake_name] = meta

        else:
            # ── Family folder ─────────────────────────────────────────────
            family_name = entry.name
            print(f"  [{family_name}] family")
            family_children: list[str] = []
            family_parent: "str | None" = None

            for child in sorted(entry.iterdir()):
                if not child.is_dir() or child.name in EXCLUDED:
                    continue
                child_nix = child / "default.nix"
                if not child_nix.exists():
                    continue

                flake_name = child.name
                print(f"    [{flake_name}] member of {family_name}")
                meta, err = eval_meta(child_nix, eval_nix)
                if err:
                    errors.append(f"[{family_name}/{flake_name}] eval failed: {err}")
                    continue
                meta["family"] = family_name
                flakes[flake_name] = meta

                family_children.append(flake_name)
                if meta.get("role") == "parent":
                    family_parent = flake_name

            if family_children:
                families[family_name] = {
                    "parent":      family_parent,
                    "children":    [c for c in family_children if c != family_parent],
                    "description": _family_description(family_name, flakes, family_parent),
                }

    return flakes, families, errors


def _family_description(family_name: str, flakes: dict, parent_name: "str | None") -> str:
    if parent_name and parent_name in flakes:
        return flakes[parent_name].get("description", family_name)
    return family_name


# ── Registry data structure ───────────────────────────────────────────────────

def build_registry(flakes: dict, families: dict) -> dict:
    return {
        "schemaVersion": SCHEMA_VERSION,
        "flakes":        flakes,
        "families":      families,
    }


# ── Atomic writers ────────────────────────────────────────────────────────────

def _atomic_write(path: Path, content: str) -> None:
    """Write content to a temp file then atomically rename it to path."""
    tmp = path.with_suffix(path.suffix + ".tmp")
    try:
        tmp.write_text(content, encoding="utf-8")
        os.replace(tmp, path)
    except Exception:
        tmp.unlink(missing_ok=True)
        raise


def write_json(registry: dict, path: Path) -> None:
    content = json.dumps(registry, indent=2) + "\n"
    _atomic_write(path, content)
    print(f"  Wrote {path}")


def write_yaml(registry: dict, path: Path) -> None:
    header = (
        "# Auto-generated by scripts/gen-registry.py — do not edit manually.\n"
        "# Source of truth: flakes/*/default.nix (meta block)\n\n"
    )
    try:
        import yaml  # type: ignore
        content = header + yaml.dump(
            registry, default_flow_style=False, allow_unicode=True, sort_keys=False
        )
    except ImportError:
        # JSON is valid YAML — use it as a fallback
        content = (
            header
            + "# (PyYAML not available; output is JSON-formatted valid YAML)\n\n"
            + json.dumps(registry, indent=2)
            + "\n"
        )
        print(f"  Wrote {path} (JSON fallback — install pyyaml for pretty YAML)")
    else:
        print(f"  Wrote {path}")

    _atomic_write(path, content)


# ── Main ──────────────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--repo-root",
        default=None,
        help="Path to the ft-nixpkgs repo root (default: parent of this script's directory)",
    )
    args = parser.parse_args()

    script_dir = Path(__file__).parent
    repo_root  = Path(args.repo_root) if args.repo_root else script_dir.parent

    flakes_dir = repo_root / "flakes"
    eval_nix   = repo_root / "scripts" / "eval-meta.nix"

    if not flakes_dir.is_dir():
        print(f"ERROR: flakes/ not found at {flakes_dir}", file=sys.stderr)
        sys.exit(1)
    if not eval_nix.exists():
        print(f"ERROR: scripts/eval-meta.nix not found at {eval_nix}", file=sys.stderr)
        sys.exit(1)

    print("Scanning flakes/...")
    flakes, families, errors = scan_flakes(flakes_dir, eval_nix)

    # Write whatever succeeded, even if some flakes failed
    registry = build_registry(flakes, families)
    print("Writing registry files...")
    write_json(registry, repo_root / "registry.json")
    write_yaml(registry, repo_root / "registry.yaml")

    print(f"\nDone — {len(flakes)} flake(s), {len(families)} famil(ies).")

    if errors:
        print(f"\n{len(errors)} flake(s) failed to evaluate:", file=sys.stderr)
        for e in errors:
            print(f"  ✗ {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
