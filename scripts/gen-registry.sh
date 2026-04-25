#!/usr/bin/env bash
# gen-registry.sh — Build registry.json and registry.yaml from the flakes/ tree.
#
# Each flake lives at one of two paths:
#   flakes/<name>/default.nix               — standalone flake (no family)
#   flakes/<family>/<member>/default.nix    — family member flake
#
# The script runs these steps in order:
#   1. Discover all flake default.nix files.
#   2. Evaluate each via nix-instantiate to extract the `meta` block.
#      Results are cached by file-hash so unchanged flakes skip re-evaluation.
#   3. Fetch all version tags from each flake's upstream git repo.
#   4. (--check-updates only) Rewrite version / versions in .nix files when
#      upstream has newer releases.
#   5. Merge upstream semver tags into each entry's versions list.
#   6. Assemble and write registry.json and registry.yaml.
#
# Usage:
#   bash scripts/gen-registry.sh [OPTIONS]
#
# Options:
#   --repo-root PATH   Path to the ft-nixpkgs repo root
#                      (default: parent directory of this script)
#   --workers N        Parallel nix-instantiate workers (default: 8)
#   --check-updates    Fetch upstream tags and rewrite version/versions in
#                      default.nix files when a newer release is found
#   --verbose, -v      Print debug info (commands run, cache hits, byte counts)
#   --help, -h         Show this help and exit

set -uo pipefail

# ── Configuration ──────────────────────────────────────────────────────────────

# Directories inside flakes/ that are never processed (e.g. scaffolding).
EXCLUDED=("_template")

# Bumped whenever the registry schema changes in a breaking way.
SCHEMA_VERSION=1

# Cache file path relative to REPO_ROOT. Keyed by absolute nix_path.
CACHE_FILE=".registry-cache.json"

# ── Argument defaults ──────────────────────────────────────────────────────────

VERBOSE=false
WORKERS=8
REPO_ROOT=""
CHECK_UPDATES=false

# ── Usage ──────────────────────────────────────────────────────────────────────

usage() {
  cat <<'EOF'
Usage: gen-registry.sh [OPTIONS]

Build registry.json and registry.yaml from the flakes/ directory.

Folder conventions:
  flakes/<name>/default.nix              standalone flake (no family)
  flakes/<family>/<name>/default.nix     family member flake

Options:
  --repo-root PATH   Path to the ft-nixpkgs repo root
                     (default: parent of this script's directory)
  --workers N        Number of parallel nix eval workers (default: 8)
  --check-updates    Fetch upstream tags and rewrite version/versions in
                     default.nix files when a newer release is available
  --verbose, -v      Print debug info (commands, cache hits, byte counts)
  --help, -h         Show this help message and exit
EOF
}

# ── Argument parsing ───────────────────────────────────────────────────────────

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

# ── Derived paths ──────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -z "$REPO_ROOT" ]] && REPO_ROOT="$(dirname "$SCRIPT_DIR")"

FLAKES_DIR="$REPO_ROOT/flakes"
EVAL_NIX="$REPO_ROOT/scripts/eval-meta.nix"
CACHE_FILE_PATH="$REPO_ROOT/$CACHE_FILE"

# ── Pre-flight checks ──────────────────────────────────────────────────────────

[[ -d "$FLAKES_DIR" ]] || { printf 'ERROR: flakes/ not found at %s\n' "$FLAKES_DIR" >&2; exit 1; }
[[ -f "$EVAL_NIX"   ]] || { printf 'ERROR: eval-meta.nix not found at %s\n' "$EVAL_NIX" >&2;   exit 1; }

# ── Temp workspace (cleaned up on EXIT) ───────────────────────────────────────

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# ══════════════════════════════════════════════════════════════════════════════
# Utility functions
# ══════════════════════════════════════════════════════════════════════════════

# Print a debug line to stderr — only when --verbose is active.
vlog() { [[ "$VERBOSE" == true ]] && printf '  [verbose] %s\n' "$*" >&2 || true; }

# SHA-256 of a file. Works on Linux (sha256sum) and macOS (shasum -a 256).
file_hash() {
  if command -v sha256sum &>/dev/null; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# Return 0 (true) if $1 is in the EXCLUDED list.
is_excluded() {
  local name="$1" excl
  for excl in "${EXCLUDED[@]}"; do [[ "$name" == "$excl" ]] && return 0; done
  return 1
}

# ══════════════════════════════════════════════════════════════════════════════
# Version helpers
# ══════════════════════════════════════════════════════════════════════════════

# Convert a Nix flake reference to a plain HTTPS git URL.
#
#   github:owner/repo   →  https://github.com/owner/repo.git
#   gitlab:owner/repo   →  https://gitlab.com/owner/repo.git
#   sourcehut:~u/repo   →  https://git.sr.ht/~u/repo
#   http(s)/git@ URLs   →  returned unchanged
flake_ref_to_git_url() {
  case "$1" in
    github:*)    printf 'https://github.com/%s.git'  "${1#github:}"    ;;
    gitlab:*)    printf 'https://gitlab.com/%s.git'  "${1#gitlab:}"    ;;
    sourcehut:*) printf 'https://git.sr.ht/%s'       "${1#sourcehut:}" ;;
    *)           printf '%s' "$1" ;;
  esac
}

# Fetch every tag from a repo (flake ref or git URL).
# For github: refs, uses the GitHub REST API (reliable in CI, supports GITHUB_TOKEN).
# Falls back to git ls-remote for all other ref types.
# Always prints a compact single-line JSON array of tag name strings.
# Prints [] if the repo is unreachable or has no tags.
fetch_upstream_tags() {
  local ref="$1"

  # ── GitHub: use the REST API (works in CI with or without a token) ───────────
  if [[ "$ref" == github:* ]] || [[ "$ref" == git+ssh://git@github.com/* ]]; then
    local owner_repo
    if [[ "$ref" == github:* ]]; then
      owner_repo="${ref#github:}"
    else
      owner_repo="${ref#git+ssh://git@github.com/}"
      owner_repo="${owner_repo%.git}"
    fi
    local api_url="https://api.github.com/repos/${owner_repo}/tags?per_page=100"

    local curl_args=(-sfL -H "Accept: application/vnd.github+json")
    # Use GITHUB_TOKEN when available (avoids anonymous rate-limiting in CI)
    [[ -n "${GITHUB_TOKEN:-}" ]] && curl_args+=(-H "Authorization: Bearer $GITHUB_TOKEN")

    local response
    response="$(curl "${curl_args[@]}" "$api_url" 2>/dev/null || true)"
    [[ -z "$response" ]] && { printf '[]'; return; }

    jq -c '[.[].name]' <<< "$response" 2>/dev/null || printf '[]'
    return
  fi

  # ── All other forges: fall back to git ls-remote ─────────────────────────────
  local url
  url="$(flake_ref_to_git_url "$ref")"
  command -v git &>/dev/null || { printf '[]'; return; }

  local refs
  refs="$(git ls-remote --tags "$url" 2>/dev/null || true)"
  [[ -z "$refs" ]] && { printf '[]'; return; }

  local tags=()
  while IFS=$'\t' read -r _sha ref_name; do
    local tag="${ref_name#refs/tags/}"
    tag="${tag%^{}}"
    [[ -n "$tag" ]] && tags+=("$tag")
  done <<< "$refs"

  [[ ${#tags[@]} -eq 0 ]] && { printf '[]'; return; }
  printf '%s\n' "${tags[@]}" | sort -u \
    | jq -cR -s 'split("\n") | map(select(length > 0))'
}

# Filter a JSON array of tag strings to only strict semver tags: vX.Y.Z or X.Y.Z.
# Prints a compact single-line JSON array, or [] on error.
filter_semver_tags() {
  jq -c '[.[] | select(test("^v?[0-9]+\\.[0-9]+\\.[0-9]+$"))]' <<< "$1" 2>/dev/null \
    || printf '[]'
}

# Compare two semver strings (optional v prefix).
# Returns 0 (success) if $1 >= $2, 1 (failure) if $1 < $2.
# Falls back to lexicographic comparison for non-numeric inputs.
semver_ge() {
  local a="${1#v}" b="${2#v}"

  # Fast path: both are pure semver — compare numerically part by part
  if [[ "$a" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$b" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    local -i am="${a%%.*}" bm="${b%%.*}"
    local arem="${a#*.}" brem="${b#*.}"
    local -i an="${arem%%.*}" bn="${brem%%.*}"
    local -i ap="${arem#*.}"  bp="${brem#*.}"

    (( am != bm )) && { (( am > bm )) && return 0 || return 1; }
    (( an != bn )) && { (( an > bn )) && return 0 || return 1; }
    (( ap >= bp ))
    return
  fi

  # Slow path: lexicographic
  [[ "$a" > "$b" || "$a" == "$b" ]]
}

# Find the newest semver tag in a JSON array of tag strings.
# Skips non-release labels (stable, beta, unstable, main, master).
# Prints the winning tag, or nothing if the array is empty / has no semver tags.
newest_version() {
  local best="" tag
  while IFS= read -r tag; do
    [[ -z "$tag" ]] && continue
    case "$tag" in stable|beta|unstable|main|master) continue ;; esac
    if [[ -z "$best" ]] || ! semver_ge "$best" "$tag"; then
      best="$tag"
    fi
  done < <(jq -r '.[]' <<< "$1" 2>/dev/null)
  printf '%s' "$best"
}

# Sort a JSON array of semver tags newest-first.
# Non-semver entries sort to the end (patch treated as 0).
# Always prints compact single-line JSON. Prints [] on invalid input.
sort_versions() {
  jq -e 'type == "array"' <<< "$1" >/dev/null 2>&1 || { printf '[]'; return; }
  jq -c '
    map(
      . as $tag |
      (sub("^v"; "") | split(".") | map(tonumber? // 0)) as $p |
      {tag: $tag, major: ($p[0] // 0), minor: ($p[1] // 0), patch: ($p[2] // 0)}
    )
    | sort_by(.major, .minor, .patch) | reverse | map(.tag)
  ' <<< "$1" 2>/dev/null || printf '[]'
}

# Prune superseded major versions from a sorted JSON array of semver tags.
#
# Rule: keep ALL versions of the highest major; for every older major keep
# only the single highest (latest) tag within that major.
#
# Examples:
#   [3.1.0, 3.0.0, 2.3.0, 2.2.0, 1.5.0, 1.4.0]
#     → [3.1.0, 3.0.0, 2.3.0, 1.5.0]
#
#   [2.3.0, 2.2.0, 1.5.0, 1.4.0, 1.3.0]
#     → [2.3.0, 2.2.0, 1.5.0]
#
# Input must be a JSON array (output of sort_versions). Returns the input
# unchanged on jq error or when there is only one major version.
prune_old_major_versions() {
  jq -c '
    map(
      . as $tag |
      (sub("^v"; "") | split(".") | map(tonumber? // 0)) as $p |
      {tag: $tag, major: ($p[0] // 0), minor: ($p[1] // 0), patch: ($p[2] // 0)}
    ) as $parsed |
    ($parsed | map(.major) | max // 0) as $top |
    [
      $parsed
      | group_by(.major)[]
      | if .[0].major == $top
        then .[]
        else sort_by(.minor, .patch) | last
        end
    ]
    | sort_by(.major, .minor, .patch) | reverse | map(.tag)
  ' <<< "$1" 2>/dev/null || printf '%s' "$1"
}

# Merge two JSON arrays of version tag strings, deduplicate, and sort newest-first.
# Either argument may be missing or invalid — it is treated as [].
merge_version_arrays() {
  local a="${1:-[]}" b="${2:-[]}"
  jq -e 'type == "array"' <<< "$a" >/dev/null 2>&1 || a='[]'
  jq -e 'type == "array"' <<< "$b" >/dev/null 2>&1 || b='[]'

  local merged
  merged="$(jq -s 'add | unique' <<< "$a$b" 2>/dev/null || printf '[]')"
  jq -e 'type == "array"' <<< "$merged" >/dev/null 2>&1 || merged='[]'
  sort_versions "$merged"
}

# Render a JSON array of strings as a single-line Nix list: [ "a" "b" "c" ]
# Prints [] for an empty array.
json_to_nix_list() {
  local items
  items="$(jq -r '.[]' <<< "$1" 2>/dev/null \
    | sed 's/^/"/; s/$/"/' | paste -sd ' ' -)"
  [[ -z "$items" ]] && printf '[]' || printf '[ %s ]' "$items"
}

# ══════════════════════════════════════════════════════════════════════════════
# Nix file version bumping
# ══════════════════════════════════════════════════════════════════════════════

# bump_version_in_nix NIX_PATH CURRENT_VER CURRENT_VERS_JSON UPSTREAM_VERS_JSON NEWEST_TAG
#
# Rewrites $1 in-place when either condition is true:
#   a) The merged versions array contains new tags not already in the nix file.
#   b) The newest upstream semver tag is greater than the current pinned version.
#
# Returns 0 if the file was modified, 1 if nothing changed.
bump_version_in_nix() {
  local nix_path="$1" current="$2" current_versions_json="$3"
  local upstream_versions_json="$4" newest="$5"
  local modified=false

  local merged_versions
  merged_versions="$(merge_version_arrays "$current_versions_json" "$upstream_versions_json")"

  # ── Rewrite `versions = [ ... ];` when the merged list has grown ─────────────
  # Compare semantically (not as strings) so JSON formatting never causes false positives.
  if ! jq -e --argjson cur "$current_versions_json" '. == $cur' <<< "$merged_versions" >/dev/null 2>&1; then
    local nix_list
    nix_list="$(json_to_nix_list "$merged_versions")"

    if grep -q 'versions[[:space:]]*=[[:space:]]*\[' "$nix_path"; then
      if command -v perl >/dev/null 2>&1; then
        # perl handles the multi-line `versions = [ ... ];` case cleanly
        perl -i -0777 -pe \
          's/versions\s*=\s*\[.*?\];/versions     = '"$nix_list"';/s' \
          "$nix_path"
      else
        # awk fallback: consume every line between `versions = [` and `];`
        awk '
          /versions[[:space:]]*=[[:space:]]*\[/ { in_block=1 }
          in_block && /\];/ {
            print "    versions     = " merged ";"
            in_block=0; next
          }
          in_block { next }
          { print }
        ' merged="$nix_list" "$nix_path" > "$nix_path.tmp" \
          && mv "$nix_path.tmp" "$nix_path"
      fi
    else
      # No versions line present — insert one after `version = "...";`
      sed -i '/version[[:space:]]*=[[:space:]]*"[^"]*";/a\    versions     = '"$nix_list"';' \
        "$nix_path"
    fi

    printf '  [updated versions] %s\n' "$(basename "$(dirname "$nix_path")")"
    modified=true
  fi

  # ── Rewrite `version = "...";` when upstream has a strictly newer release ───
  local newest_stripped="${newest#v}"
  local current_stripped="${current#v}"
  if [[ -n "$newest_stripped" && "$newest_stripped" != "$current_stripped" ]]; then
    sed -i \
      "s/version[[:space:]]*=[[:space:]]*\"$current\"/version      = \"$newest_stripped\"/" \
      "$nix_path"
    printf '  [bumped version] %s: %s → %s\n' \
      "$(basename "$(dirname "$nix_path")")" "$current" "$newest_stripped"
    modified=true
  fi

  [[ "$modified" == true ]] && return 0 || return 1
}

# ══════════════════════════════════════════════════════════════════════════════
# Entry discovery
# ══════════════════════════════════════════════════════════════════════════════

# Emit lines of the form  "family|name|/abs/path/to/default.nix"  sorted.
# family is empty string for standalone flakes.
# Runs via process substitution so the nullglob change is scoped to this subshell.
discover_entries() {
  shopt -s nullglob
  local entries=()

  for top_dir in "$FLAKES_DIR"/*/; do
    [[ -d "$top_dir" ]] || continue
    local top_name
    top_name="$(basename "$top_dir")"
    is_excluded "$top_name" && continue

    if [[ -f "${top_dir}default.nix" ]]; then
      # Standalone: flakes/<name>/default.nix
      entries+=( "|${top_name}|$(realpath "${top_dir}default.nix")" )
    else
      # Family: each sub-directory with a default.nix is a member
      for child_dir in "$top_dir"*/; do
        [[ -d "$child_dir" ]] || continue
        local child_name
        child_name="$(basename "$child_dir")"
        is_excluded "$child_name" && continue
        [[ -f "${child_dir}default.nix" ]] || continue
        entries+=( "${top_name}|${child_name}|$(realpath "${child_dir}default.nix")" )
      done
    fi
  done

  printf '%s\n' "${entries[@]+"${entries[@]}"}" | sort
}

# ══════════════════════════════════════════════════════════════════════════════
# Nix evaluation  (always runs as a background job)
# ══════════════════════════════════════════════════════════════════════════════

# eval_entry FAMILY NAME NIX_PATH OUT_FILE
#
# Evaluates NIX_PATH with nix-instantiate and writes one JSON object to OUT_FILE.
#
# On success:  {family, name, hash, nix_path, meta, cached: false}
# Cache hit:   {family, name, hash, nix_path, meta, cached: true}
# On failure:  {family, name, nix_path, error: "<message>"}
#
# Must not write to stdout — callers capture stdout for other purposes.
eval_entry() {
  local family="$1" name="$2" nix_path="$3" out_file="$4"
  local current_hash family_json

  current_hash="$(file_hash "$nix_path")"
  family_json="$([ -n "$family" ] && jq -n --arg f "$family" '$f' || printf 'null')"

  # ── Cache hit: skip nix-instantiate when the file hash is unchanged ──────────
  if [[ -f "$CACHE_FILE_PATH" ]]; then
    local cached_meta
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

  # ── Fresh evaluation via nix-instantiate ─────────────────────────────────────
  # --strict forces deep evaluation so nested lists/attrs fully serialize to JSON
  # (without it, unevaluated thunks cause "cannot convert a thunk to JSON" errors).
  local nix_stdout="${out_file}.stdout"
  local nix_stderr="${out_file}.stderr"
  local nix_exit=0
  local cmd=(
    nix-instantiate --eval --strict --json
    "$EVAL_NIX" --arg flakePath "$nix_path"
  )

  vlog "${cmd[*]}"
  "${cmd[@]}" >"$nix_stdout" 2>"$nix_stderr" || nix_exit=$?

  if [[ $nix_exit -ne 0 ]]; then
    local err_text
    err_text="$(head -c 4096 "$nix_stderr" 2>/dev/null || true)"
    [[ -n "$err_text" ]] || err_text="nix-instantiate exited with code $nix_exit"
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
  if ! jq -e . <<< "$meta_json" >/dev/null 2>&1; then
    jq -n \
      --argjson family   "$family_json" \
      --arg     name     "$name" \
      --arg     nix_path "$nix_path" \
      --arg     error    "nix-instantiate produced invalid JSON" \
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

# ══════════════════════════════════════════════════════════════════════════════
# STEP 1 — Discover flake entries
# ══════════════════════════════════════════════════════════════════════════════

echo "Scanning flakes/..."

mapfile -t ENTRIES < <(discover_entries)

if [[ ${#ENTRIES[@]} -eq 0 ]]; then
  printf 'No flake entries found under %s\n' "$FLAKES_DIR" >&2
  exit 1
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 2 — Evaluate each entry in parallel (up to $WORKERS at once)
# ══════════════════════════════════════════════════════════════════════════════

OUT_FILES=()
IDX=0
RUNNING=0

for ENTRY in "${ENTRIES[@]}"; do
  IFS='|' read -r ENTRY_FAMILY ENTRY_NAME ENTRY_NIX_PATH <<< "$ENTRY"
  ENTRY_OUT="$WORK_DIR/$(printf '%06d' $IDX).json"
  IDX=$(( IDX + 1 ))
  OUT_FILES+=("$ENTRY_OUT")

  eval_entry "$ENTRY_FAMILY" "$ENTRY_NAME" "$ENTRY_NIX_PATH" "$ENTRY_OUT" &
  RUNNING=$(( RUNNING + 1 ))

  # Throttle: once we hit the worker limit, wait for one slot to free up
  if [[ $RUNNING -ge $WORKERS ]]; then
    wait -n 2>/dev/null || true
    RUNNING=$(( RUNNING - 1 ))
  fi
done

wait  # drain all remaining background jobs

# Merge every per-entry JSON file into a single array
RESULTS_JSON="$(jq -s '.' "${OUT_FILES[@]}")"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 3 — Print evaluation results and check for failures
# ══════════════════════════════════════════════════════════════════════════════

HAS_ERROR=false

jq -r '.[] |
  if   .error  then "  ✗ [" + (if .family then .family + "/" else "" end) + .name + "] eval failed"
  elif .cached then "  ● [" + (if .family then .family + "/" else "" end) + .name + "] (cached)"
  elif .family then "  ✓ [" + .name + "] member of " + .family
  else              "  ✓ [" + .name + "] standalone"
  end
' <<< "$RESULTS_JSON"

if jq -e '[.[] | select(.error)] | length > 0' <<< "$RESULTS_JSON" >/dev/null; then
  HAS_ERROR=true
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 4 — Fetch upstream version tags for every flake
# ══════════════════════════════════════════════════════════════════════════════
#
# Writes a TSV file with one row per flake:
#   name <TAB> all_tags_json <TAB> semver_tags_json
#
# This file is read later by both the --check-updates bump pass (step 5)
# and the versions-merge pass (step 6).

echo ""
echo "Collecting upstream version tags..."

VERSIONS_FILE="$WORK_DIR/versions.tsv"
{
  jq -r '.[] | select(.error == null) | [.name, (.meta.repo // "")] | @tsv' \
    <<< "$RESULTS_JSON" \
  | while IFS=$'\t' read -r flake_name repo_url; do
      if [[ -n "$repo_url" ]]; then
        all_tags="$(fetch_upstream_tags "$repo_url")"
        semver_tags="$(filter_semver_tags "$all_tags")"
        printf '  [%s] %s total tags, %s semver: %s\n' \
          "$flake_name" \
          "$(jq 'length' <<< "$all_tags")" \
          "$(jq 'length' <<< "$semver_tags")" \
          "$(jq -r '[.[]] | join(", ")' <<< "$semver_tags")" >&2
      else
        all_tags='[]'
        semver_tags='[]'
        printf '  [%s] no repo URL configured\n' "$flake_name" >&2
      fi
      printf '%s\t%s\t%s\n' "$flake_name" "$all_tags" "$semver_tags"
    done
} > "$VERSIONS_FILE"

# Look up the semver_tags JSON column for a given flake name.
get_semver_tags() {
  local result
  result="$(grep "^${1}"$'\t' "$VERSIONS_FILE" | cut -f3)"
  [[ -n "$result" ]] && printf '%s' "$result" || printf '[]'
}

# ══════════════════════════════════════════════════════════════════════════════
# STEP 5 — Bump version/versions in .nix files  (only with --check-updates)
# ══════════════════════════════════════════════════════════════════════════════
#
# Reads current version metadata from the eval results, compares against
# upstream semver tags, and rewrites the .nix files in-place when the upstream
# has new tags or a newer release. Collects bumped flake names for step 6.

BUMPED_NAMES=()

if [[ "$CHECK_UPDATES" == true ]]; then
  echo ""
  echo "Checking for upstream version updates..."

  while IFS=$'\t' read -r flake_name current_version current_versions_json nix_path; do
    [[ -n "$current_version" ]] || continue
    semver_tags="$(get_semver_tags "$flake_name")"
    newest="$(newest_version "$semver_tags")"
    if bump_version_in_nix \
        "$nix_path" "$current_version" "$current_versions_json" \
        "$semver_tags" "$newest"; then
      BUMPED_NAMES+=("$flake_name")
    fi
  done < <(jq -r '.[] | select(.error == null) |
      [.name, (.meta.version // ""), (.meta.versions // [] | tojson), .nix_path] | @tsv
    ' <<< "$RESULTS_JSON")
fi

# ══════════════════════════════════════════════════════════════════════════════
# STEP 6 — Merge upstream semver tags into each entry's versions field
# ══════════════════════════════════════════════════════════════════════════════
#
# Every successful entry gets a `.versions` field equal to the union of:
#   - The versions list from its .nix meta block
#   - All semver-matching tags fetched from upstream in step 4
#
# For entries that were bumped in step 5, `.meta.version` is also updated in
# the JSON result so the registry reflects the new version immediately — but
# only when a non-empty newest tag was found (guards against wiping a real
# version with an empty string when a repo has no semver tags at all).
#
# Note: this loop runs in a subshell (piped while-read). BUMPED_NAMES is
# readable as an inherited copy; output goes to a tmp file, not a variable.

MERGED_TMP="$WORK_DIR/results_merged.tmp"
: > "$MERGED_TMP"  # create the file so jq -s below always works

jq -r '.[] | select(.error == null) | @base64' <<< "$RESULTS_JSON" \
| while IFS= read -r entry_b64; do
    entry="$(printf '%s' "$entry_b64" | base64 -d)"
    flake_name="$(jq -r '.name' <<< "$entry")"
    semver_tags="$(get_semver_tags "$flake_name")"

    # Merge this entry's existing versions list with all upstream semver tags
    merged_versions="$(merge_version_arrays \
      "$(jq -r '.meta.versions // [] | tojson' <<< "$entry")" \
      "$semver_tags")"
    # Fall back to the meta list alone if merging produced invalid JSON
    jq -e 'type == "array"' <<< "$merged_versions" >/dev/null 2>&1 \
      || merged_versions="$(jq '.meta.versions // []' <<< "$entry")"

    # Prune superseded major versions: for every major below the highest,
    # keep only that major's single latest release.
    merged_versions="$(prune_old_major_versions "$merged_versions")"

    # Check if this flake was bumped in step 5
    was_bumped=false
    for bumped in "${BUMPED_NAMES[@]+"${BUMPED_NAMES[@]}"}"; do
      [[ "$bumped" == "$flake_name" ]] && { was_bumped=true; break; }
    done

    if [[ "$was_bumped" == true ]]; then
      newest="$(newest_version "$semver_tags")"
      newest_stripped="${newest#v}"
      if [[ -n "$newest_stripped" ]]; then
        # Upstream has a concrete release — update both version and versions
        entry="$(jq \
          --arg     newest "$newest_stripped" \
          --argjson merged "$merged_versions" \
          '.meta.version = $newest | .meta.versions = $merged | .versions = $merged' \
          <<< "$entry")"
      else
        # No semver tag found upstream — only update the versions list
        entry="$(jq \
          --argjson merged "$merged_versions" \
          '.meta.versions = $merged | .versions = $merged' \
          <<< "$entry")"
      fi
    else
      # Entry was not bumped — just attach the merged versions list
      entry="$(jq \
        --argjson merged "$merged_versions" \
        '.versions = $merged' \
        <<< "$entry")"
    fi

    printf '%s\n' "$entry"
  done >> "$MERGED_TMP"

# Append failed entries unchanged — they carry an .error field and need no version data
jq -c '.[] | select(.error != null)' <<< "$RESULTS_JSON" >> "$MERGED_TMP"

RESULTS_JSON="$(jq -s '.' "$MERGED_TMP")"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 7 — Save evaluation cache
# ══════════════════════════════════════════════════════════════════════════════
#
# Cache maps nix_path → {hash, meta}. On the next run, entries whose file hash
# hasn't changed skip nix-instantiate entirely (cache hit in eval_entry).

NEW_CACHE="$(jq '
  map(select(.error == null))
  | map({key: .nix_path, value: {hash: .hash, meta: .meta}})
  | from_entries
' <<< "$RESULTS_JSON")"

printf '%s\n' "$NEW_CACHE" > "${CACHE_FILE_PATH}.tmp"
mv "${CACHE_FILE_PATH}.tmp" "$CACHE_FILE_PATH"
vlog "cache saved → $CACHE_FILE_PATH"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 8 — Assemble the registry
# ══════════════════════════════════════════════════════════════════════════════
#
# Output schema:
#   {
#     schemaVersion: N,
#     flakes: {
#       "<name>": { ...meta fields..., family: null|"<family>", versions: [...] }
#     },
#     families: {
#       "<family>": { parent: "<name>"|null, children: [...], description: "..." }
#     }
#   }

echo ""
echo "Writing registry files..."

REGISTRY="$(jq -n \
  --argjson schema  "$SCHEMA_VERSION" \
  --argjson results "$RESULTS_JSON" \
  '
  # Only include successfully evaluated flakes
  ($results | map(select(.error == null))) as $ok |

  # Flat flakes map: name → merged meta fields + family + versions
  (
    $ok | map({
      key:   .name,
      value: (.meta + {family: .family, versions: (.versions // [])})
    }) | from_entries
  ) as $flakes |

  # Families map: family → { parent, children, description }
  # A "parent" entry is the one with role == "parent"; everything else is a child.
  (
    $ok
    | map(select(.family != null))
    | group_by(.family)
    | map(
        (.[0].family) as $fname |
        (map(select(.meta.role? == "parent")) | first | .name // null) as $parent |
        {
          key: $fname,
          value: {
            parent:      $parent,
            children:    (
              map(select(.meta.role? != "parent")) | map(.name) | map(select(. != $parent))
            ),
            description: (
              if $parent != null and $flakes[$parent] != null
              then ($flakes[$parent].description // $fname)
              else $fname end
            )
          }
        }
      )
    | from_entries
  ) as $families |

  {schemaVersion: $schema, flakes: $flakes, families: $families}
  ')"

# ── Write registry.json (atomic via tmp file) ─────────────────────────────────

JSON_OUT="$REPO_ROOT/registry.json"
printf '%s\n' "$REGISTRY" | jq '.' > "${JSON_OUT}.tmp"
mv "${JSON_OUT}.tmp" "$JSON_OUT"
printf '  Wrote %s\n' "$JSON_OUT"
vlog "$(wc -c < "$JSON_OUT") bytes"

# ── Write registry.yaml (atomic via tmp file) ─────────────────────────────────
#
# Uses PyYAML for human-friendly indented output when available.
# Falls back to JSON-formatted YAML (valid YAML, just less readable).
# Install python3-pyyaml to get the pretty version.

YAML_OUT="$REPO_ROOT/registry.yaml"
{
  printf '# Auto-generated by scripts/gen-registry.sh — do not edit manually.\n'
  printf '# Source of truth: flakes/*/default.nix (meta block)\n\n'
  if python3 -c "import yaml" 2>/dev/null; then
    printf '%s\n' "$REGISTRY" | python3 -c "
import sys, json, yaml
data = json.load(sys.stdin)
sys.stdout.write(yaml.dump(data, default_flow_style=False, allow_unicode=True, sort_keys=False))
"
  else
    printf '# (PyYAML not available — output is JSON-formatted YAML)\n\n'
    printf '%s\n' "$REGISTRY" | jq '.'
  fi
} > "${YAML_OUT}.tmp"
mv "${YAML_OUT}.tmp" "$YAML_OUT"
printf '  Wrote %s\n' "$YAML_OUT"
vlog "$(wc -c < "$YAML_OUT") bytes"

# ══════════════════════════════════════════════════════════════════════════════
# STEP 9 — Summary and exit
# ══════════════════════════════════════════════════════════════════════════════

N_FLAKES="$(jq '.flakes | length'   <<< "$REGISTRY")"
N_FAMILIES="$(jq '.families | length' <<< "$REGISTRY")"
printf '\nDone — %s flake(s), %s famil(ies).\n' "$N_FLAKES" "$N_FAMILIES"

if [[ "$HAS_ERROR" == true ]]; then
  N_ERRORS="$(jq '[.[] | select(.error)] | length' <<< "$RESULTS_JSON")"
  printf '\n%s flake(s) failed to evaluate:\n' "$N_ERRORS" >&2
  jq -r '.[] | select(.error) |
    "  ✗ [" + (if .family then .family + "/" else "" end) + .name + "] " + .error
  ' <<< "$RESULTS_JSON" >&2
  exit 1
fi
