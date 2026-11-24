#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
DIR="${HERE#"$ROOT"/}"
INSTANCE="${ESPEJOTE_INSTANCE:-redisSecretSync}"
ESPEJOTE_CMD="${ESPEJOTE_CMD:-espejote}"
NAMESPACE="test-instance-01"
RESOURCE="redis-secret-sync"
UPDATE=0
if [ "${1:-}" = "--update" ]; then UPDATE=1; fi

cd "$ROOT"

MANIFEST="compiled/$INSTANCE/$INSTANCE/$NAMESPACE/ManagedResource-$RESOURCE.yaml"
[ -f "$MANIFEST" ] || { echo "FAIL: no manifest at $MANIFEST" >&2; exit 1; }

shopt -s nullglob
INPUTS=("$HERE"/*/input.yaml)
shopt -u nullglob
[ "${#INPUTS[@]}" -gt 0 ] || { echo "FAIL: no case input files in $DIR" >&2; exit 1; }

FAILED=0
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

for input in "${INPUTS[@]}"; do
  REL="${input#"$HERE"/}"
  CASE="${input#"$ROOT"/}"
  OUTPUT="${REL%/input.yaml}/output.yaml"
  echo "==> $DIR: ${REL%/input.yaml}"
  if ! $ESPEJOTE_CMD render "$MANIFEST" --input "$CASE" >"$TMP"; then
    echo "FAIL: render failed for $CASE" >&2
    FAILED=1
    continue
  fi
  if [ "$UPDATE" = 1 ]; then
    cp "$TMP" "$HERE/$OUTPUT"
  elif [ ! -f "$HERE/$OUTPUT" ]; then
    echo "FAIL: missing $OUTPUT (run with --update to create it)" >&2
    FAILED=1
  elif ! diff -u "$HERE/$OUTPUT" "$TMP"; then
    echo "FAIL: diff failed for $CASE" >&2
    FAILED=1
  fi
done

[ "$FAILED" -eq 0 ] || { echo "FAIL: one or more cases failed in $DIR" >&2; exit 1; }
echo "PASS: $DIR (${#INPUTS[@]} case(s))"
