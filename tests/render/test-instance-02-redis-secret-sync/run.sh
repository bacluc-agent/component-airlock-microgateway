#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
DIR="${HERE#"$ROOT"/}"
INSTANCE="${ESPEJOTE_INSTANCE:-redisSecretSync}"
ESPEJOTE_CMD="${ESPEJOTE_CMD:-espejote}"
NAMESPACE="test-instance-02"
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
TMP_ERR="$(mktemp)"
trap 'rm -f "$TMP" "$TMP_ERR"' EXIT

for input in "${INPUTS[@]}"; do
  REL="${input#"$HERE"/}"
  CASE="${input#"$ROOT"/}"
  CASE_DIR="${REL%/input.yaml}"
  OUTPUT="$CASE_DIR/output.yaml"
  echo "==> $DIR: $CASE_DIR"
  if ! $ESPEJOTE_CMD render "$MANIFEST" --input "$CASE" >"$TMP" 2>"$TMP_ERR"; then
    echo "FAIL: render command failed for $CASE" >&2
    cat "$TMP_ERR" >&2
    FAILED=1
    continue
  fi
  if grep -q '^Error:' "$TMP_ERR"; then
    if [ -f "$HERE/$CASE_DIR/error.txt" ] && grep -qF "$(cat "$HERE/$CASE_DIR/error.txt")" "$TMP_ERR"; then
      continue
    fi
    echo "FAIL: render failed for $CASE" >&2
    cat "$TMP_ERR" >&2
    FAILED=1
    continue
  fi
  if [ -f "$HERE/$CASE_DIR/error.txt" ]; then
    echo "FAIL: render succeeded for $CASE but an error was expected" >&2
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
