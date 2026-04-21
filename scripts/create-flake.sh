#!/usr/bin/env bash
# create-flake — scaffold a new Nix flake from a template
#
# Usage: create-flake [OPTIONS] [NAME]
#
# Options:
#   --dry-run, -n    Preview without writing files
#   --verbose, -v    Extra output
#   --dir DIR        Parent directory for the new flake [default: $PWD]
#   --help, -h       This help text
#
# When invoked via `nix run .#create-flake` from a ft-nixpkgs checkout,
# FT_REPO_ROOT is set automatically so family/dependency options are
# populated from the local registry.
#
# Dependencies: git, jq, gum (charm.sh/gum — available as pkgs.gum)

set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
die()   { echo -e "${RED}error:${NC} $*" >&2; exit 1; }
info()  { echo -e "${BLUE}→${NC} $*"; }
ok()    { echo -e "${GREEN}✓${NC} $*"; }
warn()  { echo -e "${YELLOW}⚠${NC} $*"; }
vecho() { $VERBOSE && echo -e "${BLUE}[v]${NC} $*" >&2 || true; }

# ── Deps ──────────────────────────────────────────────────────────────────────
for _dep in git jq gum; do
  command -v "$_dep" &>/dev/null \
    || die "'$_dep' not found. Install it or run via \`nix run .#create-flake\`."
done

# ── Args ──────────────────────────────────────────────────────────────────────
DRY_RUN=false; VERBOSE=false
TARGET_PARENT=""
POSITIONAL_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run|-n) DRY_RUN=true ;;
    --verbose|-v) VERBOSE=true ;;
    --dir)        shift; TARGET_PARENT="$1" ;;
    --help|-h)
      sed -n '2,/^$/p' "$0" | grep '^#' | sed 's/^# \?//'
      exit 0 ;;
    --) shift; POSITIONAL_ARGS+=("$@"); break ;;
    -*) die "Unknown option: $1" ;;
    *)  POSITIONAL_ARGS+=("$1") ;;
  esac
  shift
done

# ── GitHub username ────────────────────────────────────────────────────────────
get_github_username() {
  if command -v gh &>/dev/null; then
    local u; u="$(gh api user --jq '.login' 2>/dev/null || true)"
    [[ -n "$u" ]] && { echo "$u"; return; }
  fi
  local u
  u="$(git config github.user 2>/dev/null || true)"
  [[ -n "$u" ]] && { echo "$u"; return; }
  git config user.name 2>/dev/null || true
}

DETECTED_USER="$(get_github_username)"

# ── Header ────────────────────────────────────────────────────────────────────
gum style \
  --foreground 212 --border-foreground 212 --border rounded \
  --align center --width 46 --margin "1 2" \
  "  Create a new Nix flake  "

# ── Metadata collection ────────────────────────────────────────────────────────

# 1. Name
if [[ ${#POSITIONAL_ARGS[@]} -ge 1 ]]; then
  CF_NAME="${POSITIONAL_ARGS[0]}"
else
  CF_NAME="$(gum input --placeholder "ft-myflake" --prompt "Name › ")"
fi
[[ -n "$CF_NAME" ]] || die "Name is required."
CF_NAME="${CF_NAME// /-}"

# 2. GitHub owner
CF_OWNER="$(gum input \
  --placeholder "${DETECTED_USER:-your-org}" \
  --prompt "GitHub owner › " \
  --value "${DETECTED_USER:-}")"
[[ -n "$CF_OWNER" ]] || die "Owner is required."

# 3. Description
CF_DESC="$(gum input \
  --placeholder "A short description" \
  --prompt "Description › ")"

# 4. Type (single-select)
CF_TYPE="$(gum choose --header "Type:" \
  library bundle module package app)"

# 5. Role (single-select)
CF_ROLE="$(gum choose --header "Role:" \
  parent child standalone)"

# 6. Family — scan if FT_REPO_ROOT points to a ft-nixpkgs checkout
family_opts=("standalone")
if [[ -n "${FT_REPO_ROOT:-}" && -d "${FT_REPO_ROOT}/flakes" ]]; then
  for d in "${FT_REPO_ROOT}/flakes"/*/; do
    [[ -d "$d" && ! -f "${d}default.nix" ]] && family_opts+=("$(basename "$d")")
  done
fi
CF_FAMILY_SEL="$(printf '%s\n' "${family_opts[@]}" | gum choose --header "Family:")"
[[ "$CF_FAMILY_SEL" == "standalone" ]] && CF_FAMILY="" || CF_FAMILY="$CF_FAMILY_SEL"

# 7. Provides (multi-select; space to toggle, enter to confirm)
CF_PROVIDES_RAW="$(gum choose --no-limit \
  --header "Provides (space to toggle, enter to confirm):" \
  packages nixosModules homeModules lib)"
mapfile -t CF_PROVIDES <<< "$CF_PROVIDES_RAW"
# strip any empty strings that mapfile may add
CF_PROVIDES=("${CF_PROVIDES[@]}")

# 8. Dependencies — fuzzy search from known registry flakes (requires FT_REPO_ROOT)
CF_DEPS=()
if [[ -n "${FT_REPO_ROOT:-}" && -d "${FT_REPO_ROOT}/flakes" ]]; then
  known_flakes=()
  for d in "${FT_REPO_ROOT}/flakes"/*/; do
    [[ -f "${d}default.nix" ]] && known_flakes+=("$(basename "$d")")
  done
  for d in "${FT_REPO_ROOT}/flakes"/*/*/; do
    [[ -f "${d}default.nix" ]] && known_flakes+=("$(basename "$d")")
  done
  if [[ ${#known_flakes[@]} -gt 0 ]]; then
    CF_DEPS_RAW="$(printf '%s\n' "${known_flakes[@]}" \
      | gum filter --no-limit \
          --header "Dependencies (tab to select, enter to confirm):" \
          --placeholder "type to search…" \
      || true)"
    [[ -n "$CF_DEPS_RAW" ]] && mapfile -t CF_DEPS <<< "$CF_DEPS_RAW"
  fi
fi

# 9. Status (single-select)
CF_STATUS="$(gum choose --header "Status:" \
  experimental wip stable deprecated)"

# 10. Version
CF_VERSION="$(gum input \
  --placeholder "0.1.0" \
  --prompt "Version › " \
  --value "0.1.0")"
CF_VERSION="${CF_VERSION:-0.1.0}"

# ── Target directory ───────────────────────────────────────────────────────────
if [[ -n "$TARGET_PARENT" ]]; then
  TARGET="$TARGET_PARENT/$CF_NAME"
elif [[ -n "${FT_REPO_ROOT:-}" ]]; then
  TARGET="$(cd "${FT_REPO_ROOT}/.." && pwd)/$CF_NAME"
else
  TARGET="$PWD/$CF_NAME"
fi

# ── Summary + confirm ──────────────────────────────────────────────────────────
echo ""
gum style --foreground 240 "Will create: $TARGET/"
echo ""
gum style \
  --border rounded --border-foreground 240 \
  --padding "0 2" \
  "$(printf "name:      %s\nowner:     %s\ntype:      %s\nrole:      %s\nfamily:    %s\nprovides:  %s\ndeps:      %s\nstatus:    %s\nversion:   %s" \
    "$CF_NAME" "$CF_OWNER" "$CF_TYPE" "$CF_ROLE" \
    "${CF_FAMILY:-standalone}" \
    "${CF_PROVIDES[*]+"${CF_PROVIDES[*]}"}" \
    "${CF_DEPS[*]+"${CF_DEPS[*]}"}" \
    "$CF_STATUS" "$CF_VERSION")"
echo ""

if ! $DRY_RUN; then
  gum confirm "Create this flake?" || { echo "Aborted."; exit 0; }
fi

# ── File helpers ───────────────────────────────────────────────────────────────
write_file() {
  local _path="$1" _content="$2"
  if $DRY_RUN; then
    info "[dry run] would write: $_path"
    $VERBOSE && printf '%s\n' "$_content" >&2 || true
    return
  fi
  mkdir -p "$(dirname "$_path")"
  printf '%s\n' "$_content" > "$_path"
  ok "wrote: $_path"
}

_has_provide() {
  local _p="$1"
  for _item in "${CF_PROVIDES[@]+"${CF_PROVIDES[@]}"}"; do
    [[ "$_item" == "$_p" ]] && return 0
  done
  return 1
}

# ── flake.nix ─────────────────────────────────────────────────────────────────
generate_flake_nix() {
  local _out='{
  description = "'"$CF_DESC"'";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";'

  for _dep in "${CF_DEPS[@]+"${CF_DEPS[@]}"}"; do
    _out+="
    # ${_dep}.url = \"github:${CF_OWNER}/${_dep}\";  # TODO: verify URL"
  done

  _out+='
  };

  outputs = { self, nixpkgs, ... }: let
    systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
    forAllSystems = nixpkgs.lib.genAttrs systems;
    pkgsFor = system: import nixpkgs { inherit system; };
  in {'

  if _has_provide "packages"; then
    _out+='
    packages = forAllSystems (system: let pkgs = pkgsFor system; in {
      default = pkgs.callPackage ./packages { };
    });'
  fi
  if _has_provide "nixosModules"; then
    _out+='
    nixosModules.default = import ./modules/nixos;'
  fi
  if _has_provide "homeModules"; then
    _out+='
    homeModules.default = import ./modules/home;'
  fi
  if _has_provide "lib"; then
    _out+='
    lib = import ./lib { inherit (nixpkgs) lib; };'
  fi

  _out+='
  };
}'
  printf '%s' "$_out"
}

# ── ft-nixpkgs.json ───────────────────────────────────────────────────────────
generate_ft_nixpkgs_json() {
  local provides_json deps_json family_val
  provides_json="$(printf '%s\n' "${CF_PROVIDES[@]+"${CF_PROVIDES[@]}"}" \
    | jq -Rcs '[split("\n")[] | select(length > 0)]')"
  deps_json="$(printf '%s\n' "${CF_DEPS[@]+"${CF_DEPS[@]}"}" \
    | jq -Rcs '[split("\n")[] | select(length > 0)]')"
  family_val="$([ -n "$CF_FAMILY" ] && printf '"%s"' "$CF_FAMILY" || echo "null")"

  jq -n \
    --argjson schemaVersion 1 \
    --arg name "$CF_NAME" \
    --arg type "$CF_TYPE" \
    --arg role "$CF_ROLE" \
    --argjson family "$family_val" \
    --arg description "$CF_DESC" \
    --argjson provides "$provides_json" \
    --argjson dependencies "$deps_json" \
    --arg status "$CF_STATUS" \
    --arg version "$CF_VERSION" \
    '{schemaVersion:$schemaVersion, name:$name, type:$type, role:$role, family:$family,
      description:$description, provides:$provides, dependencies:$dependencies,
      status:$status, version:$version}'
}

# ── README.md ─────────────────────────────────────────────────────────────────
generate_readme() {
  local _out="# $CF_NAME

$CF_DESC

## Usage

\`\`\`nix
${CF_NAME}.url = \"github:${CF_OWNER}/${CF_NAME}\";
\`\`\`
"
  if _has_provide "packages"; then
    _out+="
### packages
\`\`\`nix
environment.systemPackages = [ inputs.${CF_NAME}.packages.\${pkgs.system}.default ];
\`\`\`
"
  fi
  if _has_provide "nixosModules"; then
    _out+="
### nixosModules
\`\`\`nix
imports = [ inputs.${CF_NAME}.nixosModules.default ];
\`\`\`
"
  fi
  if _has_provide "homeModules"; then
    _out+="
### homeModules
\`\`\`nix
imports = [ inputs.${CF_NAME}.homeModules.default ];
\`\`\`
"
  fi
  if _has_provide "lib"; then
    _out+="
### lib
\`\`\`nix
let myLib = inputs.${CF_NAME}.lib; in ...
\`\`\`
"
  fi
  _out+="
## Development

\`\`\`bash
nix develop
\`\`\`
"
  printf '%s' "$_out"
}

# ── Write files ───────────────────────────────────────────────────────────────
write_file "$TARGET/flake.nix"          "$(generate_flake_nix)"
write_file "$TARGET/ft-nixpkgs.json"    "$(generate_ft_nixpkgs_json)"
write_file "$TARGET/README.md"          "$(generate_readme)"
write_file "$TARGET/.gitignore"         ".direnv/
result
result-*
.DS_Store"

if _has_provide "packages"; then
  write_file "$TARGET/packages/default.nix" \
'{ pkgs ? import <nixpkgs> {} }:
pkgs.stdenv.mkDerivation {
  pname = "'"$CF_NAME"'";
  version = "'"$CF_VERSION"'";
  src = ../.;
  # TODO: add buildInputs, installPhase, etc.
}'
fi

if _has_provide "nixosModules"; then
  write_file "$TARGET/modules/nixos/default.nix" \
'{ config, lib, pkgs, ... }:
with lib;
let cfg = config.programs.'"$CF_NAME"'; in
{
  options.programs.'"$CF_NAME"' = {
    enable = mkEnableOption "'"$CF_NAME"'";
  };
  config = mkIf cfg.enable {
    # TODO: implement module
  };
}'
fi

if _has_provide "homeModules"; then
  write_file "$TARGET/modules/home/default.nix" \
'{ config, lib, pkgs, ... }:
with lib;
let cfg = config.programs.'"$CF_NAME"'; in
{
  options.programs.'"$CF_NAME"' = {
    enable = mkEnableOption "'"$CF_NAME"'";
  };
  config = mkIf cfg.enable {
    # TODO: implement home-manager module
  };
}'
fi

if _has_provide "lib"; then
  write_file "$TARGET/lib/default.nix" \
'{ lib }:
{
  # TODO: implement library functions
}'
fi

# ── Git init ──────────────────────────────────────────────────────────────────
if ! $DRY_RUN; then
  git init "$TARGET" --quiet
  git -C "$TARGET" add .
  ok "git repository initialised"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
gum style --foreground 212 "  Flake scaffold created: $TARGET"
echo ""
echo "  cd $TARGET"
echo "  git commit -m \"chore: initial scaffold\""
echo "  nix flake update"
if [[ -n "${FT_REPO_ROOT:-}" ]]; then
  echo ""
  info "To register in ft-nixpkgs:"
  echo "  bash ${FT_REPO_ROOT}/scripts/add-flake.sh ${CF_OWNER}/${CF_NAME}"
fi
echo ""
