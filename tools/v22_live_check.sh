#!/usr/bin/env bash
# LIVE cross-check for task-22. The Zig suite embeds a RECORDED fact table, which is a
# snapshot and cannot detect a later regression. This regenerates the facts from the
# CURRENT binary and diffs them against the recording the tests embed.
#
# Normalisation: the diagnostic text embeds the temp path the generator used, which
# differs per run. Paths are stripped before diffing so only ENCODING differences show.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${1:-$(cd "$HERE/.." && pwd)}"
CLI="${2:-$ROOT/zig-out/bin/celeris64}"
BASE="$HERE/v22_baseline.txt"
GEN="$HERE/v22_gen.sh"
[ -f "$BASE" ] || { echo "FAIL: no baseline at $BASE"; exit 1; }
# NOT exit 0: a missing CLI means the tree was not built OR the build FAILED, and a
# failed build must never be reported as a passing check. Same rule as
# tools/audit-reserved.sh, for the same reason: a green line that skipped its only real
# test is worse than a red one, because nobody looks again.
[ -x "$CLI" ] || { echo "FAIL: no CLI at $CLI (build the tree first; if that build fails, this check must not be treated as passing)"; exit 1; }
[ -f "$GEN" ] || { echo "FAIL: no generator at $GEN"; exit 1; }

OUT=$(mktemp -d)
if ! CLI_OVERRIDE="$CLI" OUT_DIR="$OUT" "$GEN" >/dev/null; then
  echo "FAIL: generator failed"; rm -rf "$OUT"; exit 1
fi
norm() { sed -E 's#/tmp/[A-Za-z0-9._-]+/#/TMP/#g' "$1"; }
if diff -q <(norm "$BASE") <(norm "$OUT/words.txt") >/dev/null 2>&1; then
  echo "LIVE CHECK: OK - all $(wc -l < "$BASE") recorded facts still reproduce"
  rm -rf "$OUT"; exit 0
fi
echo "LIVE CHECK: FAIL - the encoding changed since the facts were recorded:"
diff <(norm "$BASE") <(norm "$OUT/words.txt") | head -20
rm -rf "$OUT"; exit 1
