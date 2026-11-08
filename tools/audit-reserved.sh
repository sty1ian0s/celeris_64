#!/usr/bin/env bash
# Cross-check every "reserved ... must be zero" declaration in the encoding contract
# against an enforcement point in the decoder.
#
# WHY THIS EXISTS: this project twice shipped a contract amendment that declared
# reserved bits "rejected when set" while no code implemented the rejection -- the
# ALU zero[39:28] field (F6) and the stream operand[19:0] field. Both were latent
# through several contract revisions, and neither was findable by value-based tests,
# because a legal word never sets a reserved bit. Declaring a rule and implementing
# it drifted apart twice in one session, so the pairing is now checked mechanically.
#
# This script does not prove the check is CORRECT, only that one exists for each
# declared reservation. Correctness needs the negative/positive test pair that
# accompanies each one: a word with the bits set must be rejected, and a legal word
# sharing those bits must still round-trip.
#
# Untestable in this environment: nothing here is verified against a compiler, since
# the script only greps. It is a prompt for a human, not a proof.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

DOC=docs/isa-encoding.md
DECODER=src/decoder.zig

[ -f "$DOC" ] || { echo "missing $DOC"; exit 2; }
[ -f "$DECODER" ] || { echo "missing $DECODER"; exit 2; }

echo "=== reserved-field audit: $DOC vs $DECODER ==="
echo

# Each entry: human label | grep pattern proving the decoder enforces it
entries=(
  "§3.0 nop/halt operand        |noOperandDiagnostic"
  "§3.0 jump/call/ret rd/rs1     |controlUnusedBits"
  "§3.1 ALU zero[39:28]          |aluReservedBitsDiagnostic"
  "§3.2.2 select operand[35:0]   |selectReservedBitsDiagnostic"
  "§3.3 field operand[27:0]      |fieldReservedBitsDiagnostic"
  "§3.4 stream operand[19:0]     |streamReservedBitsDiagnostic"
  "§3.6 accel reserved[39:32]    |accelerator reserved field"
  "§3.7 thread operand[47:8]     |threadReservedBitsDiagnostic"
  "§3.5 cap operand[47:0]        |capReservedBitsDiagnostic"
)

# EXEMPTIONS -- declared reservations that CANNOT have an enforcement point, listed
# explicitly rather than omitted. `verifier` found §6 perms[7:3] missing from both
# lists during task-22 and ruled it a different class from F6/F15; that is correct,
# and it is exactly why it must still be NAMED here. A field that is absent from the
# audit is indistinguishable from a field nobody remembered, and that ambiguity is
# how F6 and F15 both survived. Silently skipping it would recreate the blind spot.
#
# §6 perms[7:3]: `Perms` is a packed struct with no raw-byte or @bitCast constructor
# and exactly one construction site (capability.zig:127) setting only named fields, so
# a non-zero value is UNREACHABLE rather than merely unchecked. No word can express
# it, so it cannot appear in the falsification list. The contract states the
# reservation AND the absence of enforcement; a diagnostic would be dead code.
exemptions=(
  "§6 perms[7:3]                 |unreachable by construction (no raw-byte Perms constructor)"
)

missing=0
for e in "${entries[@]}"; do
  label="${e%%|*}"
  pat="${e##*|}"
  if grep -qF -- "$pat" "$DECODER"; then
    printf '  OK    %s  <- %s\n' "$label" "$pat"
  else
    printf '  MISS  %s  <- no match for %s\n' "$label" "$pat"
    missing=$((missing + 1))
  fi
done

echo
for e in "${exemptions[@]}"; do
  label="${e%%|*}"
  why="${e##*|}"
  printf '  EXEMPT %s  <- %s\n' "$label" "$why"
done

echo
# Declared reservations in the document, for eyeballing against the list above.
declared=$(grep -cE 'reserved.*must be zero|must be zero.*reserved' "$DOC" || true)
echo "contract declares ~$declared reserved-must-be-zero statements"
echo "audited enforcement points: ${#entries[@]}"
echo

if [ "$missing" -ne 0 ]; then
  echo "RESULT: $missing declaration(s) have no enforcement point -- see MISS above."
  exit 1
fi

# The positive RESULT is printed AFTER the falsification half, not here. Printing it now
# meant a skimmer whose eye stopped at the last "RESULT:" line saw a green sentence while
# the exit code was 1 -- reported by `verifier` during task-22. One RESULT line, at the
# end, after every check has run.

# ---------------------------------------------------------------------------
# FALSIFICATION -- the half that matters.
#
# Grepping for a function name proves a check is *named*, not that it *fires*.
# So construct a word with each reserved field explicitly set and require the
# disassembler to reject it. This is the test that would have caught F6 and the
# stream operand[19:0] gap, both of which were "implemented" in prose only.
#
# F15 is the third instance and the reason the cap.* row was added: §3.5 declared
# operand[47:0] reserved while the decoder accepted 0x5023400000000000 as
# "cap.load R2, R3", dropping the bits. The field was never in either list here,
# which is exactly how it survived. Adding a declaration to the contract without
# adding it here is the mistake this file exists to prevent -- so a new reserved
# field is not done until it appears in BOTH the entries and the words arrays.
# ---------------------------------------------------------------------------

CLI=zig-out/bin/celeris64
if [ ! -x "$CLI" ]; then
  # NOT exit 0. A missing CLI means either the tree was not built or -- the case
  # that matters -- the build FAILED, and a failed build must never be reported
  # as a passing audit. This was found by fault injection: disabling the cap.*
  # check made capReservedBitsDiagnostic unreachable, the build errored, and this
  # branch exited 0 while silently skipping the half of the audit that proves
  # anything. A green audit that skipped its only real test is worse than a red
  # one, because nobody looks again.
  echo "FAIL: $CLI is not present, so the falsification half cannot run."
  echo "      Build the tree first: ~/.local/zig/zig build"
  echo "      If that build FAILS, this audit must not be treated as passing."
  exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# label | 64-bit word with that reserved field explicitly set
words=(
  "§3.0 nop operand set     |0x0010000000000000"
  "§3.0 jump rd set         |0x0210000000000010"
  "§3.1 ALU zero[39:28] set |0x1012000010000000"
  "§3.2.2 select [35:0] set |0x2110000000000001"
  "§3.3 field [27:0] set    |0x3010000000000001"
  "§3.4 stream [19:0] set   |0x4000000000000001"
  "§3.6 accel [39:32] set   |0x6000000100000000"
  "§3.7 thread [47:8] set   |0x90000000000001ff"
  "§3.5 cap [47:0] set      |0x5023400000000000"
)

echo "falsification -- each reserved field set explicitly, must be REJECTED:"
silent=0
for w in "${words[@]}"; do
  label="${w%%|*}"
  hex="${w##*|}"
  f="$tmp/w.bin"
  python3 -c "
import struct
open('$f','wb').write(struct.pack('<Q', int('$hex',16)))
"
  if out=$("$CLI" dis "$f" 2>&1); then
    printf '  SILENT (BAD)  %s  -> %s\n' "$label" "$out"
    silent=$((silent + 1))
  else
    printf '  rejected OK   %s\n' "$label"
  fi
done

echo
if [ "$silent" -eq 0 ]; then
  echo "RESULT: every audited declaration has an enforcement point (${#entries[@]} of ${#entries[@]})."
  echo "RESULT: all ${#words[@]} reserved fields are rejected when explicitly set."
  exit 0
fi
echo "RESULT: $silent reserved field(s) accepted silently -- contract says reject."
exit 1
