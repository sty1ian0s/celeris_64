#!/bin/bash
# Verifier artifact generator for task-22. Drives the REAL CLI and records the exact
# 64-bit word each instruction assembles to, plus the exact rejection text. The Zig
# test file then asserts on these recorded bits, so the test needs no file I/O of its
# own and the bits still come from the shipped binary.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
C=${CLI_OVERRIDE:-$(cd "$HERE/.." && pwd)/zig-out/bin/celeris64}
W=${OUT_DIR:-/tmp/v22gen}; rm -rf $W; mkdir -p $W
out=$W/words.txt; : > $out
emit() {  # emit <label> <line>
  local label="$1" line="$2"
  printf '%s\n' "$line" > $W/in.asm
  if $C asm $W/in.asm $W/out.bin >/dev/null 2>$W/err.txt; then
    python3 - "$label" "$W/out.bin" >> $out <<'PY'
import struct,sys
d=open(sys.argv[2],'rb').read()
w=struct.unpack('<Q',d[:8])[0]
print(f'{sys.argv[1]}|OK|{w:#018x}|{(w>>56)&0xFF}|{(w>>52)&0xF}|{(w>>48)&0xF}|{w&((1<<48)-1)}')
PY
  else
    printf '%s|REJECT|%s\n' "$label" "$(head -c 400 $W/err.txt | tr '\n' ' ')" >> $out
  fi
}
emit load_2_3 "cap.load R2, R3"
emit store_3_2 "cap.store R3, R2"
emit load_3_2 "cap.load R3, R2"
emit store_2_3 "cap.store R2, R3"
emit load_2_3_4 "cap.load R2, R3, R4"
emit store_2_4_6 "cap.store R2, R4, R6"
emit check_2_3 "cap.check R2, R3"
emit check_0_1 "cap.check R0, R1"
emit check_0_7 "cap.check R0, R7"
emit spawn_noslots "thread.spawn no slots, R0"
emit spawn_T0 "thread.spawn T0, R1"
emit spawn_T3 "thread.spawn T3, R1"
emit spawn_T7 "thread.spawn T7, R1"
emit spawn_T0T3T7 "thread.spawn T0, T3, T7, R1"
emit join_T2 "thread.join T2"
emit yield "thread.yield"
# full sweep of legal cap.load forms
for rd in 0 2 4 6 8 10; do for rs1 in 0 1 2 3 4 5 6 7 8 9 10 11; do
  emit "sweep_load_${rd}_${rs1}" "cap.load R${rd}, R${rs1}"; done; done
for rs1 in 0 2 4 6 8 10; do for rd in 0 1 2 3 4 5 6 7 8 9 10 11; do
  emit "sweep_store_${rd}_${rs1}" "cap.store R${rd}, R${rs1}"; done; done
for rd in 1 3 5 7 9 11; do for rs1 in 0 2 4 6 8 10; do
  emit "neg_load_${rd}_${rs1}" "cap.load R${rd}, R${rs1}"; done; done
for rs1 in 1 3 5 7 9 11; do for rd in 0 2 4 6 8 10; do
  emit "neg_store_${rd}_${rs1}" "cap.store R${rd}, R${rs1}"; done; done
echo "wrote $(wc -l < $out) entries"
