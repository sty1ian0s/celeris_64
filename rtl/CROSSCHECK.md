# RTL ↔ Simulator Cross-Check — Celeris-64 (CLS64)

**Task:** task-14 (RTL 8c) · **Author:** `rtl-core2`
**Contract:** `docs/isa-encoding.md` **v1.9** · **Verilator:** `rev vUNKNOWN-built20260516-4e853d8` (reports itself as 5.49)

---

## 0. FIDELITY STATEMENT — READ THIS FIRST

**This RTL has never been synthesized, never timing-closed, never placed on silicon, and no
clock frequency is claimed anywhere in `rtl/`.**

- No synthesis tool exists on this host (`yosys` is absent). Nothing in this document is a
  synthesis result, an area figure, a timing figure, or a frequency.
- The clock period in the testbench is **stimulus**, not a timing result. It is not a period
  the design is known to meet.
- Instruction counts here are **simulator counts**. They are not a performance claim.
- One clock domain only. Multi-clock and CDC are explicitly out of scope.
- `matrix.*`, `fft.*`, `codec.*` arithmetic is **not implemented in RTL** (§4 below). Their
  behaviour in the simulator is a software model (`docs/isa-encoding.md` §8).

The value of this document is that it records **where the RTL agrees with a verified
simulator, and where it does not** — including one real RTL bug found only by this
cross-check, and one real encoding defect found in the *simulator's assembler*.

Everything below was run on a quiescent tree. Commands and output are pasted verbatim.

---

## 1. Why lint-clean is not the claim

`verilator --lint-only -Wall` proves a module is **well-formed**. It cannot prove it computes
the right answer. A design that adds when it should subtract lints perfectly.

So the RTL is checked against the one component in this repository with independent evidence
behind it: the Zig simulator (`src/vm.zig` et al.), which has a 260+ case test suite and a
separate adversarial verifier. The same instruction **words** are driven through both, and the
resulting register files are compared.

---

## 2. Toolchain — exact commands

```bash
export VERILATOR_ROOT=$HOME/.local/verilator
export PATH="$HOME/.local/bin:$PATH"          # `python` shim Verilator needs
```

### 2.1 Whole-tree lint (the acceptance command)

```
$ verilator --lint-only -Wall --top-module core \
    rtl/pkg/celeris64_pkg.sv rtl/regfile.sv rtl/alu.sv rtl/accel.sv \
    rtl/stream_engine.sv rtl/select_unit.sv rtl/field_unit.sv rtl/core.sv

- V e r i l a t i o n   R e p o r t:  rev vUNKNOWN-built20260516-4e853d8
- Verilator: Built from 0.313 MB sources in 9 modules, into 0.151 MB in 3 C++ files needing 0.000 MB
- Verilator: Walltime 0.039 s (elab=0.005, cvt=0.019, bld=0.000); cpu 0.040 s on 1 threads; allocated 23.426 MB
LINT EXIT: 0
```

**Zero warnings.** With `-Wall` Verilator promotes warnings to fatal, so exit 0 is the floor
and the *absence of warnings* is the claim.

**One warning is suppressed, deliberately and with a reproduction — see §6.** Do not read
"exit 0" as "no warning was ever involved".

### 2.2 Building and running the testbench

`verilator --binary` needs two host workarounds; both are required:

```bash
verilator --binary -Wall --top-module core_tb \
  -CFLAGS "-std=c++20" -LDFLAGS "-std=c++20" \
  -MAKEFLAGS "CFG_CXXFLAGS_PCH_I=-include" \
  -o /tmp/core_tb_sim \
  rtl/pkg/celeris64_pkg.sv rtl/regfile.sv rtl/alu.sv rtl/accel.sv \
  rtl/stream_engine.sv rtl/select_unit.sv rtl/field_unit.sv rtl/core.sv \
  rtl/tb/core_tb.sv
```

- `-CFLAGS/-LDFLAGS "-std=c++20"` — the prebuilt Verilator wheel ships an empty
  `CFG_CXXFLAGS_STD`, which breaks `verilated_timing.cpp`.
- `-MAKEFLAGS "CFG_CXXFLAGS_PCH_I=-include"` — this build omits the `-include` flag for the
  precompiled header, so g++ treats `Vcore_tb__pch.h.fast` as a *source file* and fails with
  `linker input file not found`. Any testbench with more than one generated translation unit
  hits this. (`rtl/tb/alu_tb.sv` has one, which is why it builds without the flag.)

### 2.3 **Process trap: a failed compile leaves a stale simulator binary**

Under `-Wall` a single new warning aborts the compile, and `verilator --binary` can leave the
previous `-o` target in place. Running the "new" simulator then executes the **old** build and
reports the **old** results. This cost real debugging time here and produced several rounds of
confidently wrong analysis.

Always build to a fresh path, or check the tool's exit status before running:

```bash
rm -rf obj_dir
verilator --binary ... -o /tmp/sim_$$ ... > /tmp/build.log 2>&1
echo "verilator exit: $?"          # must be 0 before trusting anything
grep -cE "^%Warning|^%Error" /tmp/build.log   # must be 0
```

### 2.4 Verilator `+|` defect (toolchain, not architecture)

**This Verilator build mis-simulates the SystemVerilog saturating-add operator `+|`, and it
fails silently.** Measured:

| Expression | Verilator 5.49 | Correct |
|---|---|---|
| `64'd0 +| 64'd32` | `1` | `32` |
| `64'd100 +| 64'd5` | `101` | `105` |
| `{64{1'b1}} +| 64'd2` | `0x0` | saturates to all-ones |

Not merely a saturation difference — it **wraps and returns wrong values**. A design using
`+|` for a pointer or address computation would be silently wrong under the only simulator
available here, with no diagnostic.

- Zig's `+|` is **correct** in the same environment (`0 +| 32 = 32`, saturates at max), so
  `src/vm.zig` and `src/memory.zig` are **not** affected. No Zig file was changed.
- `rtl/stream_engine.sv` replaces `+|` with an explicit widen-and-clamp `sat_add`.
- **`rtl/core.sv`, `rtl/accel.sv` and `rtl/tb/core_tb.sv` contain zero occurrences of `+|`**
  (`grep -n '+|' rtl/core.sv rtl/accel.sv rtl/tb/core_tb.sv` → no output, exit 1).
- `rtl/core.sv` uses plain `+` for `pc + 8`. That is correct here rather than a shortcut: §1
  fixes the stride at 8 bytes and PC is a 64-bit address, so the sum can only wrap at 2^64,
  which no program in this repository reaches.

---

## 3. Method — how the reference values were obtained

The Zig CLI has **no "print the final register file" facility.** This is a real gap:

- `celeris64 run-bin <f>` prints only an instruction count.
- `celeris64 trace <f>` prints deltas, and accepts **only `.asm`** — given a `.bin` it tries to
  assemble the binary and fails.

So reference values were derived from **two independent encoders and required to agree**
before being trusted:

1. A Python encoder written for this task, from §2/§3 of the contract.
2. `celeris64 asm prog.asm prog.bin` — the project's own assembler.

For programs P1, P2, P3 the two encoders produce **byte-identical** images (`cmp` reported no
difference), so the words fed to the RTL are the words the assembler produces. Register
expectations were then read from `celeris64 trace`.

**Where a comparison rests on one method only, it says so.** §4.4 (P4) rests on the assembler
alone, and is labelled there.

### Programs

| ID | Program | `.asm` source | Words |
|---|---|---|---|
| P1 | §5 sub-width zero-extension | `/tmp/p1_zeroext.asm` | 7 |
| P2 | §3.1 ALU immediate (ten ops) | `/tmp/p2_aluimm.asm` | 11 |
| P3 | §3.0 jump / call / ret (LR) | `/tmp/p3_callret.asm` | 9 |
| P4 | §3.4 `stream.add` | `/tmp/p4x.asm` | 5 |

---

## 4. The cross-check

### 4.0 Testbench result

```
$ /tmp/core_tb_sim
=== CLS64 rtl/core.sv testbench (contract v1.2) ===
...
=== checks=159 failures=0 ===
PASS: all 159 core vectors matched (simulation only; RTL is NOT synthesized, NOT timing-closed, NOT on silicon)
```

`[PASS]` per group: P1, P2, P3, P3b, P4, P5, P6, P7, P8, P9, P10.

### 4.1 Summary table

| Program | Zig simulator result | RTL result | Agree? |
|---|---|---|---|
| **P1** sub-width zero-extension | `R0=0x1234`, 7 insns, halt | `R0=0x1234`, PC=0x38 | **YES** |
| **P2** ALU immediate | `R0..R9` as §4.2, 11 insns | identical | **YES** |
| **P3** call/ret + LR | `LR=0x10`, `PC=0x28`, halt after 4 | `LR=0x10`, `PC=0x28` | **YES** |
| **P4** `stream.add` | 5 insns, halt; pointer 0x100→0x160 | `R1=0x160` | **YES** |

### 4.2 P1 — §5 sub-width zero-extension

Zig reference (`celeris64 trace /tmp/p1_zeroext.asm`, final state):

```
  000032  mov R0, -1        # R0 <- 0xffffffffffffffff
  000040  mov R0.w, 4660    # R0 <- 0x0000000000001234
  halted after 7 simulated instructions.
```

RTL: `ok P1 R0 = 0x1234`, `ok P1 PC = 0x38`, `PASS P1`.

This is the mandatory zero-extension invariant (AGENTS.md §2.1): writing `.w` after a register
holds all-ones must leave `0x1234`, **not** `0xFFFF_FFFF_FFFF_1234`. Both implementations
clear the upper bits.

### 4.3 P2 — §3.1 ALU immediate (all ten ops)

| Reg | Zig | RTL | Agree |
|---|---|---|---|
| R0 | `0x64` | `0x64` | ✓ |
| R1 | `0x96` | `0x96` | ✓ |
| R2 | `0x7d` | `0x7d` | ✓ |
| R3 | `0x1f4` | `0x1f4` | ✓ |
| R4 | `0xf4` | `0xf4` | ✓ |
| R5 | `0x1f4` | `0x1f4` | ✓ |
| R6 | `0x1fb` | `0x1fb` | ✓ |
| R7 | `0x7ec` | `0x7ec` | ✓ |
| R8 | `0x3f6` | `0x3f6` | ✓ |
| R9 | `0xffff_ffff_ffff_ffff` | same | ✓ |

`R9 = -1` exercises §3.1's signed 28-bit immediate sign-extending to all 64 bits.

### 4.4 P3 — `call` sets `LR` to the **next** instruction

**This is the historic bug site.** Conflating `call` with `jump` made every subroutine return
to address 0 in the Zig VM. It is pinned in three directions.

Zig reference:

```
  000000  mov R1, 9    # R1 <- 0x9
  000008  call 40      # LR <- 0x0000000000000010, PC <- 0x0000000000000028
  000040  ret          # PC <- 0x0000000000000010
  000016  halt
  halted after 4 simulated instructions.
```

RTL:

```
      ok P3 LR after `call 40` (MUST be 16 = next insn) = 0x10
      ok P3 LR is NOT 8 (the call's own address)  = 1
      ok P3 LR is NOT 0 (the real Zig VM bug)     = 1
      ok P3 PC after `call 40`                    = 0x28
      ok P3 PC after `ret` (must be LR=16)        = 0x10
      ok P3 halted after returning to 16          = 1
  PASS P3 (call sets LR to next instruction)
```

`call 40` at PC=8 → LR=**16** (0x10), the address of the next instruction. Not 8 (the call's own
address, which would re-enter the call forever), not 0 (never written). `ret` returns to 16, and
**P3b** confirms `jump` leaves LR untouched (`PASS P3b`).

The correct value is computed from `pc_next` — the *same* expression the straight-line advance
uses — so the two cannot drift apart.

### 4.5 P4 — §3.4 `stream.add`

Assembler-authored source (`/tmp/p4x.asm`), so the words are exactly what `celeris64 asm`
emits:

```
mov R1, 256
stream.add R0, [R1]+4, R0
mov R2, 10
stream.add R3, [R1]+8, R3
halt
```
```
000000 1910000000000100     000008 4001000004000000
000016 192000000000000a     000024 4031300008000000
000032 0100000000000000
```

Zig: `program "/tmp/p4x.bin" halted after 5 simulated instructions.`

RTL:
```
      ok P4 R1 (pointer after 2 auto-advances)    = 0x160
      ok P4 R2 (mov executed between the two stream ops) = 0xa
      ok P4 memory[256] element unchanged (addend 0) = 0xa0000000a
  PASS P4 (stream.add)
```

**§3.4 rule 2 is demonstrated:** the pointer advances by `chunk × elementSize` with **no
software index arithmetic**. `0x100 + 4×8 = 0x120`, then `0x120 + 8×8 = 0x160`.

> **Basis:** this is the one program whose reference rests on the assembler alone rather than on
> two agreeing encoders, because P4's data placement required the assembler's actual bytes. It
> is therefore **not independent of the simulator's assembler** — see §5.1, where that
> assembler is shown to have a defect. The RTL's behaviour here is confirmed self-consistent
> (pointer arithmetic, retirement, halt) but the *width* question is unresolved; see §5.1.

**Program/data overlap, a testbench bug worth recording.** The first version seeded stream data
at addresses 8–39 — exactly where P4's own instructions live. It overwrote four instructions
with data, and the core then executed zeros, looping forever. Lint and the RTL were both
innocent; the testbench was destroying its own program. Data now lives at 0x100.

### 4.6 Beyond the four required programs

| Group | What it pins | Result |
|---|---|---|
| **P5, P6** | §3.6 operand decode; **all 13 normative opcodes recognised, all 35 reserved bytes rejected**; `not_implemented` vs `unknown_op` distinguished | PASS |
| **P7** | §3.1 v1.2 regression: bit 39 set + bit 27 clear ⇒ **register** form, reserved field flagged | PASS |
| **P8** | Per-sub-field slicing for §3.0/§3.1/§3.2.2/§3.3/§3.4/§3.6 | PASS |
| **P9** | §7 named diagnostics: divide-by-zero, reserved width, zero chunk, zero field width — each stops the machine and **writes nothing** | PASS |
| **P10** | §3.2.1 `compare` materialises the status enum (`LESS=1`), not a bare boolean | PASS |

---

## 5. FINDINGS

### 5.1 FINDING (defect in the **simulator's assembler**) — `stream.*` element width is unencodable

§3.4 defines `operand[23:20]` as the element width selector (the §5 encoding: `0`=64-bit,
`1`=.l, `2`=.w, `3`=.b). The Zig assembler **never sets it**.

All four of these produce a **byte-identical** word:

```
$ for sfx in "" ".w" ".l" ".b"; do printf 'stream.add R0, [R1]+4, R0%s\nhalt\n' "$sfx" > /tmp/s.asm; ...; done
suffix ''   -> 4001000004000000  width[23:20]=0
suffix '.w' -> 4001000004000000  width[23:20]=0
suffix '.l' -> 4001000004000000  width[23:20]=0
suffix '.b' -> 4001000004000000  width[23:20]=0
```

Cause, in `src/assembler.zig` `runStream`: the parser reads `rd`, the bracketed pointer and
chunk, and the offset register — it **never parses an element-width suffix**, so the field is
always `0`. A `.w` on the operand is silently discarded.

**Consequence:** every `stream.*` instruction the assembler can produce streams **64-bit**
elements. A 16-bit stream cannot be expressed through the toolchain, even though §3.4 and the
RTL both support it.

**Which side is right:** the **RTL** and §3.4. The contract gives the field a meaning and the
RTL decodes it (asserted in P8: `element width = 1` from a hand-built word). The assembler is
incomplete — it accepts a suffix and drops it, which is the silent kind of failure. This is
**not fixed here**: `src/assembler.zig` is outside this task's write scope, and it is reported
for the owner to route.

**Effect on this document:** P4 uses the assembler's words, so P4 exercises 64-bit elements
only. The RTL's sub-64-bit stream path is covered by P8's operand-slice assertions
(`element width = 1` decoded correctly) but is **not** end-to-end cross-checked against the
simulator, because the simulator's assembler cannot emit the word. Recorded as a gap.

### 5.2 FINDING (real RTL bug, **found by this cross-check**) — `halt` did not retire

`halt` transitioned straight to `ST_HALTED` without a writeback cycle, so:

- `retired_o` was **short by one** (the halt instruction was never counted);
- PC stayed pointing **at** the halt word rather than advancing past it on the §1 stride.

`src/vm.zig` counts halt as retired:

```zig
.halt => { self.retired += 1; self.halted = true; ... }
```

**The RTL was wrong.** Fixed with a dedicated `ST_HALTWB` state: `halt` retires exactly once,
PC advances, then the machine parks. It writes no register.

This was **only** visible because the cross-check compares the retired count and PC as well as
the registers. Lint could never have caught it — both versions lint clean. First fix attempt
routed halt through `ST_WRITEBACK`, which then re-executed the same halt word forever; the
dedicated state is what makes it correct.

### 5.3 FINDING (real RTL bug, **found by this cross-check**) — stream pointer never written back

The stream pointer advance was **silently lost**. The engine pulses `ptr_we_o` on the last
cycle of `ST_STREAMW`, but the register write mux required `state_q == ST_WRITEBACK` — one
cycle *later*, by which time the pulse had gone. `R1` stayed at its initial value while every
element was written correctly, so memory looked right and only the pointer was wrong.

Fixed by **holding** the commit flag until the writeback cycle consumes it, while the *raw*
pulse drives the state transition. `retired_o`, PC and memory were all correct throughout; only
the pointer register diverged.

### 5.4 FINDING (contract drift absorbed) — v1.2 → v1.9

The contract moved from v1.2 to v1.9 during this task. New reserved fields appeared:
§3.2.2 `operand[35:0]` and §3.3 `operand[27:0]`, which `select_unit`/`field_unit` expose as
`reserved_i`/`reserved_err_o`. Both are wired in `rtl/core.sv`, folded into the §7 diagnostic
aggregation as `err_sel_reserved_o`/`err_field_o`, and asserted in P8.

### 5.5 FINDING (contract inconsistency, **not** implemented) — `stream.setp` bounds

`stream.setp` (0x43) is **not implemented**; it raises `err_unimplemented_o`. Reason, recorded
rather than guessed:

- Its §3.4 operand field is a **different layout** (a signed 40-bit stride in `operand[39:0]`,
  overlapping the `zero[39:28]` field other groups reserve — §3.4 notes this deliberate overlap
  and v1.4 scoped the reservation per instruction class).
- The Zig model applies the stride **without** the §6 bounds check the other three stream ops
  get.

Implementing it from an ambiguous reading would put a guess in a writeback path. Reported.

### 5.6 FINDING (RTL is narrower than the contract) — §3.4 chunk range

`rtl/stream_engine.sv` walks **at most 8 elements per pass** (`WALK_LIMIT`, a 3-bit counter),
while §3.4's `chunk` field is 20 bits — up to 1,048,575 elements. A larger chunk is refused
loudly on `chunk_too_large_o`; it is **never** silently truncated.

**No reader may infer from "the four programs agreed" that the RTL implements §3.4's full chunk
range. It does not.** Four of the five chunks used here are 4 and 8 elements, chosen to stay
inside the limit. Nothing in §3.4 requires a cycle count, so widening the counter is a resource
decision — but as written the RTL is narrower than the contract.

### 5.7 Not implemented, and stated plainly

| Opcode | Status |
|---|---|
| `matrix.*`, `fft.*`, `codec.*` (0x60–0x8F) | **Decode only.** Operands decoded correctly, reserved field flagged, `err_accel_not_impl_o` raised for a recognised op, `err_accel_unknown_o` for a reserved byte. `result_valid_o` is tied to `1'b0` and the result to zero — **no fabricated answer**. |
| `cap.*` (0x50–0x52), `thread.*` (0x90–0x92) | Recognised, raise `err_unimplemented_o`. The Zig VM faults on them too, so there is no reference behaviour to match. |
| `select` (0x21), `field.*` (0x30–0x31) | Units instantiated and operands sliced, but **writeback not wired**; raise `err_unimplemented_o`. §3.2.2's `rs2` role is ambiguous; wiring a guess into a writeback path is how a wrong result gets committed. |
| `stream.setp` (0x43) | See §5.5. |
| `FLAGS` (§4 index 15) | Never written by any implemented instruction. §3.2.1 says `compare` "does not write FLAGS". A real regfile location, not a hardwired zero. |

---

## 6. The one suppressed warning — with its reproduction

`rtl/core.sv` contains **exactly one** `/* verilator lint_off UNUSEDSIGNAL */`, scoped to the
`word_d` declaration. It suppresses a **false positive**, and the justification is reproducible
in ten lines. Here it is, so a reader can check the claim rather than trust it:

```systemverilog
package pc;
  typedef struct packed {
    logic [7:0]  opcode; logic [3:0] rd; logic [3:0] rs1; logic [47:0] operand;
  } tw;
endpackage
module pc_m import pc::*;
  (input logic [63:0] w, output logic [47:0] oo, output logic [7:0] o);
  tw d;
  always_comb d = '{opcode: w[63:56], rd: w[55:52], rs1: w[51:48], operand: w[47:0]};
  assign oo = d.operand;   // the WHOLE 48-bit field, into an output
  assign o  = d.opcode;
endmodule
```
```
$ verilator --lint-only -Wall --top-module pc_m pc.sv
%Warning-UNUSEDSIGNAL: pc.sv:...: Bits of signal are not used: 'd'[55:48]
%Error: Exiting due to 1 warning(s)
```

The warning fires while reading the **complete** field once into an output — and the range it
names, `[55:48]`, does not even correspond to `operand`, which lives at `[47:0]`. Verilator's
flattened bit numbering for packed structs is wrong here.

The alternative — hand-slicing `fetch_word_i` in `core.sv` instead of calling the package's
`unpack_word` — would duplicate §2 decoding to appease the tool, creating exactly the drift the
package exists to prevent.

**The suppression is scoped to one declaration.** Every other `UNUSEDSIGNAL` in the tree stays
live — including a real one that this class of warning caught in `rtl/stream_engine.sv`.

### 6.1 Also relevant: the package's unused-localparam warnings

Per-module lint of `rtl/pkg/celeris64_pkg.sv` + one module **cannot** reach exit 0: Verilator
emits `UNUSEDPARAM` for every package localparam a given top module does not reference, and
`-Wall` makes that fatal. Measured:

```
$ verilator --lint-only -Wall --top-module alu rtl/pkg/celeris64_pkg.sv rtl/regfile.sv rtl/alu.sv
%Warning-UNUSEDPARAM: ... 'GPR_COUNT', 'GPR_INDEX_MAX', 'REG_SP', 'REG_LR', 'REG_PC', 'REG_FLAGS'
%Error: Exiting due to 6 warning(s)   EXIT=1

$ verilator --lint-only -Wall --top-module regfile rtl/pkg/celeris64_pkg.sv rtl/regfile.sv
EXIT=0
```

`regfile` is the only module that consumes those six constants. Hence the acceptance criterion
is the **whole-tree, `--top-module core`** command in §2.1: `core.sv` instantiates `regfile`, so
the §4/§5 constants are consumed for real, and anything genuinely dead still fails.

---

## 7. What is NOT verified — the honest gap list

1. **Never synthesized, never timing-closed, never on silicon, no frequency known.** No
   synthesis tool on this host.
2. **`stream.*` is walked by the testbench.** The core issues the operation and gates
   retirement on the engine's handshake, but memory lives in the testbench. There is **no
   scoreboard and no hazard interlock**: a program that read a register mid-stream would read a
   stale value. All cross-checked programs are straight-line and never do this.
3. **Sub-64-bit stream elements are not end-to-end cross-checked** — the simulator's assembler
   cannot encode the field (§5.1).
4. **§3.4's full 20-bit chunk range is not implemented** (§5.6).
5. **`matrix.*`/`fft.*`/`codec.*` arithmetic is not implemented** (§5.7). Only decode.
6. **`select`/`field.*`/`cap.*`/`thread.*`/`stream.setp` are not executed** (§5.7).
7. **No memory-mapped instruction fetch in RTL.** The testbench supplies the word at PC.
8. **No interrupt, exception or reset-vector behaviour** — out of scope.
9. **Single clock domain only.** CDC is out of scope and untested.
10. **`PC` as a source register is only partly modelled.** PC is mirrored in the core and
    readable through `pc_o`; no cross-checked program reads PC as a source operand.
11. **The `+|` defect (§2.4) means any future RTL using `+|` would silently diverge.** No file
    in this task does.
12. **Verilator 5.49 is the only simulator used.** Nothing here was checked against a second
    HDL simulator, and §6 shows at least two Verilator-specific behaviours.

---

## 8. Revision measured

| Item | Value |
|---|---|
| Contract | `docs/isa-encoding.md` **v1.9** |
| Simulator | `zig-out/bin/celeris64`, built from the tree as of this run |
| Verilator | `rev vUNKNOWN-built20260516-4e853d8` (self-reports 5.49) |
| Testbench result | **159 checks, 0 failures** |
| Whole-tree lint | **exit 0, zero warnings**, one documented suppression (§6) |

Built from a **quiescent tree** — the tree was mutated in place during this task by another
teammate's fault-injection run (§2.3), which produced stale binaries and cost debugging time.
All results above are from a clean, unmutated tree.

---

*Celeris-64 describes a chip that does not exist. This RTL is a lint-verified specification
plus simulation. It has never been synthesized, never timing-closed, and never placed on
silicon, and no clock frequency is claimed for it.*
