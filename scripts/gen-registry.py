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

An incremental cache (.registry-cache.json in the repo root) stores a SHA-256
hash of each default.nix.  On re-run, flakes whose files are unchanged skip
the `nix eval` call entirely — making local iteration and CI fast.
Delete .registry-cache.json to force a full rebuild.

Usage:
  python scripts/gen-registry.py [--repo-root PATH] [--workers N]
"""

import argparse
import hashlib
import json
import os
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

EXCLUDED = {"_template"}
SCHEMA_VERSION = 1
CACHE_FILE = ".registry-cache.json"


# ── Nix evaluation ────────────────────────────────────────────────────────────


def eval_meta(flake_path: Path, eval_nix: Path) -> "tuple[dict | None, str | None]":
    """
    Extract the meta attrset from a flake config file via `nix eval`.
    Returns (meta_dict, None) on success or (None, error_message) on failure.
    Does NOT exit — lets the caller decide how to handle errors.
    """
    result = subprocess.run(
        [
            "nix",
            "eval",
            "--json",
            "--file",
            str(eval_nix),
            "--arg",
            "flakePath",
            str(flake_path.resolve()),
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return (
            None,
            result.stderr.strip() or f"nix eval exited with code {result.returncode}",
        )
    try:
        return json.loads(result.stdout), None
    except json.JSONDecodeError as e:
        return None, f"invalid JSON from nix eval: {e}"


# ── Incremental cache ─────────────────────────────────────────────────────────


def _load_cache(repo_root: Path) -> dict:
    """Load the incremental eval cache; returns {} if missing or corrupt."""
    try:
        return json.loads((repo_root / CACHE_FILE).read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def _save_cache(repo_root: Path, cache: dict) -> None:
    """Atomically write the updated cache."""
    _atomic_write(repo_root / CACHE_FILE, json.dumps(cache, indent=2) + "\n")


def _file_hash(path: Path) -> str:
    """SHA-256 digest of a file's contents."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


# ── Discovery ─────────────────────────────────────────────────────────────────


def _discover_entries(flakes_dir: Path) -> "list[tuple[str | None, str, Path]]":
    """
    Walk flakes_dir and return a sorted list of
    (family_name_or_None, flake_name, default_nix_path).
    """
    entries: list[tuple] = []
    for top in sorted(flakes_dir.iterdir()):
        if not top.is_dir() or top.name in EXCLUDED:
            continue
        top_nix = top / "default.nix"
        if top_nix.exists():
            entries.append((None, top.name, top_nix))
        else:
            family = top.name
            for child in sorted(top.iterdir()):
                if not child.is_dir() or child.name in EXCLUDED:
                    continue
                child_nix = child / "default.nix"
                if child_nix.exists():
                    entries.append((family, child.name, child_nix))
    return entries


# ── Per-entry evaluation (runs in parallel worker threads) ────────────────────


def _eval_entry(
    family: "str | None",
    name: str,
    nix_path: Path,
    eval_nix: Path,
    cache: dict,
) -> "tuple[str | None, str, Path, dict | None, str | None, str, bool]":
    """
    Evaluate one flake config, returning the cached result when the file is
    unchanged.  Thread-safe: reads only immutable inputs.
    Returns (family, name, nix_path, meta_or_None, error_or_None, file_hash, from_cache).
    """
    current_hash = _file_hash(nix_path)
    cached = cache.get(str(nix_path))
    if cached and cached.get("hash") == current_hash:
        return family, name, nix_path, cached["meta"], None, current_hash, True

    meta, err = eval_meta(nix_path, eval_nix)
    return family, name, nix_path, meta, err, current_hash, False


# ── Folder scanning ───────────────────────────────────────────────────────────


def scan_flakes(
    flakes_dir: Path,
    eval_nix: Path,
    cache: dict,
    max_workers: int = 8,
) -> "tuple[dict, dict, list[str], dict]":
    """
    Discover and evaluate all flake configs in parallel.
    Returns (flakes_dict, families_dict, errors, updated_cache).

    flakes_dict   — keyed by short name (e.g. "nixpalette"), values are meta + family
    families_dict — keyed by family name (e.g. "ft-nixpalette")
    errors        — list of human-readable error strings for failed flakes
    updated_cache — updated hash→meta mapping to persist for next run
    """
    discovered = _discover_entries(flakes_dir)

    # ── Parallel evaluation ───────────────────────────────────────────────────
    raw_results: list[tuple] = []
    with ThreadPoolExecutor(max_workers=max_workers) as pool:
        futures = {
            pool.submit(_eval_entry, family, name, nix_path, eval_nix, cache): (
                family,
                name,
            )
            for family, name, nix_path in discovered
        }
        for future in as_completed(futures):
            raw_results.append(future.result())

    # Sort for deterministic output regardless of thread completion order
    raw_results.sort(key=lambda r: (r[0] or "", r[1]))

    # ── Assemble flakes & families ────────────────────────────────────────────
    flakes: dict[str, dict] = {}
    families: dict[str, dict] = {}
    errors: list[str] = []
    new_cache: dict = {}

    for family, name, nix_path, meta, err, fhash, from_cache in raw_results:
        label = f"{family}/{name}" if family else name
        if from_cache:
            print(f"  [{label}] (cached)")
        elif family:
            print(f"  [{name}] member of {family}")
        else:
            print(f"  [{name}] standalone")

        if err:
            errors.append(f"[{label}] eval failed: {err}")
            continue

        meta["family"] = family
        flakes[name] = meta
        # Store meta without the injected 'family' key — it's derived from
        # folder structure, not from the eval output.
        new_cache[str(nix_path)] = {
            "hash": fhash,
            "meta": {k: v for k, v in meta.items() if k != "family"},
        }

        if family is not None:
            if family not in families:
                families[family] = {
                    "parent": None,
                    "children": [],
                    "description": family,
                }
            if meta.get("role") == "parent":
                families[family]["parent"] = name
            else:
                families[family]["children"].append(name)

    # Fix up family descriptions (requires parent meta to be in flakes already)
    for family_name, fdata in families.items():
        parent = fdata["parent"]
        if parent and parent in flakes:
            fdata["description"] = flakes[parent].get("description", family_name)
        # Ensure the parent isn't also listed as a child
        fdata["children"] = [c for c in fdata["children"] if c != fdata["parent"]]

    return flakes, families, errors, new_cache


# ── Registry data structure ───────────────────────────────────────────────────


def build_registry(flakes: dict, families: dict) -> dict:
    return {
        "schemaVersion": SCHEMA_VERSION,
        "flakes": flakes,
        "families": families,
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
    parser.add_argument(
        "--workers",
        type=int,
        default=8,
        help="Number of parallel nix eval workers (default: 8)",
    )
    args = parser.parse_args()

    script_dir = Path(__file__).parent
    repo_root = Path(args.repo_root) if args.repo_root else script_dir.parent

    flakes_dir = repo_root / "flakes"
    eval_nix = repo_root / "scripts" / "eval-meta.nix"

    if not flakes_dir.is_dir():
        print(f"ERROR: flakes/ not found at {flakes_dir}", file=sys.stderr)
        sys.exit(1)
    if not eval_nix.exists():
        print(f"ERROR: scripts/eval-meta.nix not found at {eval_nix}", file=sys.stderr)
        sys.exit(1)

    cache = _load_cache(repo_root)

    print("Scanning flakes/...")
    flakes, families, errors, new_cache = scan_flakes(
        flakes_dir, eval_nix, cache, max_workers=args.workers
    )

    _save_cache(repo_root, new_cache)

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
