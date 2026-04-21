#!/usr/bin/env bash
# add-flake.sh — add a public GitHub flake to ft-nixpkgs
#
# Intended to be called by the GitHub Actions workflow at
# .github/workflows/add-flake.yml — but also works locally.
#
# Usage:
#   bash scripts/add-flake.sh [OPTIONS] REPO
#
# REPO can be any of:
#   ft-nixpalette
#   FT-nixforge/ft-nixpalette
#   github:FT-nixforge/ft-nixpalette
#   https://github.com/FT-nixforge/ft-nixpalette
#
# The target flake must export `outputs.meta` — metadata is fetched via
# `nix eval github:OWNER/REPO#meta --json`.  There is no interactive fallback;
# use the --dry-run flag to preview without writing anything.
#
# Options:
#   --dry-run, -n          Preview without writing files
#   --verbose, -v          Extra output
#   --non-interactive      Skip all yes/no confirmation prompts (used by CI)
#   --family FAMILY        Place config under flakes/<family>/<name>/ instead of standalone
#   --help, -h             Show this help text
#
# Environment:
#   FT_REPO_ROOT  Override repo root (set automatically by `nix run .#add-flake`)
#
# Dependencies: curl, jq, nix, python3

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${FT_REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FLAKES_DIR="$REPO_ROOT/flakes"
FLAKE_NIX="$REPO_ROOT/flake.nix"

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
die()   { echo -e "${RED}error:${NC} $*" >&2; exit 1; }
info()  { echo -e "${BLUE}→${NC} $*"; }
ok()    { echo -e "${GREEN}✓${NC} $*"; }
warn()  { echo -e "${YELLOW}⚠${NC} $*"; }
vecho() { $VERBOSE && echo -e "${BLUE}[v]${NC} $*" >&2 || true; }

# ── Deps ──────────────────────────────────────────────────────────────────────
for cmd in curl jq python3 nix; do
  command -v "$cmd" &>/dev/null || die "Required tool not found: $cmd"
done

# ── Detect GitHub username ────────────────────────────────────────────────────
get_github_username() {
  if command -v gh &>/dev/null; then
    local u; u="$(gh api user --jq '.login' 2>/dev/null || true)"
    [[ -n "$u" ]] && { echo "$u"; return; }
  fi
  local u
  u="$(git config --global github.user 2>/dev/null || true)"
  [[ -n "$u" ]] && { echo "$u"; return; }
  git config --global user.name 2>/dev/null || true
}

# ── Escape a string for Nix double-quoted strings ────────────────────────────
nix_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//\$\{/\\\$\{}"
  printf '%s' "$s"
}

# ── Argument parsing ──────────────────────────────────────────────────────────
DRY_RUN=false; VERBOSE=false; NON_INTERACTIVE=false
FLAKE_FAMILY=""
POSITIONAL_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run|-n)        DRY_RUN=true ;;
    --verbose|-v)        VERBOSE=true ;;
    --non-interactive)   NON_INTERACTIVE=true ;;
    --family)            shift; FLAKE_FAMILY="$1" ;;
    --help|-h)
      sed -n '2,/^[^#]/{ /^#/{ s/^# \?//; p }; /^[^#]/q }' "$0"
      exit 0 ;;
    -*) die "Unknown option: $1 (try --help)" ;;
    *)  POSITIONAL_ARGS+=("$1") ;;
  esac
  shift
done

$DRY_RUN && warn "Dry-run mode — no files will be written."
vecho "Repo root: $REPO_ROOT"

# ── Parse repo argument ───────────────────────────────────────────────────────
if [[ ${#POSITIONAL_ARGS[@]} -ge 1 ]]; then
  RAW_INPUT="${POSITIONAL_ARGS[0]}"
else
  die "No repo specified. Usage: add-flake.sh [OPTIONS] REPO"
fi

RAW_INPUT="${RAW_INPUT// /}"

if [[ "$RAW_INPUT" =~ ^https://github\.com/([^/]+)/([^/]+?)(/?)$ ]]; then
  OWNER="${BASH_REMATCH[1]}"; REPO_NAME="${BASH_REMATCH[2]%.git}"
elif [[ "$RAW_INPUT" =~ ^github:([^/]+)/([^/]+)$ ]]; then
  OWNER="${BASH_REMATCH[1]}"; REPO_NAME="${BASH_REMATCH[2]}"
elif [[ "$RAW_INPUT" =~ ^([^/]+)/([^/]+)$ ]]; then
  OWNER="${BASH_REMATCH[1]}"; REPO_NAME="${BASH_REMATCH[2]}"
elif [[ "$RAW_INPUT" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  REPO_NAME="$RAW_INPUT"
  DETECTED_USER="$(get_github_username)"
  [[ -n "$DETECTED_USER" ]] || die "Cannot detect GitHub owner for bare name '$REPO_NAME'. Use owner/repo format."
  OWNER="$DETECTED_USER"
else
  die "Cannot parse repo: '$RAW_INPUT'"
fi

FLAKE_URL="github:${OWNER}/${REPO_NAME}"
RAW_BASE="https://raw.githubusercontent.com/${OWNER}/${REPO_NAME}/HEAD"

echo ""
info "Repo:      ${BOLD}${OWNER}/${REPO_NAME}${NC}"
info "Flake URL: ${BOLD}${FLAKE_URL}${NC}"

if [[ "$OWNER" != "FT-nixforge" ]]; then
  warn "This repo is outside the FT-nixforge organisation — trusting external metadata."
  if ! $NON_INTERACTIVE; then
    echo -e "${BOLD}?${NC} Continue anyway? [y/N]"
    read -r EXT_CONFIRM
    [[ "$EXT_CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
  fi
fi
echo ""

# ── Verify flake.nix exists ───────────────────────────────────────────────────
info "Checking upstream flake.nix..."
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "${RAW_BASE}/flake.nix")
[[ "$HTTP_STATUS" == "200" ]] || die "No flake.nix found in ${OWNER}/${REPO_NAME} (HTTP ${HTTP_STATUS})."
ok "flake.nix found"

# ── Fetch metadata via nix eval ───────────────────────────────────────────────
info "Fetching metadata via nix eval ${FLAKE_URL}#meta..."
META_JSON="$(nix eval "${FLAKE_URL}#meta" --json \
  --extra-experimental-features 'nix-command flakes' 2>/dev/null)" \
  || die "nix eval failed.\nMake sure the flake exports:  outputs.meta = { name = ...; type = ...; ... };"

[[ -n "$META_JSON" ]] || die "nix eval returned empty output."
ok "metadata fetched"
vecho "Raw JSON:"; $VERBOSE && echo "$META_JSON" | jq . >&2 || true

if ! echo "$META_JSON" | jq -e . &>/dev/null; then
  die "Fetched metadata is not valid JSON."
fi

# ── Parse fields ──────────────────────────────────────────────────────────────
jq_get() { echo "$META_JSON" | jq -r "$1 // empty"; }

FLAKE_NAME="$(jq_get '.name')"
FLAKE_TYPE="$(jq_get '.type')"
FLAKE_ROLE="$(jq_get '.role')"
FLAKE_DESC="$(jq_get '.description')"
FLAKE_STATUS="$(jq_get '.status')"
FLAKE_VERSION="$(jq_get '.version')"
PROVIDES_RAW="$(echo "$META_JSON" | jq -c '.provides // []')"
DEPS_RAW="$(echo "$META_JSON" | jq -c '.dependencies // []')"

# ── Validate ──────────────────────────────────────────────────────────────────
errors=()
[[ -z "$FLAKE_NAME" ]]    && errors+=("meta.name is missing")
[[ -z "$FLAKE_TYPE" ]]    && errors+=("meta.type is missing")
[[ -z "$FLAKE_ROLE" ]]    && errors+=("meta.role is missing")
[[ -z "$FLAKE_DESC" ]]    && errors+=("meta.description is missing")
[[ -z "$FLAKE_STATUS" ]]  && errors+=("meta.status is missing")
[[ -z "$FLAKE_VERSION" ]] && errors+=("meta.version is missing")

valid_types=("library" "bundle" "module" "package" "app")
if [[ -n "$FLAKE_TYPE" ]] && ! printf '%s\n' "${valid_types[@]}" | grep -qx "$FLAKE_TYPE"; then
  errors+=("meta.type '$FLAKE_TYPE' is not valid (${valid_types[*]})")
fi
valid_roles=("parent" "child" "standalone")
if [[ -n "$FLAKE_ROLE" ]] && ! printf '%s\n' "${valid_roles[@]}" | grep -qx "$FLAKE_ROLE"; then
  errors+=("meta.role '$FLAKE_ROLE' is not valid (${valid_roles[*]})")
fi
valid_statuses=("unstable" "beta" "stable" "experimental" "wip" "deprecated")
if [[ -n "$FLAKE_STATUS" ]] && ! printf '%s\n' "${valid_statuses[@]}" | grep -qx "$FLAKE_STATUS"; then
  errors+=("meta.status '$FLAKE_STATUS' is not valid (${valid_statuses[*]})")
fi

if [[ ${#errors[@]} -gt 0 ]]; then
  echo -e "${RED}Metadata validation failed:${NC}" >&2
  for e in "${errors[@]}"; do echo "  - $e" >&2; done
  exit 1
fi
ok "metadata validated"

# ── Nix input attribute name (from meta.name) ─────────────────────────────────
INPUT_ATTR="$FLAKE_NAME"

# ── Show summary + confirm ────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Metadata:${NC}"
echo "  name:         ${FLAKE_NAME}"
echo "  type:         ${FLAKE_TYPE}"
echo "  role:         ${FLAKE_ROLE}"
echo "  family:       ${FLAKE_FAMILY:-(standalone)}"
echo "  description:  ${FLAKE_DESC}"
echo "  status:       ${FLAKE_STATUS}"
echo "  version:      ${FLAKE_VERSION}"
echo "  provides:     $(echo "$PROVIDES_RAW" | jq -r 'join(", ")')"
echo "  dependencies: $(echo "$DEPS_RAW" | jq -r 'join(", ") | if . == "" then "(none)" else . end')"
echo "  nix input:    ${INPUT_ATTR}.url = \"${FLAKE_URL}\""
echo ""

if ! $NON_INTERACTIVE && ! $DRY_RUN; then
  echo -e "${BOLD}?${NC} Continue adding this flake? [Y/n]"
  read -r CONFIRM
  [[ "$CONFIRM" =~ ^[Nn]$ ]] && { echo "Aborted."; exit 0; }
fi

# ── Target directory ──────────────────────────────────────────────────────────
if [[ -n "$FLAKE_FAMILY" ]]; then
  TARGET_DIR="$FLAKES_DIR/${FLAKE_FAMILY}/${FLAKE_NAME}"
else
  TARGET_DIR="$FLAKES_DIR/${FLAKE_NAME}"
fi

if [[ -d "$TARGET_DIR" ]] && ! $DRY_RUN && ! $NON_INTERACTIVE; then
  warn "Directory already exists: $TARGET_DIR"
  echo -e "${BOLD}?${NC} Overwrite? [y/N]"
  read -r OVERWRITE
  [[ "$OVERWRITE" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi

# ── Provides flags ────────────────────────────────────────────────────────────
HAS_PACKAGES=false; HAS_NIXOS=false; HAS_HOME=false; HAS_LIB=false
while IFS= read -r p; do
  case "$p" in
    packages)     HAS_PACKAGES=true ;;
    nixosModules) HAS_NIXOS=true ;;
    homeModules)  HAS_HOME=true ;;
    lib)          HAS_LIB=true ;;
  esac
done < <(echo "$PROVIDES_RAW" | jq -r '.[]')

# ── Nix-escaped values ────────────────────────────────────────────────────────
NIX_NAME="$(nix_escape "$FLAKE_NAME")"
NIX_TYPE="$(nix_escape "$FLAKE_TYPE")"
NIX_ROLE="$(nix_escape "$FLAKE_ROLE")"
NIX_DESC="$(nix_escape "$FLAKE_DESC")"
NIX_REPO="$(nix_escape "$FLAKE_URL")"
NIX_STATUS="$(nix_escape "$FLAKE_STATUS")"
NIX_VERSION="$(nix_escape "$FLAKE_VERSION")"
NIX_PROVIDES="$(echo "$PROVIDES_RAW" | jq -r '[ .[] | "\"" + . + "\"" ] | "[ " + join(" ") + " ]"')"
NIX_DEPS="$(echo "$DEPS_RAW" | jq -r '[ .[] | "\"" + . + "\"" ] | "[ " + join(" ") + " ]"')"

# ── Generate flakes/<...>/default.nix ────────────────────────────────────────
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
printf '    status       = "%s";  # unstable | beta | stable | experimental | wip | deprecated\n' "$NIX_STATUS"
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
  printf '  homeModule  = flake.homeModules.default or flake.homeManagerModules.default or null;\n'
else
  printf '  homeModule  = null;\n'
fi

$HAS_LIB && printf '  lib         = flake.lib or {};\n'

printf '\n  overlay = _final: prev: {\n'
printf '    %s = (flake.packages.${prev.system} or {}).default or null;\n' "$NIX_NAME"
printf '  };\n'
printf '}\n'
}

# ── Write default.nix ─────────────────────────────────────────────────────────
if $DRY_RUN; then
  echo ""
  info "[DRY RUN] Would create: ${TARGET_DIR}/default.nix"
  echo "  ┌─────────────────────────────────────────────────────────"
  generate_default_nix | sed 's/^/  │ /'
  echo "  └─────────────────────────────────────────────────────────"
else
  info "Writing ${TARGET_DIR}/default.nix..."
  mkdir -p "$TARGET_DIR"
  generate_default_nix > "$TARGET_DIR/default.nix"
  ok "Wrote ${TARGET_DIR}/default.nix"
fi

# ── Patch flake.nix ───────────────────────────────────────────────────────────
echo ""
info "$($DRY_RUN && echo '[DRY RUN] Would add input to' || echo 'Adding input to') flake.nix..."

if grep -q "  ${INPUT_ATTR}\.url" "$FLAKE_NIX" 2>/dev/null; then
  warn "Input '${INPUT_ATTR}' already exists in flake.nix — skipping."
elif $DRY_RUN; then
  echo "  Would insert:  ${INPUT_ATTR}.url = \"${FLAKE_URL}\";"
else
  python3 - "$FLAKE_NIX" "$INPUT_ATTR" "$FLAKE_URL" <<'PYEOF'
import sys, re, os

flake_nix, input_attr, flake_url = sys.argv[1], sys.argv[2], sys.argv[3]
with open(flake_nix) as f:
    content = f.read()

new_line = f'    {input_attr}.url = "{flake_url}";\n'
marker = '    # ── Planned'
if marker in content:
    patched = content.replace(marker, new_line + marker, 1)
else:
    patched = re.sub(r'(  \};\n\n  outputs)', new_line + r'\1', content, count=1)

tmp = flake_nix + '.tmp'
with open(tmp, 'w') as f:
    f.write(patched)
os.replace(tmp, flake_nix)
PYEOF

  grep -q "  ${INPUT_ATTR}\.url" "$FLAKE_NIX" \
    || die "Patch failed — add manually:  ${INPUT_ATTR}.url = \"${FLAKE_URL}\";"
  ok "Added ${INPUT_ATTR}.url to flake.nix"
fi

# ── Regenerate registry ───────────────────────────────────────────────────────
echo ""
if $DRY_RUN; then
  info "[DRY RUN] Would run gen-registry.sh"
elif [[ -f "$SCRIPT_DIR/gen-registry.sh" ]]; then
  info "Regenerating registry..."
  bash "$SCRIPT_DIR/gen-registry.sh" --repo-root "$REPO_ROOT" \
    $($VERBOSE && echo "--verbose" || true)
  ok "Registry updated"
else
  warn "gen-registry.sh not found — run it manually."
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
if $DRY_RUN; then
  echo -e "${YELLOW}${BOLD}Dry run complete.${NC} Re-run without --dry-run to apply."
else
  echo -e "${GREEN}${BOLD}Done!${NC} '${FLAKE_NAME}' added to ft-nixpkgs."
  echo ""
  echo "  1. Review:  $TARGET_DIR/default.nix"
  echo "  2. Run:     nix flake update ${INPUT_ATTR}"
  echo "  3. Verify:  nix flake show"
fi
echo ""
