#!/usr/bin/env bash
# Fail if any tracked text file contains a byte outside printable ASCII.
# Tab, newline, carriage return, vertical tab and form feed are allowed.
# Uses git grep in the C locale (byte matching, binaries skipped with -I), and
# distinguishes "found" (exit 0) from "none" (1) and from errors (128), so a
# grep failure can never be mistaken for a clean result.
# Usage: scripts/check-ascii.sh [pathspec...]
set -uo pipefail

LC_ALL=C git grep -n -I -e '[^[:print:][:space:]]' -- "$@"
rc=$?
case "$rc" in
  0) echo "check-ascii: non-ASCII or control characters found (listed above)" >&2; exit 1 ;;
  1) echo "check-ascii: clean"; exit 0 ;;
  *) echo "check-ascii: git grep failed (exit $rc)" >&2; exit 2 ;;
esac
