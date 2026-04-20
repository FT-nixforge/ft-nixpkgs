# Helper used by gen-registry.sh to extract the `meta` attrset from a
# flake config function without needing real inputs or a Nix system.
#
# Usage:
#   nix-instantiate --eval --json --strict --file scripts/eval-meta.nix \
#       --arg flakePath /abs/path/to/flakes/family/name/default.nix
#
# Note: use nix-instantiate (not `nix eval`) — the classic `nix` CLI correctly
# applies --arg to top-level functions in --file mode; the experimental
# `nix eval` command does not apply --arg to --file expressions.

{ flakePath }:
let
  cfg    = import flakePath;
  result = cfg { inputs = {}; system = "x86_64-linux"; pkgsLib = null; };
in
result.meta
