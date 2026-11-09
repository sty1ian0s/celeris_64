# Session handoff — 2026-11-09

Written because the assistant session began emitting malformed output (repeated
empty parameter blocks) when attempting multi-step work. Everything below is
verified state on disk, not recollection.

---

## 1. Repository state

```
HEAD         4d5dd36  feat(isa): branch, load and store — the ISA could not express a loop (v1.17)
remote       origin/main, in sync as of 4d5dd36
working tree DIRTY — two files modified, NOT committed:

  M src/assembler.zig      labels: two-pass resolution (implemented, working)
  M src/diagnostics.zig    three new label diagnostics

  `zig build` -> exit 0  (the dirty tree COMPILES)
```

### The uncommitted work is real and almost done

**Labels are implemented and work.** Verified by hand before the session broke:

```sh
# This assembles, and produces bytes IDENTICAL to the hand-computed numeric version:
mov R1, 4096
mov R2, 0
mov R3, 8
mov R4, 0
loop:
compare R4, R3 -> R5
branch R5, [EQUAL], done
load R6, [R1+0]
add R2, R2, R6
add R1, R1, 8
add R4, R4, 1
jump loop
done:
halt
```

It assembles to the same 12 words as the numeric-offset equivalent, and
`run-bin` halts after 63 instructions — matching the numeric version exactly.

**Why labels were needed:** branch/jump targets were numeric byte offsets only
(`branch R5, [EQUAL], 48`). Writing "quite a few examples, maybe big ones" by
hand with magic numbers is not viable.

Design: three passes in `Assembler.assembleSource` —
1. collect label -> instruction index (and reject duplicates),
2. assemble, recording unresolved references in `self.pending`,
3. patch every reference, now that all addresses are known.

Labels resolve to `index * 8`; `branch` gets a PC-relative signed 28-bit delta,
`jump`/`call` an absolute 48-bit address. `splitLabel` is shared by passes 1 and
2 so the two cannot drift about which lines emit an instruction.

### The one thing blocking a commit

**3 of the 8 new label tests fail — and it is a TEST bug, not a product bug.**

`assembleOk()` (an existing helper at the bottom of `src/assembler.zig`) asserts
`prog.words.len == 1`. Three of my new tests feed it multi-instruction programs,
so they fail with `expected 1, found 4` / `found 2`.

**Fix:** either add a multi-instruction helper (`assembleProgram`) returning the
whole `[]u64`, or write those three tests against `words[0]`/`words[k]` directly.
The affected tests are:

- `labels: a forward reference resolves to the right address` (4 instructions)
- `labels: a backward branch encodes a negative PC-relative offset` (2)
- `labels: a label on the same line as an instruction still works` (2)

The other five pass, including the two that matter most (duplicate label
rejected; undefined label rejected rather than patched to 0).

**Also note a trap already hit once:** `assembleSource` MOVES its arena into the
returned `Program` on success. Calling both `prog.deinit()` and
`assembler.deinit()` is a double free and aborts. The comment added at the
"line that is only a label" test records this. This is the same trap
`src/main.zig` documents.

### After fixing, re-run

```sh
~/.local/zig/zig test src/assembler.zig --test-filter "labels"
rm -rf .zig-cache && ~/.local/zig/zig build test --summary all   # expect 49/49 steps
```

Then commit `src/assembler.zig` + `src/diagnostics.zig` and push.

---

## 2. The goal in flight

```
Finish the CLS64 core ISA (no extensions/accelerators), then build a
non-cherry-picked cross-architecture example suite: multiple examples including
large ones, written idiomatically per ISA (CLS64, RISC-V, AArch64, x86-64), with
Zig analyzers producing findings, and an instruction counter that simulates
efficiency per assembly program. Every example must be verified equivalent
across all four ISAs and must not favour CLS64.
```

Goal id `goal-bcd934e2-c9da-4d29-a68d-3d314631667c`, left **active**. Round
counter reached 6/40 before the session broke.

---

## 3. What is already done toward that goal

### The ISA can now express a loop (v1.17, committed)

Before v1.17 every control transfer was **unconditional** (`jump`, `call`,
`ret`), so CLS64 could not express a loop *at all*, and the only memory-touching
opcodes were the fused `stream.*` engine and decode-only `cap.*`, so a scalar
load did not exist either. Added:

| Opcode | Mnemonic | Form |
|---|---|---|
| `0x05` | `branch` | `branch rs1, [MATCH], offset` — tests the status enum `compare` produces; offset is relative to the branch itself |
| `0x1A` | `load` | `load rd, [rs1+off]` |
| `0x1B` | `store` | `store rs2, [rs1+off]` |

Four defects were found while implementing them; three by the round-trip fuzzer
within one run. All are recorded in `docs/STATUS.md` as **F34** and in
`docs/isa-encoding.md` v1.17. Details worth knowing:

- The assembler's `.control` encoder arm handled only `jump`/`call`, so `branch`
  assembled to operand 0 — **every loop ran forever**.
- `branch`'s width nibble was first specified as "checked but not used". The
  fuzzer disproved it in one run: a validated-but-dropped field loses bits
  silently. It is now reserved-and-rejected.
- The decoder accepted a branch offset that is not a multiple of 8, which the
  assembler refused (the F24/F27 two-layer shape).
- `load`/`store` accepted a surplus third operand and discarded it silently.

### Cross-architecture execution already works (committed)

`zig build crossarch` executes real machine code for CLS64, RISC-V RV64I,
AArch64 and x86-64 in **one measurement loop**, reporting retired instructions
and encoded bytes. Current output:

```
  Celeris-64 CLS64 batch            4          32        8.00
  RISC-V RV64I     batch           54         216        4.00
  AArch64 A64      batch           60         240        4.00
  x86-64           batch           52         167        3.21
  Celeris-64 CLS64 scalar          11          88        8.00
  RISC-V RV64I     scalar          55         220        4.00
  AArch64 A64      scalar          61         244        4.00
  x86-64           scalar          60         207        3.45
```

**No cycles, no clock, no speedup — by design.** `src/isaharness.zig` has no
field for a timing quantity and a test fails if one is added. The user asked for
"the same clock"; that was declined because assigning a cycle cost means
inventing a microarchitecture, and CLS64's number would come from the same
invention. `docs/comparison.md` §8 records this.

Files: `src/isaharness.zig`, `src/isa_riscv.zig`, `src/isa_aarch64.zig`,
`src/isa_x86_64.zig`, `src/crossarch.zig`, `tools/crossarch-report.zig`.

The three new decoders are verified against **`llvm-mc` as an oracle** —
encodings pasted verbatim from LLVM's assembler. That caught three real bugs
that every self-consistency test passed (sign-extension never shifted back;
`0xC7` misgrouped with the ALU opcodes; SIB reading a `disp32` that was not
there). See **F33** in `docs/STATUS.md`.

---

## 4. What remains

Ordered by what unblocks the most:

1. **Finish and commit the labels work** (section 1). Small, and without labels
   the example suite is unreadable regardless of anything else.
2. **Rewrite CLS64's rows in `crossarch.zig` to use the new `load`/`store`.**
   Its "scalar" row is currently `stream.add` at `chunk = 1`, NOT an unfused
   loop — the F32 finding. The other three ISAs' scalar rows ARE real loops, so
   that row is not comparable. Now that `load`/`store` exist, this can finally
   be fixed honestly.
3. **Wire the accelerators.** `matrix.zig`, `fft.zig`, `codec.zig` are imported
   by **no other file** — `0x60`–`0x8F` decodes to an opaque payload and
   executes nothing. This is the largest remaining core gap.
4. **The example suite, analyzers, and instruction counter** — the bulk of the
   goal, and genuinely unblocked only after 1–3.
5. **`cap.*`** remains decode-only. §3.5 v1.12 explains why: the register pair
   has no `length` bit position, so a capability cannot be reconstructed. This
   needs a §6 redesign, not a bug fix.

---

## 5. Environment facts that cost time to rediscover

- Zig **0.17.1** at `~/.local/zig/zig`. There is no system `zig`.
- Verilator **5.49** at `~/.local/verilator/bin/verilator`.
- LLVM 20 at `/usr/lib/llvm-20/bin/` — `llvm-mc`, `llc`, `llvm-objdump`. **Use
  `llvm-mc -triple=<isa> -show-encoding` as the assembler oracle.**
- **Verilator PCH bug:** a `--binary` build floods ~8 GB of diagnostics because
  GCC is handed `Vstream_tb__pch.h.fast` as a bare positional argument. Fix with
  `-MAKEFLAGS "VK_PCH_I_FAST= VK_PCH_I_SLOW="`. `--lint-only` is unaffected.
  Never redirect a Verilator build log to a file.
- **Test counts are a measurement, not a calculation.** `zig build test` on a
  warm cache reports a *stale* count (it showed 395 where the truth was 556).
  Always `rm -rf .zig-cache` before quoting a number.
- Two encoders exist (`assembler.zig` `Instruction.word()` and `decoder.zig`
  `encode()`); the fuzzer checks they agree. Keep it that way.
- `assembleSource` moves its arena into `Program` — see the double-free trap in
  section 1.

---

## 6. Honesty constraints this repository enforces

These are load-bearing and predate this session. Do not relax them:

- Every benchmark line contains the word **"simulated"**.
- **No clock frequency, timing figure, area figure or silicon performance claim
  appears anywhere.** `docs/fidelity.md` calls such a claim a bug.
- Models are labelled as models; RTL is synthesised but never timing-closed and
  never on silicon.
- A finding that turns out to be wrong is **retracted in place**, not deleted.
  F30 was retracted and F29 re-attributed this way (see `docs/isa-encoding.md`
  v1.16).
- Mutation tests run in **throwaway copies**, never on the shared tree.
