#!/usr/bin/env bash
# End-to-end check for §3.6 amendment 1.19: `matrix.mulout` (0x65) executes.
#
#   bash tests/mulout_e2e.sh
#
# WHAT THIS PROVES, AND WHAT IT DOES NOT
#   Proves: asm source -> `celeris64 asm` -> `celeris64 run-bin` -> execution, with the
#   PRODUCT READ BACK BY THE PROGRAM ITSELF and compared against a reference computed
#   by python3's own arithmetic here. The reference never calls src/matrix.zig, so
#   agreement is not the model grading its own homework.
#
#   `run-bin` does not write the image back out, so the shell cannot diff the result
#   file. The program therefore loads every product element, compares it with the
#   reference constant, and halts ONLY when all four match; each mismatch path jumps
#   into the data region, which the simulator faults on loudly. Exit code 0 is the
#   evidence, and a mismatch cannot look like success.
#
#   Does NOT prove that the encoding matches real hardware. CLS64 has no LLVM backend,
#   so its words are only ever checked against this repository's own decoder/encoder
#   pair. That is self-consistency, not independent verification.
#
# REBUILD FIRST. `zig-out/bin/celeris64` is refreshed only by `zig build`, and a stale
# binary reads exactly like a real result (docs/HANDOFF.md §4), so this refuses to run
# when the binary is older than src/vm.zig.
set -euo pipefail

# Always rebuild before observing: `zig-out/bin/celeris64` is refreshed only by this
# command, and a stale binary reads exactly like a real result. `zig build` is a no-op
# when only tests changed, which would leave the binary OLDER than src/vm.zig; touching
# it after a successful build records that the binary is current with the sources.
cd "$(dirname "$0")/.."
ZIG="${ZIG:-$HOME/.local/zig/zig}"
"$ZIG" build || { echo "FAIL: '$ZIG build' failed" >&2; exit 1; }
touch zig-out/bin/celeris64
CC_BIN=zig-out/bin/celeris64
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [[ ! -x "$CC_BIN" ]]; then
  echo "FAIL: $CC_BIN is missing. Run '$ZIG build' first." >&2
  exit 1
fi
if [[ src/vm.zig -nt "$CC_BIN" ]]; then
  echo "FAIL: $CC_BIN is older than src/vm.zig. Run '$ZIG build' first — a stale binary reads like a real result." >&2
  exit 1
fi

checks=0
fail=0
pass() { checks=$((checks + 1)); echo "  ok   $1"; }
bad() { checks=$((checks + 1)); fail=$((fail + 1)); echo "  FAIL $1"; }

# --- the reference, computed here and independently of the simulator -------
# A is 2x3 and B is 3x2, written as explicit element lists; the product is the
# textbook sum over t of A[i][t] * B[t][j]. Nothing here reads src/.
_ref="$(python3 - <<'PY'
A = [[1.0, 2.0, 3.0], [4.0, 5.0, 6.0]]
B = [[7.0, 8.0], [9.0, 10.0], [11.0, 12.0]]
P = [[sum(A[i][t] * B[t][j] for t in range(3)) for j in range(2)] for i in range(2)]
print(" ".join(str(int(v)) for v in (P[0][0], P[0][1], P[1][0], P[1][1])))
PY
)"
read -r R00 R01 R10 R11 <<<"$_ref"
echo "reference product (python3, no Zig involved): [[$R00, $R01], [$R10, $R11]]"

# --- data layout ----------------------------------------------------------
# The data base is 1024, well clear of the 208-byte self-checking program. `mov`'s
# immediate is signed 28 bits, so every address here is encodable as a literal.
#   A   at byte 1024 (0x0400): header 2,3 then six f64 -- 8 + 48 = 56 bytes
#   B   at byte 1088 (0x0440): header 3,2 then six f64
#   OUT at byte 1216 (0x04C0): writable header + four f64, written by matrix.mulout
python3 - "$TMP/data.bin" <<'PY'
import struct, sys
img = bytearray()

def at(addr, payload):
    assert addr >= len(img), "address %d overlaps the image (%d bytes)" % (addr, len(img))
    img.extend(bytes(addr - len(img)))
    img.extend(payload)

def mat(rows, cols, vals):
    out = struct.pack("<II", rows, cols)
    for v in vals:
        out += struct.pack("<d", float(v))
    return out

at(0x0400, mat(2, 3, [1, 2, 3, 4, 5, 6]))
at(0x0440, mat(3, 2, [7, 8, 9, 10, 11, 12]))
at(0x04C0, bytes(0x28))   # the product's 8-byte header plus four f64, zeroed
# The four expected products, as f64, so the program compares bit patterns with bit
# patterns. Rule E.2 stores f64 results by reinterpretation, so comparing a product
# against an INTEGER 58 would never match: 58.0 is 0x404D000000000000.
at(0x0500, struct.pack("<4d", 58.0, 64.0, 139.0, 154.0))
open(sys.argv[1], "wb").write(img)
PY

# Splices a program in front of the data region. The program must fit below byte 256.
splice() {
  python3 - "$1" "$TMP/data.bin" <<'PY'
import sys
DATA_BASE = 0x0400
prog = bytearray(open(sys.argv[1], "rb").read())
data = bytearray(open(sys.argv[2], "rb").read())
# `data.bin` was built by `at()`, which pads from address 0, so it already carries
# its own leading zeros: it is placed as-is and must NOT be padded again.
assert len(prog) <= DATA_BASE, "program is %d bytes and would overlap the data at %d" % (len(prog), DATA_BASE)
out = bytearray(len(data))
out[: len(prog)] = prog
out[DATA_BASE:] = data[DATA_BASE:]
open(sys.argv[1], "wb").write(out)
PY
}

# --- the self-checking program --------------------------------------------
# `matrix.mulout R3, R1, R2`: rd = product address, rs1 = A address, rs2 = B address.
cat >"$TMP/mul.asm" <<ASM
    mov R1, 1024         # A   at 0x0400
    mov R2, 1088         # B   at 0x0440
    mov R3, 1216         # OUT at 0x04C0
    matrix.mulout R3, R1, R2
    mov R4, 1224         # OUT + 8, first product element
    load R5, [R4+0]      # product[0][0]
    load R6, [R4+8]      # product[0][1]
    load R7, [R4+16]     # product[1][0]
    load R8, [R4+24]     # product[1][1]
    mov R11, 1280        # EXPECTED at 0x0500
    load R9, [R11+0]
    compare R10, R5, R9
    branch R10, [EQUAL], el00
    jump 400000          # a mismatch leaves the 64 KiB image, which faults loudly
el00:
    load R9, [R11+8]
    compare R10, R6, R9
    branch R10, [EQUAL], el01
    jump 400000
el01:
    load R9, [R11+16]
    compare R10, R7, R9
    branch R10, [EQUAL], el10
    jump 400000
el10:
    load R9, [R11+24]
    compare R10, R8, R9
    branch R10, [EQUAL], done
    jump 400000
done:
    halt
ASM

if ! "$CC_BIN" asm "$TMP/mul.asm" "$TMP/mul.bin" >"$TMP/asm.log" 2>&1; then
  echo "FAIL: the assembler rejected the program:"; cat "$TMP/asm.log"; exit 1
fi
echo "asm: $(stat -c%s "$TMP/mul.bin") bytes of program"
# Keep the program-only image: `dis` must see instructions, not the data region.
cp "$TMP/mul.bin" "$TMP/mul_prog.bin"
splice "$TMP/mul.bin"

echo "run-bin (exit 0 means the program itself confirmed all four product elements):"
if "$CC_BIN" run-bin "$TMP/mul.bin" >"$TMP/run.log" 2>&1; then
  sed 's/^/    /' "$TMP/run.log"
  pass "matrix.mulout produced [[$R00, $R01], [$R10, $R11]] — the program loaded it back and matched"
else
  sed 's/^/    /' "$TMP/run.log"
  bad "run-bin exited non-zero, so the product did not match the reference"
fi

# --- the check has teeth: one WRONG reference constant must fail -----------
# If the program accepted anything, this would also exit 0. It must not.
cat >"$TMP/teeth.asm" <<ASM
    mov R1, 1024
    mov R2, 1088
    mov R3, 1216
    matrix.mulout R3, R1, R2
    mov R4, 1224
    load R5, [R4+0]
    mov R11, 1280
    load R9, [R11+8]     # deliberately WRONG: the expected value for element 0
    compare R10, R5, R9
    branch R10, [EQUAL], ok
    jump 400000
ok:
    halt
ASM
"$CC_BIN" asm "$TMP/teeth.asm" "$TMP/teeth.bin" >/dev/null 2>&1
splice "$TMP/teeth.bin"
if "$CC_BIN" run-bin "$TMP/teeth.bin" >"$TMP/teeth.log" 2>&1; then
  bad "a WRONG expected constant also exited 0, so the self-check proves nothing"
else
  pass "the self-check has teeth: a wrong constant faults instead of passing"
fi

# --- 0x62 keeps its old meaning, with its original sentence ----------------
cat >"$TMP/old.asm" <<'ASM'
    matrix.mul R1, R2, R3
    halt
ASM
if "$CC_BIN" run "$TMP/old.asm" >"$TMP/old.log" 2>&1; then
  bad "matrix.mul (0x62) exited 0; it must still refuse"
else
  if grep -q "E.5" "$TMP/old.log" && grep -q "matrix.mul" "$TMP/old.log"; then
    pass "0x62 matrix.mul still refuses, naming itself and rule E.5"
    sed 's/^/    /' "$TMP/old.log"
  else
    bad "0x62 refuses, but its sentence changed:"; sed 's/^/    /' "$TMP/old.log"
  fi
fi

# --- a dimension mismatch is a sentence, not a wrong answer ----------------
cat >"$TMP/bad.asm" <<'ASM'
    mov R1, 1024
    mov R2, 1088
    mov R3, 1216
    matrix.mulout R3, R1, R2
    halt
ASM
"$CC_BIN" asm "$TMP/bad.asm" "$TMP/bad.bin" >/dev/null
python3 - "$TMP/bad.bin" <<'PY'
import struct, sys
img = bytearray(open(sys.argv[1], "rb").read())
def at(addr, payload):
    assert addr >= len(img), "address %d overlaps the program (%d bytes)" % (addr, len(img))
    img.extend(bytes(addr - len(img)))
    img.extend(payload)
def mat(rows, cols, vals):
    out = struct.pack("<II", rows, cols)
    for v in vals:
        out += struct.pack("<d", float(v))
    return out
at(0x0400, mat(2, 3, [1, 2, 3, 4, 5, 6]))   # A: 2x3
at(0x0440, mat(4, 1, [1, 2, 3, 4]))          # B: FOUR rows -- A's 3 columns cannot reach
at(0x04C0, bytes(0x28))
open(sys.argv[1], "wb").write(img)
PY
if "$CC_BIN" run-bin "$TMP/bad.bin" >"$TMP/bad.log" 2>&1; then
  bad "a 2x3 times 4x1 product exited 0; it must refuse"
else
  if grep -q "3 columns" "$TMP/bad.log" && grep -q "4 rows" "$TMP/bad.log"; then
    pass "dimension mismatch refuses in plain language"
    sed 's/^/    /' "$TMP/bad.log"
  else
    bad "dimension mismatch refused with an unexpected sentence:"; sed 's/^/    /' "$TMP/bad.log"
  fi
fi

# --- the disassembler names the new opcode -------------------------------
if "$CC_BIN" dis "$TMP/old.bin" >/dev/null 2>&1 || true; then :; fi
head -c "$(stat -c%s "$TMP/mul_prog.bin")" "$TMP/mul.bin" >"$TMP/prog_only.bin"
if "$CC_BIN" dis "$TMP/prog_only.bin" | grep -q "matrix.mulout R3, R1, R2"; then
  pass "dis names 0x65 as matrix.mulout"
else
  bad "dis does not name 0x65 as matrix.mulout"
  head -6 "$TMP/mul.dis" | sed 's/^/    /'
fi

# --- dis -> asm reproduces the program words exactly ----------------------
"$CC_BIN" dis "$TMP/mul_prog.bin" >"$TMP/rt.dis" 2>&1 || true
if "$CC_BIN" asm "$TMP/rt.dis" "$TMP/rt.bin" >"$TMP/rt.log" 2>&1; then
  if head -c "$(stat -c%s "$TMP/rt.bin")" "$TMP/mul.bin" | cmp -s - "$TMP/rt.bin"; then
    pass "dis -> asm round-trips the program words byte for byte ($(($(stat -c%s "$TMP/rt.bin") / 8)) words)"
  else
    bad "dis -> asm did not reproduce the program bytes"
  fi
else
  bad "dis -> asm failed:"; sed 's/^/    /' "$TMP/rt.log"
fi

echo
if ((fail == 0)); then
  echo "$checks/$checks checks passed"
else
  echo "$((checks - fail))/$checks checks passed, $fail FAILED"
  exit 1
fi
