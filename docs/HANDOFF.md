# Session handoff — 2026-11-09 (second session)

Supersedes the earlier handoff of the same date. Everything below was verified by
running something; claims that were not observed are marked as such.

---

## 1. Repository state

```
HEAD         66aee85  docs(status): F32 closed, F35 recorded, and one of our own drafts retracted
remote       origin/main, IN SYNC as of 66aee85 (pushed)
working tree CLEAN
```

Three commits landed this session, in this order:

| Commit | What |
|---|---|
| `07c0017` | `feat(asm)`: labels — branch/jump targets can be named (v1.18) |
| `025af04` | `fix(crossarch)`: CLS64's "scalar" row is a real loop now (closes **F32**) |
| `66aee85` | `docs(status)`: F32 closed, F35 recorded, one draft of ours retracted |

**The previous handoff's blocking item is done.** The dirty tree it described is
committed, the 3 failing label tests pass, and the labels work is byte-verified.

### Gates, all run on a cold cache at `66aee85`

```sh
rm -rf .zig-cache && ~/.local/zig/zig build test --summary all
  -> Build Summary: 49/49 steps succeeded; 570/570 tests passed   exit 0

~/.local/zig/zig build crossarch   -> 8 rows, no !! warnings
~/.local/zig/zig build audit       -> 9/9 enforcement points, all 9 rejected when set
~/.local/zig/zig build live-check  -> all 232 recorded facts still reproduce
fuzzer (inside build test)         -> checked=11839 identical=11839, 0 mismatches
```

---

## 2. What was fixed, and two numbers that were wrong

### Labels (v1.18) — the blocking item

Three passes in `Assembler.assembleSource`: collect label → instruction index and
reject duplicates, assemble while recording unresolved references in `pending`,
then patch once every address is known. Labels resolve to `index * 8`; `branch`
gets a PC-relative signed 28-bit delta **from the branch instruction itself**
(§3.0.1), `jump`/`call` an absolute 48-bit address. `splitLabel` is shared by
passes 1 and 2 so they cannot drift.

The test bug was exactly as the old handoff described. But **two inherited numbers
were wrong**, and both are worth knowing because each could have been "fixed" by
bending the product instead of the test:

1. **`-16` → `-8`.** The failing test asserted `-16`. The encoder computes
   `target_addr - branch_addr`, so a branch at address 8 targeting address 0 gives
   `-8`. Setting it back to `-16` fails, so the assertion is load-bearing.
2. **The by-hand numeric program did not exist and the first reconstruction
   faulted.** The old handoff claimed the label program assembles to "the same 12
   words as the numeric-offset equivalent" but never printed that program. The
   first attempt to write it used branch delta `80` and `jump 24`, which sends the
   exit past the 96-byte image and the back-edge to the setup word; the run dies
   with *"the simulator refused an access at address 48"*. Correct values are a
   branch delta of `48` and an absolute jump of `32`. Against those the images are
   **byte-identical** (`cmp` clean) and both halt after 63 simulated instructions —
   so the handoff's claim holds.

   That mistake was made by an agent that had just read the encoding rules. It is
   the argument for labels existing, and it is recorded in `docs/STATUS.md` F35.

### F32 is closed — and CLS64 now loses that comparison

The CLS64 "scalar" row was the fused `stream.add` (0x40) eight times at
`chunk = 1`, not a loop. v1.17's `load`/`store`/`branch` removed the reason that
could not be fixed, so it is now a real 13-word per-element loop:

```
CLS64 scalar   11 -> 68 retired     88 -> 544 bytes     (now WORST of four)
RISC-V scalar  55        (unchanged)
AArch64 scalar 61        (unchanged)
x86-64 scalar  60        (unchanged)
CLS64 batch     4        (unchanged, 32 bytes)  <- still CLS64's real result
```

This is the honest result, not a regression: the old 11 measured a fused sequence
under a scalar label. `docs/comparison.md` §7 and `docs/fidelity.md` §3.4 were
written against the old 4/11 pair — **they have not been updated yet** (§5 below).

---

## 3. What remains

Unchanged in priority from the old handoff, minus items 1 and 2:

1. **Wire the accelerators** — the largest remaining core gap, and the last thing
   before the example suite. `matrix.zig`, `fft.zig` and `codec.zig` are imported
   by **no other file**; `0x60`–`0x8F` decodes to an `Accelerator` payload that
   `vm.zig`'s `execute` sends to its `else` arm, which faults with "not wired into
   this build yet". The decoder side is already complete and normative (§3.6
   amendment 1.1: `rs2[47:44] | rs3[43:40] | reserved[39:32] | count[31:0]`), and
   `decoder.acceleratorGroup()` already maps `0x60-0x6F` → matrix, `0x70-0x7F` →
   fft, else codec. So the work is a VM-side dispatch, not a contract change.
2. **The example suite, analyzers, instruction counter** — the bulk of the goal,
   genuinely unblocked only after 1.
3. **`cap.*`** stays decode-only. §3.5 v1.12 explains why: the register pair has
   no `length` bit position, so a capability cannot be reconstructed. Needs a §6
   redesign, not a bug fix. Do not "fix" it by inventing a field layout.

---

## 4. Environment facts that cost time

- Zig **0.17.1** at `~/.local/zig/zig`. No system `zig`.
- Verilator **5.49** at `~/.local/verilator/bin/verilator`.
- LLVM 20 at `/usr/lib/llvm-20/bin/` — use `llvm-mc -triple=<isa> -show-encoding`
  as an assembler oracle. **There is no LLVM backend for CLS64**, so CLS64's own
  encodings can only be checked against this repo's decoder. That is
  self-consistency, not independent verification; say so when quoting them.
- **Test counts are a measurement, not a calculation.** `zig build test` on a warm
  cache reports a stale count. Always `rm -rf .zig-cache` before quoting a number.
- `zig build test --summary all` may print a `failed command:` line from the
  *build runner* while still reporting `49/49 steps succeeded`. Trust the summary
  line and the exit code, not that line.
- Verilator PCH bug: a `--binary` build floods ~8 GB because GCC gets
  `Vstream_tb__pch.h.fast` as a bare positional argument. Fix with
  `-MAKEFLAGS "VK_PCH_I_FAST= VK_PCH_I_SLOW="`. Never redirect a Verilator log.
- Two encoders exist (`assembler.zig` `Instruction.word()` and `decoder.zig`
  `encode()`); the fuzzer checks they agree. Keep it that way.

### Two traps, both confirmed this session

- **`assembleSource` moves its arena into the returned `Program`.** `Program.arena`
  is a *value copy* sharing one node list, so `prog.deinit()` **and**
  `assembler.deinit()` frees the same nodes twice — a double free on the **success**
  path that aborts. On the failure path nothing was handed over, so the assembler
  must free.
- **Returning `prog.words` as a slice is unsafe on its own.** It is the live
  `ArrayList` buffer, and Zig 0.17's `ArenaAllocator` can *move* that allocation
  when it grows the same node; a stale slice then reads `0xAAAA…` poison. "The
  words are arena-owned" does not make a slice safe. Test helpers return `Program`.

---

## 5. Known-stale documentation (do this before quoting the numbers)

- `docs/comparison.md` §7 and `docs/fidelity.md` §3.4 still describe the CLS64
  scalar row as 11 retired / the 4-vs-11 pair. F32's closure changes that to 68.
  STATUS.md has the new numbers; those two files do not.
- `README.md` may quote the old crossarch table. It was not re-read this session.

---

## 6. Honesty constraints this repository enforces

Load-bearing. Do not relax them.

- Every benchmark line contains the word **"simulated"**.
- **No clock frequency, timing figure, area figure or silicon performance claim
  appears anywhere.** `docs/fidelity.md` calls such a claim a bug.
  `src/isaharness.zig` has no field for a timing quantity and a test — "the harness
  reports no timing quantity of any kind" — fails if one is added.
- Models are labelled as models; RTL is synthesised but never timing-closed and
  never on silicon.
- A finding that turns out to be wrong is **retracted in place**, not deleted.
  This session retracted its own draft attribution in F35 for exactly this reason.
- Mutation tests run in **throwaway copies**, never on the shared tree.
- **A comparison must not favour the subject.** When the honest fix makes CLS64
  look worse, report the worse number. That happened here (11 → 68) and is the
  correct outcome.

---

## 7. Goal in flight

```
Finish the CLS64 core ISA (no extensions/accelerators), then build a
non-cherry-picked cross-architecture example suite: multiple examples including
large ones, written idiomatically per ISA (CLS64, RISC-V, AArch64, x86-64), with
Zig analyzers producing findings, and an instruction counter that simulates
efficiency per assembly program. Every example must be verified equivalent
across all four ISAs and must not favour CLS64.
```

The old handoff recorded goal id `goal-bcd934e2-c9da-4d29-a68d-3d314631667c`.
**No goal is active in this session** — `get_goal` returned null, so the goal was
not carried across. If the objective above is to continue, it must be re-created.

Note the tension worth resolving explicitly: the goal says "no
extensions/accelerators", while the old handoff's item 3 lists wiring the
accelerators as the next core gap. These are compatible if the accelerators are
treated as part of the core encoding contract (§3.6) rather than as optional
extensions — but that reading should be confirmed, not assumed.
