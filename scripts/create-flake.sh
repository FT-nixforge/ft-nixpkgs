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

nix_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//\$\{/\\\$\{}"
  printf '%s' "$s"
}

nix_list_from_array() {
  local values=("$@")
  if [[ ${#values[@]} -eq 0 ]]; then
    printf '[]'
    return
  fi

  local rendered=()
  local value
  for value in "${values[@]}"; do
    rendered+=("\"$(nix_escape "$value")\"")
  done

  printf '[ %s ]' "${rendered[*]}"
}

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
  unstable beta stable experimental wip deprecated)"

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
  for _item in "${CF_PROVIDES[@]}"; do
    [[ "$_item" == "$_p" ]] && return 0
  done
  return 1
}

_supports_floating_release_tag() {
  case "$CF_STATUS" in
    stable|beta|unstable) return 0 ;;
    *) return 1 ;;
  esac
}

# ── flake.nix ─────────────────────────────────────────────────────────────────
generate_flake_nix() {
  local _desc _repo _provides _deps
  _desc="$(nix_escape "$CF_DESC")"
  _repo="$(nix_escape "github:${CF_OWNER}/${CF_NAME}")"
  _provides="$(nix_list_from_array "${CF_PROVIDES[@]}")"
  _deps="$(nix_list_from_array "${CF_DEPS[@]}")"

  cat <<EOF
{
  description = "${_desc}";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
EOF

  local _dep
  for _dep in "${CF_DEPS[@]}"; do
    printf '    # %s.url = "github:%s/%s";  # TODO: verify URL\n' "$_dep" "$CF_OWNER" "$_dep"
  done

  cat <<EOF
  };

  outputs = { self, nixpkgs, ... }:
  let
    systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
    forAllSystems = nixpkgs.lib.genAttrs systems;
    pkgsFor = system: import nixpkgs { inherit system; };
  in
  {
    meta = {
      name         = "${CF_NAME}";
      type         = "${CF_TYPE}";        # library | bundle | module | package | app
      role         = "${CF_ROLE}";        # parent | child | standalone
      description  = "${_desc}";
      repo         = "${_repo}";
      provides     = ${_provides};
      dependencies = ${_deps};
      status       = "${CF_STATUS}";      # unstable | beta | stable | experimental | wip | deprecated
      version      = "${CF_VERSION}";
    };
EOF

  if _has_provide "packages"; then
    cat <<'EOF'

    packages = forAllSystems (system:
      let pkgs = pkgsFor system; in
      {
        default = pkgs.callPackage ./packages { };
      });
EOF
  fi

  if _has_provide "nixosModules"; then
    cat <<'EOF'

    nixosModules.default = import ./modules/nixos;
EOF
  fi

  if _has_provide "homeModules"; then
    cat <<'EOF'

    homeModules.default = import ./modules/home;
    homeManagerModules.default = self.homeModules.default;
EOF
  fi

  if _has_provide "lib"; then
    cat <<'EOF'

    lib = import ./lib { inherit (nixpkgs) lib; };
EOF
  fi

  cat <<'EOF'

    devShells = forAllSystems (system:
      let pkgs = pkgsFor system; in
      {
        default = pkgs.mkShell {
          packages = with pkgs; [
            git
            jq
          ];
        };
      });
  };
}
EOF
}

# ── README.md ─────────────────────────────────────────────────────────────────
generate_readme() {
  local _rolling_block
  if _supports_floating_release_tag; then
    _rolling_block="
### Rolling (${CF_STATUS})
\`\`\`nix
inputs.${CF_NAME}.url = \"github:${CF_OWNER}/${CF_NAME}/${CF_STATUS}\";
\`\`\`
"
  else
    _rolling_block="
### Rolling releases

This flake only publishes floating release tags for \`stable\`, \`beta\`, and \`unstable\`.
Current status: \`${CF_STATUS}\`.
"
  fi

  local _out="# $CF_NAME

$CF_DESC

## Usage

### Pinned release
\`\`\`nix
inputs.${CF_NAME}.url = \"github:${CF_OWNER}/${CF_NAME}/v${CF_VERSION}\";
\`\`\`

${_rolling_block}

### Bleeding edge
\`\`\`nix
inputs.${CF_NAME}.url = \"github:${CF_OWNER}/${CF_NAME}/main\";
\`\`\`

## Metadata

\`\`\`nix
outputs.meta = {
  name = \"${CF_NAME}\";
  version = \"${CF_VERSION}\";
  status = \"${CF_STATUS}\";
};
\`\`\`

The release workflow creates:
- a fixed tag \`v${CF_VERSION}\`
- a floating tag matching \`meta.status\` when the status is \`stable\`, \`beta\`, or \`unstable\`
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

## CI / release automation

- \`.github/workflows/check.yml\` validates the flake on pushes and PRs
- \`.github/workflows/update_flake.yml\` opens a weekly \`flake.lock\` update PR
- \`.github/workflows/release.yml\` tags and releases from \`meta.version\` and \`meta.status\`
"
  printf '%s' "$_out"
}

generate_check_workflow() {
  cat <<'EOF'
name: Check

on:
  push:
    branches: [main, master]
  pull_request:
    branches: [main, master]
  workflow_dispatch:

jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6

      - name: Install Nix
        uses: cachix/install-nix-action@v27
        with:
          github_access_token: ${{ secrets.GITHUB_TOKEN }}

      - name: Setup cache
        uses: actions/cache@v5
        with:
          path: |
            /nix/store
            ~/.cache/nix
          key: ${{ runner.os }}-nix-${{ hashFiles('flake.lock') }}
          restore-keys: |
            ${{ runner.os }}-nix-

      - name: Check flake
        run: nix flake check --show-trace

      - name: Verify meta export
        run: |
          nix eval .#meta.name --raw
          nix eval .#meta.version --raw
          nix eval .#meta.status --raw
EOF

  if _has_provide "packages"; then
    cat <<'EOF'

      - name: Verify packages export
        run: |
          nix eval .#packages.x86_64-linux --apply builtins.attrNames
EOF
  fi

  if _has_provide "nixosModules"; then
    cat <<'EOF'

      - name: Verify nixosModules export
        run: |
          nix eval .#nixosModules.default --apply 'x: "ok"'
EOF
  fi

  if _has_provide "homeModules"; then
    cat <<'EOF'

      - name: Verify homeModules export
        run: |
          nix eval .#homeModules.default --apply 'x: "ok"'
EOF
  fi

  if _has_provide "lib"; then
    cat <<'EOF'

      - name: Verify lib export
        run: |
          nix eval .#lib --apply builtins.attrNames
EOF
  fi

  cat <<'EOF'

      - name: Summary
        if: always()
        run: |
          echo "## Check Results" >> "$GITHUB_STEP_SUMMARY"
          echo "Status: ${{ job.status }}" >> "$GITHUB_STEP_SUMMARY"
EOF
}

generate_update_flake_workflow() {
  cat <<'EOF'
name: Update Flake

on:
  schedule:
    - cron: "0 0 * * 0"
  workflow_dispatch:

jobs:
  update-flake:
    runs-on: ubuntu-latest
    permissions:
      contents: write
      pull-requests: write
    steps:
      - uses: actions/checkout@v6
        with:
          token: ${{ secrets.GITHUB_TOKEN }}

      - name: Install Nix
        uses: cachix/install-nix-action@v27
        with:
          github_access_token: ${{ secrets.GITHUB_TOKEN }}

      - name: Setup cache
        uses: actions/cache@v5
        with:
          path: |
            /nix/store
            ~/.cache/nix
          key: ${{ runner.os }}-nix-${{ hashFiles('flake.lock') }}
          restore-keys: |
            ${{ runner.os }}-nix-

      - name: Configure Git
        run: |
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"

      - name: Update flake inputs
        run: nix flake update

      - name: Check flake still evaluates
        run: nix flake check --show-trace

      - name: Verify meta export
        run: |
          nix eval .#meta.name --raw
          nix eval .#meta.version --raw
          nix eval .#meta.status --raw
EOF

  if _has_provide "packages"; then
    cat <<'EOF'

      - name: Verify packages export
        run: |
          nix eval .#packages.x86_64-linux --apply builtins.attrNames
EOF
  fi

  if _has_provide "nixosModules"; then
    cat <<'EOF'

      - name: Verify nixosModules export
        run: |
          nix eval .#nixosModules.default --apply 'x: "ok"'
EOF
  fi

  if _has_provide "homeModules"; then
    cat <<'EOF'

      - name: Verify homeModules export
        run: |
          nix eval .#homeModules.default --apply 'x: "ok"'
EOF
  fi

  if _has_provide "lib"; then
    cat <<'EOF'

      - name: Verify lib export
        run: |
          nix eval .#lib --apply builtins.attrNames
EOF
  fi

  cat <<'EOF'

      - name: Create Pull Request
        uses: peter-evans/create-pull-request@v6
        with:
          token: ${{ secrets.GITHUB_TOKEN }}
          branch: update-flake-lock
          commit-message: "flake: update flake.lock"
          title: "Update flake.lock"
          body: |
            Automated weekly `flake.lock` update.

            - Updated flake inputs
            - Re-ran `nix flake check`
            - Re-validated exported flake outputs
          labels: |
            dependencies
            automated
          delete-branch: true
EOF
}

generate_release_workflow() {
  cat <<'EOF'
name: Release

on:
  push:
    branches: [main, master]
  workflow_dispatch:

jobs:
  release:
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@v6
        with:
          fetch-depth: 0

      - name: Install Nix
        uses: cachix/install-nix-action@v27
        with:
          github_access_token: ${{ secrets.GITHUB_TOKEN }}

      - name: Read release metadata
        id: meta
        run: |
          version="$(nix eval .#meta.version --raw)"
          status="$(nix eval .#meta.status --raw)"
          tag="v${version#v}"
          echo "version=$version" >> "$GITHUB_OUTPUT"
          echo "status=$status" >> "$GITHUB_OUTPUT"
          echo "tag=$tag" >> "$GITHUB_OUTPUT"

      - name: Check whether the version tag already exists
        id: existing
        run: |
          if git ls-remote --exit-code --tags origin "refs/tags/${{ steps.meta.outputs.tag }}" >/dev/null 2>&1; then
            echo "exists=true" >> "$GITHUB_OUTPUT"
          else
            echo "exists=false" >> "$GITHUB_OUTPUT"
          fi

      - name: Skip duplicate release
        if: steps.existing.outputs.exists == 'true'
        run: |
          echo "Version tag ${{ steps.meta.outputs.tag }} already exists. Skipping release."

      - name: Create version and floating tags
        if: steps.existing.outputs.exists != 'true'
        run: |
          version_tag="${{ steps.meta.outputs.tag }}"
          status="${{ steps.meta.outputs.status }}"

          git tag "$version_tag"

          case "$status" in
            stable|beta|unstable)
              git tag -fa "$status" -m "Release $version_tag"
              ;;
            *)
              echo "No floating tag for status '$status'"
              ;;
          esac

          git push origin "refs/tags/$version_tag"

          case "$status" in
            stable|beta|unstable)
              git push origin "refs/tags/$status" --force
              ;;
          esac

      - name: Create GitHub Release
        if: steps.existing.outputs.exists != 'true'
        uses: softprops/action-gh-release@v2
        with:
          tag_name: ${{ steps.meta.outputs.tag }}
          generate_release_notes: true
EOF
}

# ── Write files ───────────────────────────────────────────────────────────────
write_file "$TARGET/flake.nix"          "$(generate_flake_nix)"
write_file "$TARGET/README.md"          "$(generate_readme)"
write_file "$TARGET/.gitignore"         ".direnv/
result
result-*
.DS_Store"
write_file "$TARGET/.github/workflows/check.yml"        "$(generate_check_workflow)"
write_file "$TARGET/.github/workflows/update_flake.yml" "$(generate_update_flake_workflow)"
write_file "$TARGET/.github/workflows/release.yml"      "$(generate_release_workflow)"

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
