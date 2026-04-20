#!/usr/bin/env bash
# gen-registry.sh — Generate registry.json and registry.yaml from flakes/
#
# Folder conventions:
#   flakes/<name>/default.nix              standalone flake (no family)
#   flakes/<family>/<name>/default.nix     family member flake
#
# Usage:
#   bash scripts/gen-registry.sh [--repo-root PATH] [--workers N] [--verbose]
set -euo pipefail

# ── Constants ─────────────────────────────────────────────────────────────────
EXCLUDED=("_template")
SCHEMA_VERSION=1
CACHE_FILE=".registry-cache.json"

# ── Defaults ──────────────────────────────────────────────────────────────────
VERBOSE=false
WORKERS=8
REPO_ROOT=""

# ── Argument parsing ──────────────────────────────────────────────────────────

usage() {
  cat <<'EOF'
Usage: gen-registry.sh [OPTIONS]

Generate registry.json and registry.yaml from the flakes/ directory.

Folder conventions:
  flakes/<name>/default.nix              standalone flake (no family)
  flakes/<family>/<name>/default.nix     family member flake

Options:
  --repo-root PATH   Path to the ft-nixpkgs repo root
                     (default: parent of this script's directory)
  --workers N        Number of parallel nix eval workers (default: 8)
  --verbose, -v      Print debug info (nix eval commands, cache hits, byte counts)
  --help, -h         Show this help message and exit
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-root)  REPO_ROOT="$2"; shift 2 ;;
    --workers)    WORKERS="$2";   shift 2 ;;
    --verbose|-v) VERBOSE=true;   shift   ;;
    --help|-h)    usage; exit 0           ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 1 ;;
  esac
done

# ── Derived paths ─────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "$REPO_ROOT" ]]; then
  REPO_ROOT="$(dirname "$SCRIPT_DIR")"
fi

FLAKES_DIR="$REPO_ROOT/flakes"
EVAL_NIX="$REPO_ROOT/scripts/eval-meta.nix"
CACHE_FILE_PATH="$REPO_ROOT/$CACHE_FILE"

# ── Sanity checks ─────────────────────────────────────────────────────────────

if [[ ! -d "$FLAKES_DIR" ]]; then
  printf 'ERROR: flakes/ not found at %s\n' "$FLAKES_DIR" >&2
  exit 1
fi
if [[ ! -f "$EVAL_NIX" ]]; then
  printf 'ERROR: scripts/eval-meta.nix not found at %s\n' "$EVAL_NIX" >&2
  exit 1
fi

# ── Work directory (cleaned up on exit) ───────────────────────────────────────

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# ── Helpers ───────────────────────────────────────────────────────────────────

vlog() {
  if [[ "$VERBOSE" == true ]]; then
    printf '  [verbose] %s\n' "$*" >&2
  fi
}

file_hash() {
  local path="$1"
  if command -v sha256sum &>/dev/null; then
    sha256sum "$path" | cut -d' ' -f1
  else
    shasum -a 256 "$path" | cut -d' ' -f1
  fi
}

is_excluded() {
  local name="$1" excl
  for excl in "${EXCLUDED[@]}"; do
    [[ "$name" == "$excl" ]] && return 0
  done
  return 1
}

# Outputs lines of "family_or_empty|name|abs_nix_path", sorted.
# Called via process substitution — runs in a subshell; nullglob is safe here.
discover_entries() {
  shopt -s nullglob
  local entries=() top_dir top_name top_nix child_dir child_name child_nix

  for top_dir in "$FLAKES_DIR"/*/; do
    [[ -d "$top_dir" ]] || continue
    top_name="$(basename "$top_dir")"
    is_excluded "$top_name" && continue
    top_nix="${top_dir}default.nix"
    if [[ -f "$top_nix" ]]; then
      entries+=( "|${top_name}|$(realpath "$top_nix")" )
    else
      for child_dir in "$top_dir"*/; do
        [[ -d "$child_dir" ]] || continue
        child_name="$(basename "$child_dir")"
        is_excluded "$child_name" && continue
        child_nix="${child_dir}default.nix"
        if [[ -f "$child_nix" ]]; then
          entries+=( "${top_name}|${child_name}|$(realpath "$child_nix")" )
        fi
      done
    fi
  done

  printf '%s\n' "${entries[@]+"${entries[@]}"}" | sort
}

# Evaluate one entry; write a JSON result object to out_file.
# Runs as a background job — must not write to stdout.
eval_entry() {
  local family="$1" name="$2" nix_path="$3" out_file="$4"
  local current_hash family_json cached_meta

  current_hash="$(file_hash "$nix_path")"

  if [[ -n "$family" ]]; then
    family_json="$(jq -n --arg f "$family" '$f')"
  else
    family_json="null"
  fi

  # ── Cache check ──────────────────────────────────────────────────────────
  if [[ -f "$CACHE_FILE_PATH" ]]; then
    cached_meta="$(jq -r \
      --arg key  "$nix_path" \
      --arg hash "$current_hash" \
      'if (.[$key] // null) != null and .[$key].hash == $hash
       then .[$key].meta | tojson
       else ""
       end' \
      "$CACHE_FILE_PATH" 2>/dev/null || true)"
    if [[ -n "$cached_meta" && "$cached_meta" != "null" ]]; then
      vlog "cache hit: $nix_path"
      jq -n \
        --argjson family   "$family_json" \
        --arg     name     "$name" \
        --arg     hash     "$current_hash" \
        --arg     nix_path "$nix_path" \
        --argjson meta     "$cached_meta" \
        '{family:$family,name:$name,hash:$hash,nix_path:$nix_path,meta:$meta,cached:true}' \
        > "$out_file"
      return
    fi
  fi

  # ── Nix evaluation ───────────────────────────────────────────────────────
  local nix_stdout="${out_file}.stdout"
  local nix_stderr="${out_file}.stderr"
  local nix_exit=0
  local cmd=("nix" "eval" "--json" "--file" "$EVAL_NIX" "--arg" "flakePath" "$nix_path")

  vlog "${cmd[*]}"
  "${cmd[@]}" >"$nix_stdout" 2>"$nix_stderr" || nix_exit=$?

  if [[ $nix_exit -ne 0 ]]; then
    local err_text
    err_text="$(head -c 4096 "$nix_stderr" || true)"
    [[ -n "$err_text" ]] || err_text="nix eval exited with code $nix_exit"
    jq -n \
      --argjson family   "$family_json" \
      --arg     name     "$name" \
      --arg     nix_path "$nix_path" \
      --arg     error    "$err_text" \
      '{family:$family,name:$name,nix_path:$nix_path,error:$error}' \
      > "$out_file"
    rm -f "$nix_stdout" "$nix_stderr"
    return
  fi

  local meta_json
  meta_json="$(cat "$nix_stdout")"
  if ! jq -e . <<<"$meta_json" >/dev/null 2>&1; then
    jq -n \
      --argjson family   "$family_json" \
      --arg     name     "$name" \
      --arg     nix_path "$nix_path" \
      --arg     error    "invalid JSON from nix eval" \
      '{family:$family,name:$name,nix_path:$nix_path,error:$error}' \
      > "$out_file"
    rm -f "$nix_stdout" "$nix_stderr"
    return
  fi

  jq -n \
    --argjson family   "$family_json" \
    --arg     name     "$name" \
    --arg     hash     "$current_hash" \
    --arg     nix_path "$nix_path" \
    --argjson meta     "$meta_json" \
    '{family:$family,name:$name,hash:$hash,nix_path:$nix_path,meta:$meta,cached:false}' \
    > "$out_file"

  rm -f "$nix_stdout" "$nix_stderr"
}

# ── Discovery ─────────────────────────────────────────────────────────────────

echo "Scanning flakes/..."

mapfile -t ENTRIES < <(discover_entries)

# ── Parallel evaluation ───────────────────────────────────────────────────────

OUT_FILES=()
IDX=0
RUNNING=0

for ENTRY in "${ENTRIES[@]+"${ENTRIES[@]}"}"; do
  IFS='|' read -r ENTRY_FAMILY ENTRY_NAME ENTRY_NIX_PATH <<< "$ENTRY"
  ENTRY_OUT="$WORK_DIR/$(printf '%06d' $IDX).json"
  IDX=$(( IDX + 1 ))
  OUT_FILES+=("$ENTRY_OUT")

  eval_entry "$ENTRY_FAMILY" "$ENTRY_NAME" "$ENTRY_NIX_PATH" "$ENTRY_OUT" &
  RUNNING=$(( RUNNING + 1 ))

  if [[ $RUNNING -ge $WORKERS ]]; then
    wait -n 2>/dev/null || true
    RUNNING=$(( RUNNING - 1 ))
  fi
done

wait

# ── Collect results ───────────────────────────────────────────────────────────

if [[ ${#OUT_FILES[@]} -eq 0 ]]; then
  RESULTS_JSON="[]"
else
  RESULTS_JSON="$(jq -s '.' "${OUT_FILES[@]+"${OUT_FILES[@]}"}")"
fi

# ── Print per-entry status ────────────────────────────────────────────────────

HAS_ERROR=false

while IFS= read -r STATUS_LINE; do
  printf '%s\n' "$STATUS_LINE"
done < <(jq -r '.[] |
  if .error then
    "  [" + (if .family then .family + "/" else "" end) + .name + "] eval failed"
  elif .cached then
    "  [" + (if .family then .family + "/" else "" end) + .name + "] (cached)"
  else
    if .family then "  [" + .name + "] member of " + .family
    else "  [" + .name + "] standalone"
    end
  end' <<< "$RESULTS_JSON")

if jq -e '[.[] | select(.error)] | length > 0' <<< "$RESULTS_JSON" >/dev/null; then
  HAS_ERROR=true
fi

# ── Save updated cache (atomic) ───────────────────────────────────────────────

NEW_CACHE="$(jq '
  map(select(.error == null)) |
  map({key: .nix_path, value: {hash: .hash, meta: .meta}}) |
  from_entries
' <<< "$RESULTS_JSON")"

TMP_CACHE="${CACHE_FILE_PATH}.tmp"
printf '%s\n' "$NEW_CACHE" > "$TMP_CACHE"
mv "$TMP_CACHE" "$CACHE_FILE_PATH"
vlog "saved cache → $CACHE_FILE_PATH"

# ── Assemble registry with jq ─────────────────────────────────────────────────

echo "Writing registry files..."

REGISTRY="$(jq -n \
  --argjson schema   "$SCHEMA_VERSION" \
  --argjson results  "$RESULTS_JSON" \
  '
  ($results | map(select(.error == null))) as $ok |
  ($ok | map({key: .name, value: (.meta + {family: .family})}) | from_entries) as $flakes |
  ($ok
    | map(select(.family != null))
    | group_by(.family)
    | map(
        (.[0].family) as $fname |
        (map(select(.meta.role? == "parent")) | first | .name // null) as $parent |
        {
          key: $fname,
          value: {
            parent: $parent,
            children: (map(select(.meta.role? != "parent")) | map(.name) | map(select(. != $parent))),
            description: (
              if $parent != null and ($flakes[$parent] != null)
              then ($flakes[$parent].description // $fname)
              else $fname
              end
            )
          }
        }
      )
    | from_entries
  ) as $families |
  { schemaVersion: $schema, flakes: $flakes, families: $families }
  ')"

# ── Write registry.json (atomic) ──────────────────────────────────────────────

JSON_OUT="$REPO_ROOT/registry.json"
TMP_JSON="${JSON_OUT}.tmp"
printf '%s\n' "$REGISTRY" | jq '.' > "$TMP_JSON"
mv "$TMP_JSON" "$JSON_OUT"
printf '  Wrote %s\n' "$JSON_OUT"
vlog "wrote $(wc -c < "$JSON_OUT") bytes → $JSON_OUT"

# ── Write registry.yaml (atomic, python3+pyyaml or JSON fallback) ─────────────

YAML_OUT="$REPO_ROOT/registry.yaml"
TMP_YAML="${YAML_OUT}.tmp"

if python3 -c "import yaml" 2>/dev/null; then
  {
    printf '# Auto-generated by scripts/gen-registry.sh — do not edit manually.\n'
    printf '# Source of truth: flakes/*/default.nix (meta block)\n\n'
    printf '%s\n' "$REGISTRY" | python3 -c "
import sys, json, yaml
data = json.load(sys.stdin)
sys.stdout.write(yaml.dump(data, default_flow_style=False, allow_unicode=True, sort_keys=False))
"
  } > "$TMP_YAML"
  mv "$TMP_YAML" "$YAML_OUT"
  printf '  Wrote %s\n' "$YAML_OUT"
else
  {
    printf '# Auto-generated by scripts/gen-registry.sh — do not edit manually.\n'
    printf '# Source of truth: flakes/*/default.nix (meta block)\n\n'
    printf '# (PyYAML not available; output is JSON-formatted valid YAML)\n\n'
    printf '%s\n' "$REGISTRY" | jq '.'
  } > "$TMP_YAML"
  mv "$TMP_YAML" "$YAML_OUT"
  printf '  Wrote %s (JSON fallback — install pyyaml for pretty YAML)\n' "$YAML_OUT"
fi
vlog "wrote $(wc -c < "$YAML_OUT") bytes → $YAML_OUT"

# ── Summary ───────────────────────────────────────────────────────────────────

N_FLAKES="$(jq '.flakes | length' <<< "$REGISTRY")"
N_FAMILIES="$(jq '.families | length' <<< "$REGISTRY")"

printf '\nDone — %s flake(s), %s famil(ies).\n' "$N_FLAKES" "$N_FAMILIES"

if [[ "$HAS_ERROR" == true ]]; then
  N_ERRORS="$(jq '[.[] | select(.error)] | length' <<< "$RESULTS_JSON")"
  printf '\n%s flake(s) failed to evaluate:\n' "$N_ERRORS" >&2
  jq -r '.[] | select(.error) |
    "  \u2717 [" + (if .family then .family + "/" else "" end) + .name + "] eval failed: " + .error' \
    <<< "$RESULTS_JSON" >&2
  exit 1
fi
