#!/usr/bin/env bash
# create-flake.sh — scaffold a new Nix flake from a template
#
# Usage:
#   bash scripts/create-flake.sh [OPTIONS] [NAME]
#
# Creates a new flake directory at:
#   <parent of ft-nixpkgs>/<name>/
#
# The new directory contains:
#   flake.nix, ft-nixpkgs.json, README.md, .gitignore
#   and skeleton source files based on the selected "provides".
#
# Options:
#   --dry-run, -n    Preview what would be created without writing files
#   --verbose, -v    Print extra info
#   --help, -h       Show this help text
#
# Environment:
#   FT_REPO_ROOT  Override the ft-nixpkgs repo root (auto-set by nix run .#create-flake)
#
# Dependencies: git, jq

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${FT_REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FLAKES_DIR="$REPO_ROOT/flakes"

# shellcheck source=tui.sh
. "$SCRIPT_DIR/tui.sh"

# ── Colours ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
die()   { echo -e "${RED}ERROR:${NC} $*" >&2; exit 1; }
info()  { echo -e "${BLUE}→${NC} $*"; }
ok()    { echo -e "${GREEN}✓${NC} $*"; }
warn()  { echo -e "${YELLOW}⚠${NC} $*"; }
ask()   { echo -e "${BOLD}?${NC} $*"; }
vecho() { $VERBOSE && echo -e "${BLUE}[verbose]${NC} $*" >&2 || true; }

# ── Dependency check ─────────────────────────────────────────────────────────
for _dep in git jq; do
  command -v "$_dep" &>/dev/null || die "'$_dep' is required but not found in PATH."
done

# ── Argument parsing ─────────────────────────────────────────────────────────
DRY_RUN=false
VERBOSE=false
POSITIONAL_ARGS=()

show_help() {
  sed -n '2,/^$/p' "$0" | grep '^#' | sed 's/^# \?//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run|-n) DRY_RUN=true  ;;
    --verbose|-v) VERBOSE=true  ;;
    --help|-h)    show_help     ;;
    --)           shift; POSITIONAL_ARGS+=("$@"); break ;;
    -*)           die "Unknown option: $1" ;;
    *)            POSITIONAL_ARGS+=("$1") ;;
  esac
  shift
done

# ── Detect GitHub username ────────────────────────────────────────────────────
get_github_username() {
  if command -v gh &>/dev/null; then
    local u
    u="$(gh api user --jq '.login' 2>/dev/null || true)"
    [[ -n "$u" ]] && { echo "$u"; return; }
  fi
  local u
  u="$(git config github.user 2>/dev/null || true)"
  [[ -n "$u" ]] && { echo "$u"; return; }
  u="$(git config user.name 2>/dev/null || true)"
  [[ -n "$u" ]] && { echo "$u"; return; }
  echo ""
}

# ── Metadata collection ───────────────────────────────────────────────────────

# 1. Project name
if [[ ${#POSITIONAL_ARGS[@]} -ge 1 ]]; then
  CF_NAME="${POSITIONAL_ARGS[0]}"
else
  ask "Project name (will become the directory name, e.g. ft-nixbar):"
  read -r CF_NAME
fi
[[ -n "$CF_NAME" ]] || die "Project name is required."
CF_NAME="${CF_NAME// /-}"

# 2. GitHub owner
DETECTED_USER="$(get_github_username)"
ask "GitHub owner/org [${DETECTED_USER:-your-username}]:"
read -r CF_OWNER
CF_OWNER="${CF_OWNER:-$DETECTED_USER}"
[[ -n "$CF_OWNER" ]] || die "GitHub owner is required."

# 3. Description
ask "Short description (one line):"
read -r CF_DESC

# 4. Type
select_one "type" CF_TYPE  library bundle module package app

# 5. Role
select_one "role" CF_ROLE  parent child standalone

# 6. Family — scan existing family dirs
family_opts=("standalone (no family)")
for d in "$FLAKES_DIR"/*/; do
  [[ -d "$d" && ! -f "${d}default.nix" ]] && family_opts+=("$(basename "$d")")
done
CF_FAMILY_SEL=""
select_one "family" CF_FAMILY_SEL "${family_opts[@]}"
[[ "$CF_FAMILY_SEL" == "standalone (no family)" ]] && CF_FAMILY="" || CF_FAMILY="$CF_FAMILY_SEL"

# 7. Provides
CF_PROVIDES=()
select_many "provides" CF_PROVIDES  packages nixosModules homeModules lib

# 8. Dependencies — searchable from known flakes
known_flakes=()
for d in "$FLAKES_DIR"/*/; do
  [[ -f "${d}default.nix" ]] && known_flakes+=("$(basename "$d")")
done
for d in "$FLAKES_DIR"/*/*/; do
  [[ -f "${d}default.nix" ]] && known_flakes+=("$(basename "$d")")
done
CF_DEPS=()
if [[ ${#known_flakes[@]} -gt 0 ]]; then
  select_search "dependencies" CF_DEPS "${known_flakes[@]}"
else
  warn "No flakes in registry yet — skipping dependency selector."
fi

# 9. Status
select_one "status" CF_STATUS  experimental wip stable deprecated

# 10. Version
ask "version [0.1.0]:"
read -r CF_VERSION
CF_VERSION="${CF_VERSION:-0.1.0}"

# ── Target directory ─────────────────────────────────────────────────────────
PARENT_DIR="$(cd "$REPO_ROOT/.." && pwd)"
TARGET="$PARENT_DIR/$CF_NAME"

# ── Summary + confirm ────────────────────────────────────────────────────────
echo ""
info "Will create: $TARGET/"
echo "  name:        $CF_NAME"
echo "  owner:       $CF_OWNER"
echo "  type:        $CF_TYPE"
echo "  role:        $CF_ROLE"
echo "  family:      ${CF_FAMILY:-standalone}"
echo "  provides:    ${CF_PROVIDES[*]+"${CF_PROVIDES[*]}"}"
echo "  deps:        ${CF_DEPS[*]+"${CF_DEPS[*]}"}"
echo "  status:      $CF_STATUS"
echo "  version:     $CF_VERSION"
echo ""

if ! $DRY_RUN; then
  ask "Continue? [Y/n]:"
  read -r _confirm
  case "${_confirm,,}" in
    n|no) echo "Aborted."; exit 0 ;;
  esac
fi

# ── File generation helpers ───────────────────────────────────────────────────
write_file() {
  local _path="$1"
  local _content="$2"
  if $DRY_RUN; then
    info "[DRY RUN] Would write: $_path"
    vecho "--- content ---"
    $VERBOSE && printf '%s\n' "$_content" >&2 || true
    return
  fi
  mkdir -p "$(dirname "$_path")"
  printf '%s\n' "$_content" > "$_path"
  ok "Wrote: $_path"
}

_has_provide() {
  local _p="$1"
  local _item
  for _item in "${CF_PROVIDES[@]+"${CF_PROVIDES[@]}"}"; do
    [[ "$_item" == "$_p" ]] && return 0
  done
  return 1
}

generate_flake_nix() {
  local _out
  _out='{
  description = "'"$CF_DESC"'";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";'

  local _dep
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

generate_ft_nixpkgs_json() {
  local provides_json deps_json family_val
  provides_json="$(printf '%s\n' "${CF_PROVIDES[@]+"${CF_PROVIDES[@]}"}" | jq -Rcs '[split("\n")[] | select(length > 0)]')"
  deps_json="$(printf '%s\n' "${CF_DEPS[@]+"${CF_DEPS[@]}"}" | jq -Rcs '[split("\n")[] | select(length > 0)]')"
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

generate_readme() {
  local _out
  _out="# $CF_NAME

$CF_DESC

## Overview

<!-- TODO: describe the flake -->

## Usage

\`\`\`nix
# In your flake.nix inputs:
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

## License

<!-- TODO: add license -->
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
  write_file "$TARGET/packages/default.nix" '{ pkgs ? import <nixpkgs> {} }:
pkgs.stdenv.mkDerivation {
  pname = "'"$CF_NAME"'";
  version = "'"$CF_VERSION"'";
  src = ../.;
  # TODO: add buildInputs, installPhase, etc.
}'
fi

if _has_provide "nixosModules"; then
  write_file "$TARGET/modules/nixos/default.nix" '{ config, lib, pkgs, ... }:
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
  write_file "$TARGET/modules/home/default.nix" '{ config, lib, pkgs, ... }:
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
  write_file "$TARGET/lib/default.nix" '{ lib }:
{
  # TODO: implement library functions
}'
fi

# ── Git init ─────────────────────────────────────────────────────────────────
if ! $DRY_RUN; then
  git init "$TARGET"
  git -C "$TARGET" add .
  ok "Git repository initialised in $TARGET"
fi

# ── Next steps ───────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}Done!${NC} Flake scaffold created at: $TARGET"
echo ""
echo "Next steps:"
echo "  cd $TARGET"
echo "  git commit -m \"chore: initial scaffold\""
echo "  nix flake update    # generate flake.lock"
echo ""
info "To register this flake in ft-nixpkgs, run:"
echo "  bash $REPO_ROOT/scripts/add-flake.sh ${CF_OWNER}/${CF_NAME}"
echo ""
