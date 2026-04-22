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
CHECK_UPDATES=false

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
  --check-updates    Check upstream repos for newer versions and update default.nix files
  --verbose, -v      Print debug info (nix eval commands, cache hits, byte counts)
  --help, -h         Show this help message and exit
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-root)     REPO_ROOT="$2"; shift 2 ;;
    --workers)       WORKERS="$2";   shift 2 ;;
    --verbose|-v)    VERBOSE=true;   shift   ;;
    --check-updates) CHECK_UPDATES=true; shift ;;
    --help|-h)       usage; exit 0           ;;
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

# Convert a flake reference like "github:owner/repo" to a git HTTPS URL.
flake_ref_to_git_url() {
  local ref="$1"
  case "$ref" in
    github:*)
      local path="${ref#github:}"
      printf 'https://github.com/%s.git' "$path"
      ;;
    gitlab:*)
      local path="${ref#gitlab:}"
      printf 'https://gitlab.com/%s.git' "$path"
      ;;
    sourcehut:*)
      local path="${ref#sourcehut:}"
      printf 'https://git.sr.ht/%s' "$path"
      ;;
    http:*|https:*|git@*)
      printf '%s' "$ref"
      ;;
    *)
      # Unknown format, return as-is and let git ls-remote fail gracefully
      printf '%s' "$ref"
      ;;
  esac
}

# Fetch all version tags from upstream repo via git ls-remote.
# Returns JSON array sorted by semver (newest first); includes numeric tags and floating tags.
# Returns empty array if repo is unreachable or has no tags.
fetch_upstream_versions() {
  local repo_url="$1"
  repo_url="$(flake_ref_to_git_url "$repo_url")"

  if ! command -v git &> /dev/null; then
    printf '[]'
    return 0
  fi

  local refs
  refs="$(git ls-remote --tags --heads "$repo_url" 2>/dev/null || true)"

  if [[ -z "$refs" ]]; then
    printf '[]'
    return 0
  fi

  # Extract tag/branch names, filter for version tags
  local versions=()
  while IFS=$'\t' read -r _sha ref_name; do
    local tag_name="${ref_name#refs/tags/}"
    tag_name="${tag_name#refs/heads/}"
    tag_name="${tag_name%^{}}"

    case "$tag_name" in
      v[0-9]*|stable|beta|unstable|main)
        versions+=("$tag_name")
        ;;
    esac
  done <<< "$refs"

  # Deduplicate and output as JSON array
  if [[ ${#versions[@]} -eq 0 ]]; then
    printf '[]'
  else
    printf '%s\n' "${versions[@]}" | sort -u | jq -R -s 'split("\n") | map(select(length > 0))'
  fi
}

# Compare two semver strings (with optional v prefix).
# Returns 0 if $1 >= $2, 1 otherwise.
# Falls back to string comparison if either isn't semver-like.
semver_ge() {
  local a="${1#v}" b="${2#v}"
  local a_major a_minor a_patch b_major b_minor b_patch
  a_major="$(echo "$a" | cut -d. -f1)"
  a_minor="$(echo "$a" | cut -d. -f2)"
  a_patch="$(echo "$a" | cut -d. -f3)"
  b_major="$(echo "$b" | cut -d. -f1)"
  b_minor="$(echo "$b" | cut -d. -f2)"
  b_patch="$(echo "$b" | cut -d. -f3)"

  if [[ "$a_major" =~ ^[0-9]+$ && "$a_minor" =~ ^[0-9]+$ && "$a_patch" =~ ^[0-9]+$ && \
        "$b_major" =~ ^[0-9]+$ && "$b_minor" =~ ^[0-9]+$ && "$b_patch" =~ ^[0-9]+$ ]]; then
    if [[ "$a_major" -gt "$b_major" ]]; then return 0; fi
    if [[ "$a_major" -lt "$b_major" ]]; then return 1; fi
    if [[ "$a_minor" -gt "$b_minor" ]]; then return 0; fi
    if [[ "$a_minor" -lt "$b_minor" ]]; then return 1; fi
    if [[ "$a_patch" -gt "$b_patch" ]]; then return 0; fi
    if [[ "$a_patch" -lt "$b_patch" ]]; then return 1; fi
    return 0
  else
    [[ "$a" > "$b" || "$a" == "$b" ]]
  fi
}

# Given a JSON array of version tags, return the newest semver tag.
# Prefers numeric tags over floating tags (stable, main, etc.).
# Returns empty string if no suitable tag found.
newest_version() {
  local versions_json="$1"
  local best=""
  local tag
  while IFS= read -r tag; do
    [[ -n "$tag" ]] || continue
    case "$tag" in
      stable|beta|unstable|main|master) continue ;;
    esac
    if [[ -z "$best" ]] || ! semver_ge "$best" "$tag"; then
      best="$tag"
    fi
  done < <(jq -r '.[]' <<< "$versions_json" 2>/dev/null)
  printf '%s' "$best"
}

# Sort a single version tag for ordering.
# Output: "sort_key\ttag" where sort_key controls final order.
_version_sort_key() {
  local tag="$1"
  case "$tag" in
    stable)   printf 'A\t%s\n' "$tag" ;;
    beta)     printf 'B\t%s\n' "$tag" ;;
    unstable) printf 'C\t%s\n' "$tag" ;;
    wip)      printf 'Z\t%s\n' "$tag" ;;
    deprecated) printf 'X\t%s\n' "$tag" ;; # dropped later
    *)
      # semver: negate the numeric parts so newer = earlier in sort
      local v="${tag#v}"
      local major minor patch
      major="$(echo "$v" | cut -d. -f1)"
      minor="$(echo "$v" | cut -d. -f2)"
      patch="$(echo "$v" | cut -d. -f3)"
      [[ "$major" =~ ^[0-9]+$ ]] || major=0
      [[ "$minor" =~ ^[0-9]+$ ]] || minor=0
      [[ "$patch" =~ ^[0-9]+$ ]] || patch=0
      # Use 9999 - value so descending order becomes ascending
      printf 'D%04d%04d%04d\t%s\n' "$((9999 - major))" "$((9999 - minor))" "$((9999 - patch))" "$tag"
      ;;
  esac
}

# Sort versions in the desired order:
#   stable → beta → unstable → semver desc (newest first) → wip
#   deprecated tags are dropped entirely.
sort_versions() {
  local json="$1"
  # Validate input is a JSON array
  if ! jq -e 'type == "array"' <<< "$json" >/dev/null 2>&1; then
    echo '[]'
    return
  fi
  local sorted
  sorted="$(while IFS= read -r tag; do
    [[ -n "$tag" && "$tag" != "deprecated" ]] || continue
    _version_sort_key "$tag"
  done < <(jq -r '.[]' <<< "$json" 2>/dev/null) | sort | cut -f2-)"
  # Convert back to JSON array
  if [[ -z "$sorted" ]]; then
    echo '[]'
  else
    printf '%s\n' "$sorted" | jq -R . | jq -s .
  fi
}

# Merge two JSON arrays of versions, deduplicate, sort.
# Args: old_json_array new_json_array
merge_version_arrays() {
  local old_json="$1" new_json="$2"
  local merged
  # Validate both inputs
  if ! jq -e 'type == "array"' <<< "$old_json" >/dev/null 2>&1; then
    old_json='[]'
  fi
  if ! jq -e 'type == "array"' <<< "$new_json" >/dev/null 2>&1; then
    new_json='[]'
  fi
  merged="$(jq -s 'add | unique' <<< "$old_json$new_json" 2>/dev/null || echo '[]')"
  if ! jq -e 'type == "array"' <<< "$merged" >/dev/null 2>&1; then
    merged='[]'
  fi
  sort_versions "$merged"
}

# Format a Nix list from a JSON array of strings.
# Output is a single-line Nix list suitable for sed replacement.
json_to_nix_list() {
  local json="$1"
  local items
  items="$(jq -r '.[]' <<< "$json" 2>/dev/null | sed 's/^/"/; s/$/"/' | paste -sd ' ' -)"
  if [[ -z "$items" ]]; then
    printf '[]'
  else
    printf '[ %s ]' "$items"
  fi
}

# Update version and versions in a default.nix file if newer versions are available.
# Args: nix_path current_version current_versions_json upstream_versions_json newest_version
# Returns 0 if file was modified, 1 otherwise.
bump_version_in_nix() {
  local nix_path="$1" current="$2" current_versions_json="$3" upstream_versions_json="$4" newest="$5"
  local merged_versions merged_nix_list modified=false

  # Merge current and upstream versions
  merged_versions="$(merge_version_arrays "$current_versions_json" "$upstream_versions_json")"

  # Update versions array if upstream added new tags
  if [[ "$merged_versions" != "$current_versions_json" ]]; then
    merged_nix_list="$(json_to_nix_list "$merged_versions")"
    # Replace any versions = ... line (single-line or multi-line) with single-line list
    if grep -q 'versions\s*=\s*\[' "$nix_path"; then
      # Multi-line or single-line list: use perl for robust multi-line replacement
      perl -i -0777 -pe 's/versions\s*=\s*\[.*?\];/versions     = '"$merged_nix_list"';/s' "$nix_path"
    else
      # Missing entirely: insert after version line
      sed -i '/version\s*=\s*"[^"]*";/a\    versions     = '"$merged_nix_list"';' "$nix_path"
    fi
    printf '  [updated versions] %s\n' "$(basename "$(dirname "$nix_path")")"
    modified=true
  fi

  # Always set main version to the newest available semver
  if [[ -n "$newest" && "$newest" != "$current" ]]; then
    sed -i "s/version\s*=\s*\"$current\"/version = \"$newest\"/" "$nix_path"
    printf '  [bumped version] %s: %s → %s\n' "$(basename "$(dirname "$nix_path")")" "$current" "$newest"
    modified=true
  fi

  if [[ "$modified" == true ]]; then
    return 0
  fi
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
  local cmd=("nix-instantiate" "--eval" "--json" "--strict" "$EVAL_NIX" "--arg" "flakePath" "$nix_path")

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

# ── Collect version tags from upstream repos ──────────────────────────────────

echo ""
echo "Collecting upstream version tags..."

# Build temporary versions file: name\tversions_json
VERSIONS_FILE="$WORK_DIR/versions.txt"
{
  jq -r '.[] | select(.error == null) | .name + "\t" + (.meta.repo // "")' <<< "$RESULTS_JSON" | \
  while IFS=$'\t' read -r flake_name repo_url; do
    if [[ -n "$repo_url" ]]; then
      versions="$(fetch_upstream_versions "$repo_url")"
      vlog "[$flake_name] found $(echo "$versions" | jq 'length') version tags"
    else
      versions="[]"
    fi
    printf '%s\t%s\n' "$flake_name" "$versions"
  done
} > "$VERSIONS_FILE"

# ── Check for upstream version updates ────────────────────────────────────────

# ── Check for upstream version updates ────────────────────────────────────────

BUMPED_NAMES=""

if [[ "$CHECK_UPDATES" == true ]]; then
  echo ""
  echo "Checking for upstream version updates..."
  while IFS=$'\t' read -r flake_name current_version current_versions_json nix_path; do
    [[ -n "$current_version" ]] || continue
    upstream_versions="$(grep "^${flake_name}\t" "$VERSIONS_FILE" | cut -f2)"
    [[ -n "$upstream_versions" ]] || upstream_versions='[]'
    newest="$(newest_version "$upstream_versions")"
    if bump_version_in_nix "$nix_path" "$current_version" "$current_versions_json" "$upstream_versions" "$newest"; then
      BUMPED_NAMES="$BUMPED_NAMES $flake_name"
    fi
  done < <(jq -r '.[] | select(.error == null) | .name + "\t" + (.meta.version // "") + "\t" + (.meta.versions // "[]" | tojson) + "\t" + .nix_path' <<< "$RESULTS_JSON")
fi

# Now merge versions into RESULTS_JSON by re-assembling it
RESULTS_JSON_WITH_VERSIONS="[]"
jq -r '.[] | select(.error == null) | @base64' <<< "$RESULTS_JSON" | while read -r entry_b64; do
  entry="$(echo "$entry_b64" | base64 -d)"
  flake_name="$(echo "$entry" | jq -r '.name')"
  upstream_versions="$(grep "^${flake_name}\t" "$VERSIONS_FILE" | cut -f2)"
  [[ -n "$upstream_versions" ]] || upstream_versions='[]'
  # If this flake was bumped, also update version and versions in the JSON result
  if [[ "$BUMPED_NAMES" == *" $flake_name "* ]]; then
    newest="$(newest_version "$upstream_versions")"
    merged_versions="$(merge_version_arrays "$(echo "$entry" | jq -r '.meta.versions // [] | tojson')" "$upstream_versions")"
    entry="$(echo "$entry" | jq --arg newest "$newest" --argjson merged "$merged_versions" '
      .meta.version = $newest |
      .meta.versions = $merged |
      .versions = $merged
    ')"
  else
    # Use meta.versions if available, otherwise fall back to upstream versions
    entry="$(echo "$entry" | jq --argjson upstream "$upstream_versions" '
      .versions = (.meta.versions // $upstream)
    ')"
  fi
  echo "$entry" >> "$WORK_DIR/results_with_versions.tmp"
done
# Also add failed entries (with error field)
jq '.[] | select(.error != null)' <<< "$RESULTS_JSON" >> "$WORK_DIR/results_with_versions.tmp"
RESULTS_JSON="$(jq -s '.' "$WORK_DIR/results_with_versions.tmp")"

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
  ($ok | map({key: .name, value: (.meta + {family: .family, versions: (.versions // [])})}) | from_entries) as $flakes |
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
