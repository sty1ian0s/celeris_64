# Independent verification report — Phase 4 RTL and contract v1.4–v1.6

Author: `verifier` (team task-15). Write scope: this file only. I wrote no code under
`rtl/`, `src/`, `docs/`, and did not touch `tests/vm_tests.zig`.

Everything below is an **observed** result with the command that produced it. Where I
could not test something I say **unverifiable** and why. Where I was wrong I say so.

Method note: the defect that started this phase (the imm28 40-vs-28 bit error) had a
signature — *a name stating one width, a diagram drawing another range, and two
implementations quietly disagreeing*. I hunted that pattern deliberately, and derived
field widths from the **architecture** (how many slots, how many registers, what range
does this quantity need) rather than from the contract text, because a width error cannot
be caught by a value-based test: a test that only ever exercises `T0` passes under both a
5-bit and an 8-bit mask.

---

## 1. Contract self-contradictions found

The dominant defect mode in `docs/isa-encoding.md` is **a normative claim in one section
that another section or the code contradicts**. Five confirmed instances, listed in the
order I found them. The first three were fixed by Lead in v1.4; the fourth in v1.6; the
fifth was still open when I last read v1.6.

### F3 — §2 promised "wide immediate forms" that §3.1 does not define
- **§2 text:** "Wide immediate forms consume `rs1` as additional immediate bits; see §3.1."
- **§3.1:** defines `rs2[47:44] | width[43:40] | zero[39:28] | imm28[27:0]` and says
  nothing about `rs1` extending the immediate. No implementation has such a form —
  `decoder.zig`'s ALU payload carries `op/rd/rs1/rs2/width/imm` only.
- **Which side is right:** §3.1. The §2 sentence promised an encoding that does not exist.
- **Status:** removed in v1.3. Lead found the same defect independently.

### F4 — §3.1 v1.2's reserved-bits rule read as global, but §3.4 reuses those bits
- **§3.1 v1.2:** "Bits `[39:28]` are therefore reserved and must be zero; a non-zero value
  is a diagnostic error (§7)."
- **§3.4:** "Encoding for `stream.setp`: `operand[39:0]` is a signed 40-bit byte stride."
- These overlap in `[39:28]`. Read literally, §3.1's amendment would have **rejected every
  legal `stream.setp`**.
- **Implementation** follows §3.4 (`decoder.zig` reads a `u40`), so this was a document
  defect, not a code bug.
- **Which side is right:** both, once scoped. A "reserved" claim in one section does not
  reserve those bits for every opcode.
- **Status:** fixed in v1.4 — reservations are now scoped **per instruction class, never
  global**, and §3.4 notes the deliberate overlap. Verified by re-reading v1.4.

### F5 — §6's `length` was 64-bit but "stored in `permissions[23:0]`"
- A 64-bit value cannot be held in 24 bits. `capability.zig` carries `length` as a full
  `u64` field beside `base` and `perms`; no such packing was ever written. The line
  hand-waved "see the model module for the current packing", which is how it survived.
- **Status:** removed in v1.4. Re-verified against `capability.zig:79-80`, which uses
  `base: u64, length: u64`.

### F6 — §3.1 v1.2 reserved the bits and declared a diagnostic; nobody implemented it
- **§3.1 v1.2:** non-zero `zero[39:28]` "is a diagnostic error (§7)".
- **Observed:** word `0x1012000010000000` (opcode `0x10`, `zero[39:28] = 1`) decodes
  **silently**:
  ```
  $ celeris64 dis alu_zero_bit.bin
  000000:  add R1, R2, R0          exit 0 — no diagnostic
  ```
  Same with all 12 reserved bits set (`0x101200fff0000000`).
- **Why this was a gap and not a design choice:** the accelerator reserved field *is*
  rejected (`0x6000000100000000` yields a full sentence naming "accelerator reserved
  field"), and thread bits are checked. The ALU path simply had no equivalent check.
- **Cross-implementation divergence:** `rtl/alu.sv:69` **did** implement it —
  `assign zero_err_o = !alu_zero_is_reserved_ok(alu_zero_i);` — and the RTL testbench
  passes both its negative vectors. So the hardware side was right and the software side
  was behind. This is exactly the imm28 shape: two implementations disagreeing on one word.
- **Status:** fixed. The ALU reserved word now yields a sentence and exit 1.

### F8 — §4 mandates two PC diagnostics; neither exists, and the write is silently discarded
- **§4 text:** "`14` | `PC` (readable; **writing it is a diagnostic error** outside jump
  forms)" and "in `rs1`/`rs2` it is legal for `SP`, `LR` and `FLAGS` and **a diagnostic
  error for `PC`**."
- **Observed:** all three assemble with exit 0 and no diagnostic —
  `add PC, R1, R2`, `add R0, PC, R1`, `add R0, R1, PC`.
- **Worse — the write is then silently thrown away.** `src/vm.zig:246` ends every
  `execute()` with `self.regs.pc = pc +| instruction_bytes;`, overwriting whatever the ALU
  wrote to index 14 (`src/registers.zig:123`). The trace prints `PC <- 0x18`, but that is
  the *normal advance*, not the computed value:
  ```
  $ celeris64 trace pctest.asm     # mov R1,100 ; mov R2,5 ; add PC,R1,R2 ; halt
    000016  add PC, R1, R2   # PC <- 0x0000000000000018
  ```
  A program can compute a jump, receive no error, and silently not jump.
- **Status:** fixed on both sides — assembler rejects it, and the VM faults so a
  hand-encoded binary cannot slip through.

### F9 — §4 described index 15 (FLAGS) as if it were ZERO
- **§4 text:** "`ZERO` has no index ... and any read of index `15` in a source position
  where a zero is required is not defined."
- Index 15 is **FLAGS** — §4's own table two lines above says so, and §2 lists ZERO as a
  separate system register with no index. A leftover from a draft where 15 was ZERO.
- **Status:** deleted in v1.4.

### F11 — v1.6 corrected the slot mask to `operand[7:0]` but left `operand[4:0] == 0` three paragraphs below
- **§3.7 opcode table (v1.6):** `thread.spawn` / `thread.join` act on `operand[7:0]`.
- **§3.7 reserved region (v1.6):** "The remaining bits `operand[47:8]` must be zero."
- **§3.7 Amendment 1.1 (normative), same section, line ~335:** "`operand[4:0] == 0` is a
  legal encoding that names no slot."
- The amendment still names the **old five-bit field**. The code uses `slot_mask: u8`
  (`src/assembler.zig:300`). A reader implementing Amendment 1.1 verbatim would test the
  wrong bits and would consider `T5`–`T7` outside the mask.
- **Status:** OPEN as of v1.6. Low functional severity (the semantic claim — "mask 0 is
  legal" — is still true), but it is the identical leftover-class defect as F9: a stale
  field reference surviving a width correction in the same section.
- **Suggested fix:** `operand[7:0] == 0`.
- Note the other two `operand[4:0]` hits in v1.6 (lines 298, 479) are **correct** — they
  are the historical narrative explaining the old width, not live claims.

---

## 2. Bit-position audit (derived from the architecture, not the text)

| Field | Architecture requirement | Declared | Verdict |
|---|---|---|---|
| §3.7 slot mask | 8 slots `T0`–`T7` → needs ≥3 bits to name the top slot | v1.5 and earlier `operand[4:0]` (5 bits) | **WRONG — could not express `T5`–`T7`.** Fixed to `operand[7:0]` in v1.6 |
| §3.7 reserved | remaining bits above the mask | `operand[47:5]` → `operand[47:8]` | corrected with the mask |
| §4 register index | 12 GPRs + SP, LR, PC, FLAGS = 16 indices | 4 bits (`rd[55:52]`, `rs1[51:48]`) | **CORRECT and exactly at capacity.** All four system registers present; ZERO correctly unassigned. Zero headroom — any new register needs a format change |
| §5 width suffix | 4 values (none/`.l`/`.w`/`.b`) → 2 bits suffice | 4 bits (`width[43:40]`) | **Over-wide by 2 bits, harmless.** Verified nothing indexes the field as a 16-element array (`width_enc_is_legal` / `width_bits` / `width_mask` are all comparisons). Reserved values 4–15 are rejected |
| §3.6 `count[31:0]` | element/byte count | 32 bits | **CONSISTENT** with `decoder.zig:249 count: u32`. No model imposes a larger limit in practice |
| §6 descriptor | 128-bit = 2 × 64-bit registers | `base` 64, perms bit 0/1/2 | **CORRECT** after F5. Reserved permission bits must be zero — but see U3 below |
| §2 word | 8 + 4 + 4 + 48 | 64 bits total | **SUMS CORRECTLY** |
| ALU operand (v1.2+) | `rs2[47:44]`, `width[43:40]`, `zero[39:28]`, `imm28[27:0]` | 4+4+12+28 = 48 | **SUMS CORRECTLY** |
| Accelerator operand (§3.6) | `rs2[47:44]`, `rs3[43:40]`, `reserved[39:32]`, `count[31:0]` | 4+4+8+32 = 48 | **SUMS CORRECTLY** |

### F10 (open) — §6's new reserved-permission-bits rule is again unimplemented
§6 v1.4 declares: "The remaining permission bits are reserved and must be zero; a
non-zero value is a diagnostic error (§7)."
`src/capability.zig:30` declares `_reserved: u5 = 0` inside `Perms`, and
`grep -n "_reserved" src/capability.zig` returns **that declaration line only** — the
field is never read, never validated, and never mentioned in any diagnostic path. It is a
placeholder, not an enforced rule. This is F6's pattern repeated: a normative reservation
added to the contract with no implementation behind it. I did not find a public entry
point that could construct a non-zero `_reserved` from a word today, which caps the
severity — but the contract claims a diagnostic that cannot exist.

### Opcode range allocation — no collisions
I checked every declared range pairwise for overlap: **none**. 77 of 256 opcode bytes are
inside a declared range; the remainder is unassigned space (`0x05–0x0F`, `0x1A–0x1F`,
`0x22–0x2F`, `0x32–0x3F`, `0x44–0x4F`, `0x53–0x5F`, `0x93–0xFF`).

---

## 3. F7 — a documented example panicked the assembler

The verbatim v1.4 §3.7 example `thread.spawn T0-T7, R0` **aborted the process**:

```
$ printf "thread.spawn T0-T7, R0\n" > ex.asm
$ celeris64 asm ex.asm ex.bin
thread 50066 panic: shift amount is greater than the type size
/home/steli/celeris_64/src/assembler.zig:934:66: in parseSlots
                    while (i <= b) : (i += 1) mask |= @as(u5, 1) << i;
EXIT=134  (SIGABRT)
```

Root cause (`src/assembler.zig:932-935`): `var i: u3 = a;` with `a=0, b=7`. The loop runs
`i=0..7`, then `i += 1` overflows a `u3` (max 7). Two bugs in one line — the induction
variable is too narrow, and `@as(u5,1) << i` has no guard against `i ≥ 8` even if it were.

This also breached §7 / AGENTS.md §4.2: a Zig panic with a stack trace is not a
plain-language sentence, and it is the one failure mode the diagnostics contract exists to
forbid. **Fixed by `tooling`; verified by Lead: now exit 0.**

**This finding mattered more than it looked.** While `T0-T7` merely aborted, the malformed
word it *would* have produced stayed invisible. Once it assembled, Lead checked the word
arithmetically and found that a 5-bit `operand[4:0]` cannot address 8 slots — the contract
forbade the word its own slot range required (now F1/§3.7, fixed in v1.6). My abort finding
and that width defect are one bug seen from two ends.

The other five verbatim §3.7 examples all assemble and round-trip:

| Input | Result |
|---|---|
| `thread.spawn T0, R0` | OK → `thread.spawn T0, R0` |
| `thread.spawn T0, T2, R0` | OK → `thread.spawn T0, T2, R0` |
| `thread.spawn no slots, R0` | OK → `thread.spawn no slots, R0` |
| `thread.join T0, T2` | OK → `thread.join T0, T2` |
| `thread.yield` | OK → `thread.yield` |
| `thread.spawn T0-T7, R0` | **PANIC** (now fixed) |

---

## 4. Round-trip, typed as a user types it (no `sed`)

17-instruction program: all 13 §3.6 accelerators, `count=N` on seven of them, and mask-0
thread words.

```
$ celeris64 asm prog.asm prog.bin      -> assembled 17 instructions into "prog.bin" (136 bytes). exit 0
$ celeris64 dis prog.bin > prog.dis    -> exit 0
$ celeris64 asm prog.dis again.bin     -> assembled 17 instructions into "again.bin" (136 bytes). exit 0
$ cmp prog.bin again.bin               -> IDENTICAL
```

**This claim HOLDS**, and the disassembly is readable, e.g.
`matrix.transform R8, R9, count=16`, `fft.ntt.inverse R7, R8, R9, count=8`,
`codec.decompress R2, R3, count=128`, `thread.spawn no slots, R0`.

### Break attempts

| Hand-crafted binary | Observed behaviour |
|---|---|
| reserved accel `0x6E` | `.raw 110, 0` — reassembles **byte-identically** |
| reserved accel `0x6F` | `.raw 111, 0` — byte-identical |
| reserved accel `0x8F` | `.raw 143, 0` — byte-identical |
| unknown opcode `0xAB` | full sentence naming `opcode 171 (171)`, exit 0, no panic |
| `0xFFFFFFFFFFFFFFFF` | full sentence naming `opcode 255 (255)`, no panic |
| non-zero accelerator `reserved[39:32]` | rejected with a sentence naming "accelerator reserved field" |
| non-zero ALU `zero[39:28]` | **was silently accepted** (F6, now fixed) |
| `nop` with a stray operand | decodes as `nop`, not flagged — §3.0 says "unused, must be zero", so arguably a further unchecked reserved field. Passed to `tooling` to implement or explicitly decline |

Reserved opcodes round-trip **without being reinterpreted as a neighbour** — the claim
holds, and the `.raw` mechanism is a genuinely good design.

---

## 5. Disassembler test root — independently verified by fault injection

Lead's account was that `zig build test` previously reported green while all disassembler
tests never compiled. I confirmed the fix myself rather than trusting it.

```
$ md5sum src/disassembler.zig            -> 6325dfffc9ad0762a2860a6004e8c4a6  (backed up first)
$ zig test src/disassembler.zig          -> All 56 tests passed.
# injected one failing assertion into a test BODY at src/disassembler.zig:530:
$ zig build test
    Build Summary: 33/35 steps succeeded (1 failed); 55/56 tests passed (1 failed)
    failed command: .../test ... 
    src/disassembler.zig:530:13: in test.non-zero reserved bits are reported as a sentence...
  EXIT=1
# restored byte-identically:
$ cp /tmp/dis_backup.zig src/disassembler.zig ; md5sum src/disassembler.zig
    6325dfffc9ad0762a2860a6004e8c4a6   (matches)
$ zig build test                          -> EXIT=0
```

**CONFIRMED**: a fault in `src/disassembler.zig` now fails `zig build test`, and restoring
it makes the suite pass. The root genuinely compiles that file's tests. Baseline is
`Build Summary: 35/35 steps succeeded`.

---

## 6. RTL — what I ran, what held, what is unresolved

### ALU + register file: PASSES (80/80)
```
$ verilator --binary -j 0 -Wno-UNUSEDPARAM --top-module alu_tb --Mdir /tmp/vsim/obj_alu2 \
    -CFLAGS "-std=c++20" -LDFLAGS "-std=c++20" \
    rtl/pkg/celeris64_pkg.sv rtl/regfile.sv rtl/alu.sv rtl/tb/alu_tb.sv
  BUILD_EXIT=0
$ /tmp/vsim/obj_alu2/Valu_tb
  === checks=80 failures=0 ===
  PASS: all 80 alu/regfile vectors matched (simulation only; RTL is NOT synthesized)
  SIM_EXIT=0
```
This covers sub-width zero-extension (`.l`/`.w`/`.b`), imm28 sign-extension including
`0x08000000 -> 0xFFFFFFFFF8000000`, reserved width 4 and 15, and — importantly — **both
negative `zero[39:28]` vectors plus the `zero == 0` positive control**. The positive
control is what makes the negatives meaningful: a check that fires on everything is as
useless as one that never fires.

The testbench prints "(simulation only; RTL is NOT synthesized)" itself, satisfying §8.

**Self-correction.** My first run of this testbench reported **2 failures** and I was
about to file it. It was a **stale artifact**: `rtl/alu.sv` and the package were both
newer than my compiled binary, i.e. a mid-write race. A clean rebuild gave 80/80. I
retracted the failure rather than filing it, and I mention it here because a verifier's
errors must be as visible as its findings.

### Stream testbench: FAILS 117/309 — and I attribute it to the HARNESS, not the engine
```
$ /tmp/vsim/obj_s4/Vstream_tb
  checks run: 309, failures: 117
  FAIL: 117 of 309 assertions failed
  SIM_EXIT=1
```
Reproduced three times from clean Mdirs after the sources stopped changing (mtimes
checked first: `stream_engine.sv` 20:55:42, `stream_tb.sv` 20:58:56, runs at 21:00+).
Representative failures:
```
FAIL: §3.4: zero chunk writes nothing: byte 19 is 0x00 expected 0x11
FAIL: §3.4 add: element 0 is 10+5: got 0x1e1e1e1e1e1e1e0f expected 0x000000000000000f
FAIL: §3.4 add: pointer advanced by 32: got 0x0000000000000001 expected 0x0000000000000020
FAIL: ATOMICITY: memory byte-for-byte unchanged: byte 0 is 0xa5 expected 0xdd
FAIL: §3.3 U3 round-trip extract == 0b101: got 0x0000000000000007 expected 0x0000000000000005
```

**Three independent tells say this is the harness:**
1. "zero chunk writes nothing" fails on a **pre-condition** — memory preloaded with `0x11`
   reads back `0x00`. A DUT cannot zero memory it was never asked to touch.
2. Byte 0 reads `0xa5` on the ATOMICITY check while the same run elsewhere expects `0xdd`
   and `0x11`. `mem[]` is observed with values from a **different vector's** initialisation.
3. The ATOMICITY failure is not the shape of a partial write. A partial-application bug
   would show *some* bytes changed to the written value and the rest untouched; instead the
   observed value is a fill constant from another vector. That is state bleed, not a
   partially applied chunk.

**Specific harness defects, with line numbers:**
- `rtl/tb/stream_tb.sv:204` — the DUT exposes **one byte** (`mem_wr_byte_o`, 8 bits) plus
  an 8-bit lane mask, but the harness writes that same byte into every selected lane:
  `if (se_mem_byte_sel[b]) mem[ADDR_W'(wr_addr_q + ADDR_W'(b))] <= se_mem_wr_byte;`
  With `byte_sel = 8'hFF` this replicates one byte across eight addresses, which matches
  the `0x1e1e1e1e1e1e1e0f` reading.
- Memory is **32 bytes** (`MEM_BYTES=32`, `ADDR_W=5`, line 182) and `wr_addr_q` is
  truncated to 5 bits (line 190) while `region_len` is driven from `MEM_BYTES`. A chunk
  near the end therefore **wraps inside the array instead of being refused**, so bounds
  vectors can alias onto bytes 0–31 — consistent with ATOMICITY observing `0xa5` at byte 0.
- `mem` is written with non-blocking assignments in `always_ff` (line 204) and read
  combinationally (line 198), so vectors can sample before an update lands.

**I therefore do not report RTL atomicity as broken, and I do not report it as working.**
It is **unverifiable** until the harness is fixed. I attempted my own independent
testbench and abandoned it rather than ship a second harness with its own bugs; that is a
limitation of this report, stated plainly rather than papered over.

### Lint — the stated acceptance criterion is not literally achievable
```
$ verilator --lint-only -Wall rtl/pkg/celeris64_pkg.sv rtl/regfile.sv rtl/alu.sv
  %Warning-MULTITOP: rtl/alu.sv:25:8: Multiple top level modules
  %Error: Exiting due to 1 warning(s)     exit=1
```
Two independent causes: MULTITOP when two tops are passed together, and `UNUSEDPARAM` for
every package localparam a given top does not reference (only a top instantiating
`regfile` consumes `REG_SP/LR/PC/FLAGS` and `GPR_COUNT/GPR_INDEX_MAX`). Isolated per module
with `--top-module`: `regfile` exits 0 clean; every other module exits 1 with
**UNUSEDPARAM warnings only**. I checked specifically that no width, latch, or
combinational-loop warning is hiding among them — that check is the one that mattered,
since six harmless warnings would happily mask a real one.

Ruling applied by Lead: the authoritative command is the whole tree with `--top-module core`,
run as part of task-14's acceptance. **`rtl/core.sv` did not lint clean when I tried it, but
task-14 was still in progress and `rtl-core2` was mid-write, so per the mid-write rule I
note it rather than filing it.** The errors I saw (for the record, to be re-checked after
task-14 settles):
```
%Error-PINNOTFOUND: rtl/core.sv:409:6: Pin not found: 'ptr_q_i'  (stream_engine offers 'ptr_d_o')
%Warning-IMPLICIT: rtl/core.sv:390:25: Signal definition not found, creating implicitly: 'st_issue'
%Warning-PINCONNECTEMPTY ×6: rs2_idx_o, true_idx_o, false_idx_o, src2_idx_o, width_err_o ×2
```

### Verilator PCH quirk (toolchain, **not** an RTL defect)
`--binary` fails on rebuild with:
```
c++: error: Vstream_tb__pch.h.fast: linker input file not found: No such file or directory
make: *** [/home/steli/.local/verilator/include/verilated.mk:289: Vstream_tb.o] Error 1
```
Cause: `verilated.mk:300` declares `%.fast.gch: %`, so building the precompiled header
requires a bare `Vstream_tb__pch.h.fast`, but Verilator only emits `Vstream_tb__pch.h` and
`...__pch.h.fast.gch`. The prerequisite is never created, so `c++` is handed a nonexistent
path. Workaround: after one Verilator invocation, in the Mdir, copy `Vstream_tb__pch.h` to
`Vstream_tb__pch.h.fast` and `.slow`, `make` the two `.gch` targets, then `make`. Recorded
so nobody files the build failure as a code bug.

### `call`/LR
Not yet re-verified in RTL. `rtl/core.sv` is task-14's file and was mid-write; the historic
Zig-side bug (E, `call` decoded as `jump`, LR never set) was fixed and I verified it
end-to-end in the simulator (`call -> PC=32 LR=8`, then `ret -> PC=8`). **RTL-side
`call`/LR is UNVERIFIABLE until `rtl/core.sv` and `core_tb.sv` settle.** This is the
cross-check I most want to complete, because it is a known historic bug site.

---

## 7. Fidelity audit — PASSES

Benchmark output (`zig-out/bin/celeris64-bench`), every line checked programmatically:
```
$ ./zig-out/bin/celeris64-bench | awk 'NF && !/simulated/ {n++} END {print n+0}'
  0
```
Every non-blank line contains the word "simulated", including the closing line
"It is a simulated count of instructions, not a claim about speed."

Documentation and RTL header scan for forbidden claims (`GHz`, `MHz`, timing closure,
tape-out, silicon performance):
- `docs/fidelity.md:197` — "No clock frequency, timing figure, area figure or silicon
  performance claim".
- `docs/fpga-prototyping.md:200-202` — explicitly tabulates and refuses a clock-frequency
  claim and a silicon performance figure.
- `docs/isa-encoding.md:434` — RTL entry says "Never synthesized, never timing-closed,
  never placed on real silicon. No clock frequency is claimed."
- Every `rtl/*.sv` header carries "NEVER synthesized, never timing-closed, never on
  silicon. No frequency claimed."
- `rtl/tb/alu_tb.sv` prints "(simulation only; RTL is NOT synthesized)" at runtime.

**One inconsistency worth flagging (documentation accuracy, not a fidelity breach):**
`docs/isa-encoding.md:434` states the RTL "passes `verilator --lint-only -Wall`". As shown
in §6, that command does **not** exit 0 on this tree without `--top-module`. The claim is
directionally honest (the modules are well-formed) but literally false as written. Suggest
naming the exact command, e.g. "`verilator --lint-only -Wall --top-module core` over the
whole `rtl/` tree".

---

## 8. Summary

**What broke (13 findings):** F3, F4, F5, F9, F11 (contract self-contradictions — all fixed
except F11, still open in v1.6); F6, F8, F10 (normative claims with no implementation —
F6 and F8 fixed, F10 open); F7 (assembler SIGABRT on a documented example — fixed);
harness defects in `rtl/tb/stream_tb.sv` (open); `rtl/core.sv` lint errors (mid-write, to
re-check); the task-12 lint criterion being unachievable as written; and the
`docs/isa-encoding.md:434` lint claim.

**What held:** the full CLI round-trip (17 instructions, all 13 accelerators, `count=N`,
mask-0 threads) byte-identical; reserved opcodes `0x6E`/`0x6F`/`0x8F` round-tripping as
raw bytes without reinterpretation; malformed words diagnosed as sentences with no panic;
the disassembler test root (fault injection confirmed both directions); ALU + register
file RTL at 80/80 including both polarities of the reserved-field check; the bit arithmetic
of the word layout, ALU operand and accelerator operand all summing to 48 bits; no opcode
range collisions; and every fidelity claim.

**Unverifiable, with reasons:**
1. **RTL stream atomicity** — harness defects (§6). Neither confirmed nor refuted.
2. **RTL `call`/LR and the full RTL-vs-simulator divergence table** — `rtl/core.sv` still
   mid-write; I have the simulator reference values but no settled RTL top to compare.
3. **F10's user-visible impact** — I found no public path that constructs a non-zero
   `_reserved`, so the contract claims a diagnostic that cannot currently be triggered.
   The claim is unimplemented; whether it is *reachable* is untested.
4. **RTL synthesis, timing, or hardware behaviour of any kind** — no yosys, no FPGA, no
   vendor toolchain on this host. Never synthesized, never timing-closed.

**Highest-value next step:** fix `rtl/tb/stream_tb.sv`'s memory model (one preloaded byte
must round-trip; the 32-byte array must REFUSE out-of-range addresses rather than truncate
via `ADDR_W=5`; one DUT byte must not be replicated across all eight lanes), then re-run.
Until that happens the RTL atomicity claim — the single most important semantic guarantee in
this project — is untested in hardware and tested only in software.
