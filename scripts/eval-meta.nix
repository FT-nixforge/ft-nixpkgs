# Helper used by gen-registry.py to extract the `meta` attrset from a
# flake config function without needing real inputs or a Nix system.
#
# Usage:
#   nix eval --json --file scripts/eval-meta.nix \
#       --arg flakePath /abs/path/to/flakes/family/name/default.nix
#
# Nix is lazy, so `inputs`, `system`, and `pkgsLib` are never forced when
# only `meta` is accessed — the function body's `let flake = inputs.X`
# binding is never evaluated.

{ flakePath }:
let
  cfg    = import flakePath;
  result = cfg { inputs = {}; system = "x86_64-linux"; pkgsLib = null; };
in
result.meta
