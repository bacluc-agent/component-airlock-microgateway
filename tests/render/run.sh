#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

shopt -s nullglob
SCRIPTS=(*/run.sh)
shopt -u nullglob
[ "${#SCRIPTS[@]}" -gt 0 ] || { echo "FAIL: no per-MR run.sh under $HERE" >&2; exit 1; }

FAILED=0
for s in "${SCRIPTS[@]}"; do
  echo "==> $s"
  bash "$s" "$@" || FAILED=1
done
[ "$FAILED" -eq 0 ] || { echo "FAIL: one or more render tests failed" >&2; exit 1; }
echo "PASS: ${#SCRIPTS[@]} render test(s)"
