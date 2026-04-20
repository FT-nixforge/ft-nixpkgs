#!/usr/bin/env bash
# add-flake.sh — interactively add a public GitHub flake to ft-nixpkgs
#
# Usage:
#   bash scripts/add-flake.sh [OPTIONS] [REPO]
#
# REPO can be any of:
#   nixbar                           → assumes github:<you>/nixbar  (detected from gh/git)
#   FT-nixforge/nixbar
#   github:FT-nixforge/nixbar
#   https://github.com/FT-nixforge/nixbar
#
# Options:
#   --dry-run, -n    Preview what would be created/changed without writing files
#   --verbose, -v    Print debug info (curl commands, raw JSON, file sizes)
#   --help, -h       Show this help text
#
# The target repo must have a ft-nixpkgs.json file in its root.
# See scripts/ft-nixpkgs.example.json for the expected format.
#
# Environment:
#   FT_REPO_ROOT  Override the ft-nixpkgs repo root (set automatically by
#                 `nix run .#add-flake`; defaults to the script's parent dir)
#
# Dependencies: curl, jq, python3 (optional — for registry regen)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# FT_REPO_ROOT lets `nix run .#add-flake` point at the caller's checkout.
REPO_ROOT="${FT_REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FLAKES_DIR="$REPO_ROOT/flakes"
FLAKE_NIX="$REPO_ROOT/flake.nix"

# shellcheck source=tui.sh
. "$SCRIPT_DIR/tui.sh"

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

die()   { echo -e "${RED}ERROR:${NC} $*" >&2; exit 1; }
info()  { echo -e "${BLUE}→${NC} $*"; }
ok()    { echo -e "${GREEN}✓${NC} $*"; }
warn()  { echo -e "${YELLOW}⚠${NC} $*"; }
ask()   { echo -e "${BOLD}?${NC} $*"; }
vecho() { $VERBOSE && echo -e "${BLUE}[verbose]${NC} $*" >&2 || true; }

# ── Detect GitHub username ────────────────────────────────────────────────────
# Tries (in order):  gh CLI → git config github.user → git config user.name → ""
get_github_username() {
  if command -v gh &>/dev/null; then
    local u
    u="$(gh api user --jq '.login' 2>/dev/null)" && [[ -n "$u" ]] && { echo "$u"; return; }
  fi
  local u
  u="$(git config --global github.user 2>/dev/null)" && [[ -n "$u" ]] && { echo "$u"; return; }
  u="$(git config --global user.name 2>/dev/null)"  && [[ -n "$u" ]] && { echo "$u"; return; }
  echo ""
}

# ── Dependency check ──────────────────────────────────────────────────────────
for cmd in curl jq python3; do
  command -v "$cmd" &>/dev/null || die "Required tool not found: $cmd"
done

# ── Escape a string for use inside a Nix double-quoted string ─────────────────
# Nix double-quoted strings interpolate ${...}, so we must escape:
#   \  →  \\
#   "  →  \"
#   ${ →  \${
nix_escape() {
  local s="$1"
  s="${s//\\/\\\\}"    # backslash first
  s="${s//\"/\\\"}"    # double-quote
  s="${s//\$\{/\\\${}" # ${ interpolation
  printf '%s' "$s"
}

# ── Manual metadata collection (used when ft-nixpkgs.json is absent) ──────────
collect_manual_meta() {
  echo ""
  warn "You will be prompted for each required field."
  warn "Press Ctrl-C at any time to abort."

  local name description version
  local type role family status
  local -a provides deps

  # name — plain text
  ask "name (e.g. ft-nixbar):"; read -r name

  # type — single-select
  select_one "type" type  library bundle module package app

  # role — single-select
  select_one "role" role  parent child standalone

  # family — read existing family dirs + "standalone (no family)" as first option
  local -a family_opts=("standalone (no family)")
  local d
  for d in "$FLAKES_DIR"/*/; do
    [[ -d "$d" && ! -f "${d}default.nix" ]] && family_opts+=("$(basename "$d")")
  done
  local family_sel
  select_one "family" family_sel "${family_opts[@]}"
  [[ "$family_sel" == "standalone (no family)" ]] && family="" || family="$family_sel"

  # description — plain text
  ask "description (one line):"; read -r description

  # provides — multi-select
  select_many "provides" provides  packages nixosModules homeModules lib

  # dependencies — searchable multi-select from known flakes
  local -a known_flakes=()
  for d in "$FLAKES_DIR"/*/; do
    [[ -f "${d}default.nix" ]] && known_flakes+=("$(basename "$d")")
  done
  for d in "$FLAKES_DIR"/*/*/; do
    [[ -f "${d}default.nix" ]] && known_flakes+=("$(basename "$d")")
  done
  if [[ ${#known_flakes[@]} -gt 0 ]]; then
    select_search "dependencies" deps "${known_flakes[@]}"
  else
    deps=()
    warn "No flakes found in registry yet — skipping dependency selector."
  fi

  # status — single-select
  select_one "status" status  experimental wip stable deprecated

  # version — plain text with default
  ask "version [0.1.0]:"; read -r version
  version="${version:-0.1.0}"

  # Build JSON output
  local provides_json deps_json family_val
  provides_json="$(printf '%s\n' "${provides[@]+"${provides[@]}"}" | jq -Rcs '[split("\n")[] | select(length > 0)]')"
  deps_json="$(printf '%s\n' "${deps[@]+"${deps[@]}"}" | jq -Rcs '[split("\n")[] | select(length > 0)]')"
  family_val="$([ -n "$family" ] && echo "\"$family\"" || echo "null")"

  jq -n \
    --arg     name        "$name" \
    --arg     type        "$type" \
    --arg     role        "$role" \
    --argjson family      "$family_val" \
    --arg     description "$description" \
    --argjson provides    "$provides_json" \
    --argjson dependencies "$deps_json" \
    --arg     status      "$status" \
    --arg     version     "$version" \
    '{name:$name, type:$type, role:$role, family:$family,
      description:$description, provides:$provides,
      dependencies:$dependencies, status:$status, version:$version}'
}

# ── Validate required metadata fields ────────────────────────────────────────
validate_meta() {
  local errors=()

  [[ -z "$FLAKE_NAME" ]]    && errors+=("'name' is required")
  [[ -z "$FLAKE_TYPE" ]]    && errors+=("'type' is required")
  [[ -z "$FLAKE_ROLE" ]]    && errors+=("'role' is required")
  [[ -z "$FLAKE_DESC" ]]    && errors+=("'description' is required")
  [[ -z "$FLAKE_STATUS" ]]  && errors+=("'status' is required")
  [[ -z "$FLAKE_VERSION" ]] && errors+=("'version' is required")

  local valid_types=("library" "bundle" "module" "package" "app")
  if [[ -n "$FLAKE_TYPE" ]] && ! printf '%s\n' "${valid_types[@]}" | grep -qx "$FLAKE_TYPE"; then
    errors+=("'type' must be one of: ${valid_types[*]} — got: '$FLAKE_TYPE'")
  fi

  local valid_roles=("parent" "child" "standalone")
  if [[ -n "$FLAKE_ROLE" ]] && ! printf '%s\n' "${valid_roles[@]}" | grep -qx "$FLAKE_ROLE"; then
    errors+=("'role' must be one of: ${valid_roles[*]} — got: '$FLAKE_ROLE'")
  fi

  local valid_statuses=("experimental" "wip" "stable" "deprecated")
  if [[ -n "$FLAKE_STATUS" ]] && ! printf '%s\n' "${valid_statuses[@]}" | grep -qx "$FLAKE_STATUS"; then
    errors+=("'status' must be one of: ${valid_statuses[*]} — got: '$FLAKE_STATUS'")
  fi

  if [[ ${#errors[@]} -gt 0 ]]; then
    echo -e "${RED}Metadata validation failed:${NC}" >&2
    for e in "${errors[@]}"; do
      echo "  - $e" >&2
    done
    exit 1
  fi
}

# ── Argument parsing ──────────────────────────────────────────────────────────
DRY_RUN=false
VERBOSE=false
POSITIONAL_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run|-n)
      DRY_RUN=true
      shift
      ;;
    --verbose|-v)
      VERBOSE=true
      shift
      ;;
    --help|-h)
      sed -n '2,/^[^#]/{ /^#/{ s/^# \?//; p }; /^[^#]/q }' "$0"
      exit 0
      ;;
    -*)
      die "Unknown option: $1 (try --help)"
      ;;
    *)
      POSITIONAL_ARGS+=("$1")
      shift
      ;;
  esac
done

$DRY_RUN && warn "Dry-run mode — no files will be written."
vecho "Repo root: $REPO_ROOT"

# ── Parse repo argument ───────────────────────────────────────────────────────
if [[ ${#POSITIONAL_ARGS[@]} -ge 1 ]]; then
  RAW_INPUT="${POSITIONAL_ARGS[0]}"
else
  ask "Enter the flake repo (e.g. FT-nixforge/nixbar or github:... or https://github.com/...):"
  read -r RAW_INPUT
fi

RAW_INPUT="${RAW_INPUT// /}"  # strip spaces

# Normalise to owner/repo
if [[ "$RAW_INPUT" =~ ^https://github\.com/([^/]+)/([^/]+)/?$ ]]; then
  OWNER="${BASH_REMATCH[1]}"
  REPO_NAME="${BASH_REMATCH[2]%.git}"
elif [[ "$RAW_INPUT" =~ ^github:([^/]+)/([^/]+)$ ]]; then
  OWNER="${BASH_REMATCH[1]}"
  REPO_NAME="${BASH_REMATCH[2]}"
elif [[ "$RAW_INPUT" =~ ^([^/]+)/([^/]+)$ ]]; then
  OWNER="${BASH_REMATCH[1]}"
  REPO_NAME="${BASH_REMATCH[2]}"
elif [[ "$RAW_INPUT" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  REPO_NAME="$RAW_INPUT"
  DETECTED_USER="$(get_github_username)"
  if [[ -n "$DETECTED_USER" ]]; then
    OWNER="$DETECTED_USER"
    vecho "Detected GitHub user: $DETECTED_USER"
  else
    ask "Could not detect your GitHub username. Enter the owner/org for '${REPO_NAME}':"
    read -r OWNER
    [[ -n "$OWNER" ]] || die "Owner is required when using a bare repo name."
  fi
else
  die "Cannot parse repo: '$RAW_INPUT'"
fi

FLAKE_URL="github:${OWNER}/${REPO_NAME}"
RAW_BASE="https://raw.githubusercontent.com/${OWNER}/${REPO_NAME}/HEAD"

echo ""
info "Repo:      ${BOLD}${OWNER}/${REPO_NAME}${NC}"
info "Flake URL: ${BOLD}${FLAKE_URL}${NC}"

# Warn when adding a repo outside the FT-nixforge organisation
if [[ "$OWNER" != "FT-nixforge" ]]; then
  echo ""
  warn "This repo is outside the FT-nixforge organisation."
  warn "You are trusting metadata from an external source."
  ask "Continue anyway? [y/N]"
  read -r EXT_CONFIRM
  [[ "$EXT_CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi
echo ""

# ── Verify flake.nix exists ───────────────────────────────────────────────────
info "Checking for flake.nix in repo..."
vecho "curl -s -o /dev/null -w '%{http_code}' ${RAW_BASE}/flake.nix"
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "${RAW_BASE}/flake.nix")
if [[ "$HTTP_STATUS" != "200" ]]; then
  die "No flake.nix found in ${OWNER}/${REPO_NAME} (HTTP ${HTTP_STATUS}).\nThis repo does not appear to be a Nix flake."
fi
ok "flake.nix found"

# ── Fetch ft-nixpkgs.json ─────────────────────────────────────────────────────
info "Fetching ft-nixpkgs.json..."
vecho "curl -s -f ${RAW_BASE}/ft-nixpkgs.json"
META_JSON=$(curl -s -f "${RAW_BASE}/ft-nixpkgs.json" 2>/dev/null || true)

if [[ -z "$META_JSON" ]]; then
  warn "No ft-nixpkgs.json found in ${OWNER}/${REPO_NAME}."
  echo ""
  echo "  The upstream repo should include a ft-nixpkgs.json metadata file."
  echo "  See scripts/ft-nixpkgs.example.json for the format."
  echo ""
  ask "Do you want to enter the metadata manually instead? [y/N]"
  read -r MANUAL_CONFIRM
  if [[ ! "$MANUAL_CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
  fi
  META_JSON="$(collect_manual_meta)"
else
  ok "ft-nixpkgs.json fetched"
  vecho "Raw JSON:"
  $VERBOSE && echo "$META_JSON" | jq . >&2 || true
fi

# ── Validate JSON ─────────────────────────────────────────────────────────────
if ! echo "$META_JSON" | jq -e . &>/dev/null; then
  die "ft-nixpkgs.json is not valid JSON."
fi

jq_get() { echo "$META_JSON" | jq -r "$1 // empty"; }

FLAKE_NAME="$(jq_get '.name')"
FLAKE_TYPE="$(jq_get '.type')"
FLAKE_ROLE="$(jq_get '.role')"
FLAKE_FAMILY="$(jq_get '.family')"
FLAKE_DESC="$(jq_get '.description')"
FLAKE_STATUS="$(jq_get '.status')"
FLAKE_VERSION="$(jq_get '.version')"
PROVIDES_RAW="$(echo "$META_JSON" | jq -c '.provides // []')"
DEPS_RAW="$(echo "$META_JSON" | jq -c '.dependencies // []')"

# ── Validate required fields & allowed values ─────────────────────────────────
validate_meta

# ── Check schema version ──────────────────────────────────────────────────────
FT_SCHEMA_EXPECTED=1
SCHEMA_VER="$(echo "$META_JSON" | jq -r '.schemaVersion // "absent"')"
if [[ "$SCHEMA_VER" != "absent" && "$SCHEMA_VER" != "$FT_SCHEMA_EXPECTED" ]]; then
  warn "ft-nixpkgs.json has schemaVersion '${SCHEMA_VER}' but this script expects version ${FT_SCHEMA_EXPECTED}."
  warn "Metadata parsing may be unreliable — please check for a newer version of ft-nixpkgs."
fi

# ── Derive Nix input attribute name ──────────────────────────────────────────
INPUT_ATTR="$REPO_NAME"

# ── Show parsed metadata & confirm ───────────────────────────────────────────
echo ""
echo -e "${BOLD}Parsed metadata:${NC}"
echo "  name:         ${FLAKE_NAME}"
echo "  type:         ${FLAKE_TYPE}"
echo "  role:         ${FLAKE_ROLE}"
echo "  family:       ${FLAKE_FAMILY:-(none — standalone)}"
echo "  description:  ${FLAKE_DESC}"
echo "  status:       ${FLAKE_STATUS}"
echo "  version:      ${FLAKE_VERSION}"
echo "  provides:     $(echo "$PROVIDES_RAW" | jq -r 'join(", ")')"
echo "  dependencies: $(echo "$DEPS_RAW" | jq -r 'join(", ") | if . == "" then "(none)" else . end')"
echo "  nix input:    ${INPUT_ATTR}.url = \"${FLAKE_URL}\""
echo ""

ask "Continue adding this flake? [Y/n]"
read -r CONFIRM
if [[ "$CONFIRM" =~ ^[Nn]$ ]]; then
  echo "Aborted."
  exit 0
fi

# ── Determine target directory ────────────────────────────────────────────────
if [[ -n "$FLAKE_FAMILY" ]]; then
  TARGET_DIR="$FLAKES_DIR/${FLAKE_FAMILY}/${REPO_NAME}"
else
  TARGET_DIR="$FLAKES_DIR/${REPO_NAME}"
fi

if [[ -d "$TARGET_DIR" ]] && ! $DRY_RUN; then
  warn "Directory already exists: $TARGET_DIR"
  ask "Overwrite? [y/N]"
  read -r OVERWRITE
  [[ "$OVERWRITE" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi

# ── Generate provides booleans ────────────────────────────────────────────────
HAS_PACKAGES=false; HAS_NIXOS=false; HAS_HOME=false; HAS_LIB=false
while IFS= read -r p; do
  case "$p" in
    packages)     HAS_PACKAGES=true ;;
    nixosModules) HAS_NIXOS=true ;;
    homeModules)  HAS_HOME=true ;;
    lib)          HAS_LIB=true ;;
  esac
done < <(echo "$PROVIDES_RAW" | jq -r '.[]')

# ── Build escaped values for the Nix template ─────────────────────────────────
NIX_NAME="$(nix_escape "$FLAKE_NAME")"
NIX_TYPE="$(nix_escape "$FLAKE_TYPE")"
NIX_ROLE="$(nix_escape "$FLAKE_ROLE")"
NIX_DESC="$(nix_escape "$FLAKE_DESC")"
NIX_REPO="$(nix_escape "$FLAKE_URL")"
NIX_STATUS="$(nix_escape "$FLAKE_STATUS")"
NIX_VERSION="$(nix_escape "$FLAKE_VERSION")"
NIX_PROVIDES="$(echo "$PROVIDES_RAW" | jq -r '[ .[] | "\"" + . + "\"" ] | "[ " + join(" ") + " ]"')"
NIX_DEPS="$(echo "$DEPS_RAW" | jq -r '[ .[] | "\"" + . + "\"" ] | "[ " + join(" ") + " ]"')"

# ── Generate the default.nix content ─────────────────────────────────────────
# Use printf so that special characters in metadata values cannot break the output.
generate_default_nix() {
printf '{ inputs, system, pkgsLib, ... }:\n\n'
printf 'let\n'
printf '  flake = inputs.%s;\n' "$INPUT_ATTR"
printf 'in\n'
printf '{\n'
printf '  meta = {\n'
printf '    name         = "%s";\n'  "$NIX_NAME"
printf '    type         = "%s";    # library | bundle | module | package | app\n' "$NIX_TYPE"
printf '    role         = "%s";    # parent | child | standalone\n' "$NIX_ROLE"
printf '    description  = "%s";\n' "$NIX_DESC"
printf '    repo         = "%s";\n' "$NIX_REPO"
printf '    provides     = %s;\n'   "$NIX_PROVIDES"
printf '    dependencies = %s;\n'   "$NIX_DEPS"
printf '    status       = "%s";  # experimental | wip | stable | deprecated\n' "$NIX_STATUS"
printf '    version      = "%s";\n' "$NIX_VERSION"
printf '  };\n\n'

if $HAS_PACKAGES; then
  printf '  packages    = flake.packages.${system} or {};\n'
else
  printf '  packages    = {};\n'
fi

if $HAS_NIXOS; then
  printf '  nixosModule = flake.nixosModules.default or null;\n'
else
  printf '  nixosModule = null;\n'
fi

if $HAS_HOME; then
  printf '  # Handles both homeModules and homeManagerModules output conventions\n'
  printf '  homeModule  = flake.homeModules.default or flake.homeManagerModules.default or null;\n'
else
  printf '  homeModule  = null;\n'
fi

$HAS_LIB && printf '  lib         = flake.lib or {};\n'

printf '\n  overlay = _final: prev: {\n'
printf '    %s = (flake.packages.${prev.system} or {}).default or null;\n' "$REPO_NAME"
printf '  };\n'
printf '}\n'
}

# ── Write (or preview) flakes/<folder>/default.nix ───────────────────────────
if $DRY_RUN; then
  echo ""
  info "[DRY RUN] Would create: ${TARGET_DIR}/default.nix"
  echo "  ┌─────────────────────────────────────────────────────────"
  generate_default_nix | sed 's/^/  │ /'
  echo "  └─────────────────────────────────────────────────────────"
else
  info "Writing $TARGET_DIR/default.nix..."
  mkdir -p "$TARGET_DIR"
  generate_default_nix > "$TARGET_DIR/default.nix"
  ok "Wrote $TARGET_DIR/default.nix"
fi

# ── Patch (or preview) flake.nix — add new input ─────────────────────────────
echo ""
info "$(  $DRY_RUN && echo '[DRY RUN] Would add input to' || echo 'Adding input to') flake.nix..."

if grep -qP "^\s*${INPUT_ATTR}\.url\s*=" "$FLAKE_NIX" 2>/dev/null || \
   grep -q "  ${INPUT_ATTR}\.url" "$FLAKE_NIX"; then
  warn "Input '${INPUT_ATTR}' already exists in flake.nix — skipping input patch."
elif $DRY_RUN; then
  echo ""
  echo "  Would insert into flake.nix inputs block:"
  echo "    ${INPUT_ATTR}.url = \"${FLAKE_URL}\";"
  echo ""
else
  python3 - "$FLAKE_NIX" "$INPUT_ATTR" "$FLAKE_URL" <<'PYEOF'
import sys, re, os, tempfile

flake_nix, input_attr, flake_url = sys.argv[1], sys.argv[2], sys.argv[3]

with open(flake_nix, 'r') as f:
    content = f.read()

new_line = f'    {input_attr}.url = "{flake_url}";\n'

# Prefer inserting before the "# ── Planned" comment block
marker = '    # ── Planned'
if marker in content:
    patched = content.replace(marker, new_line + marker, 1)
else:
    # Fallback: insert before the closing brace of the inputs block
    patched = re.sub(
        r'(  \};\n\n  outputs)',
        new_line + r'\1',
        content,
        count=1,
    )

if new_line.strip() not in patched:
    print(f"ERROR: could not locate insertion point in {flake_nix}", file=sys.stderr)
    sys.exit(1)

# Atomic write: write to a temp file then rename
tmp = flake_nix + '.tmp'
with open(tmp, 'w') as f:
    f.write(patched)
os.replace(tmp, flake_nix)
print(f"  patched {flake_nix}")
PYEOF

  # Verify the patch actually landed
  if ! grep -q "  ${INPUT_ATTR}\.url" "$FLAKE_NIX"; then
    die "Patch did not apply — '${INPUT_ATTR}.url' not found in flake.nix after patching.\nPlease add the input manually:\n  ${INPUT_ATTR}.url = \"${FLAKE_URL}\";"
  fi

  ok "Added '${INPUT_ATTR}.url = \"${FLAKE_URL}\";' to flake.nix"
fi

# ── Regenerate (or skip) registry ────────────────────────────────────────────
echo ""
if $DRY_RUN; then
  info "[DRY RUN] Would run: bash scripts/gen-registry.sh"
elif [[ -f "$SCRIPT_DIR/gen-registry.sh" ]]; then
  info "Regenerating registry..."
  bash "$SCRIPT_DIR/gen-registry.sh" --repo-root "$REPO_ROOT" \
    $($VERBOSE && echo "--verbose" || true)
  ok "Registry updated"
elif [[ -f "$SCRIPT_DIR/gen-registry.py" ]]; then
  info "Regenerating registry (via Python fallback)..."
  python3 "$SCRIPT_DIR/gen-registry.py" --repo-root "$REPO_ROOT" \
    $($VERBOSE && echo "--verbose" || true)
  ok "Registry updated"
else
  warn "gen-registry script not found — run it manually to update the registry."
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
if $DRY_RUN; then
  echo -e "${YELLOW}${BOLD}Dry run complete.${NC} No files were written."
  echo "Re-run without --dry-run to apply the changes."
else
  echo -e "${GREEN}${BOLD}Done!${NC} Flake '${FLAKE_NAME}' added to ft-nixpkgs."
  echo ""
  echo "Next steps:"
  echo "  1. Review generated file:  $TARGET_DIR/default.nix"
  echo "  2. Review patched input:   $FLAKE_NIX"
  echo "  3. nix flake update ${INPUT_ATTR}   (adds it to flake.lock)"
  echo "  4. nix flake show"
  echo "  5. Commit and push"
fi
echo ""
