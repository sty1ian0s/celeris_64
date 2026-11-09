# Session handoff — 2026-11-09 (second session)

Supersedes the earlier handoff of the same date. Everything below was verified by
running something; claims that were not observed are marked as such.

---

## 1. Repository state

```
HEAD         efa86bf  docs(status): F36 closed by Amendment 1.18; F38 and F39 recorded
remote       origin/main, IN SYNC as of efa86bf (pushed)
working tree CLEAN (at efa86bf)
```

Fifteen commits landed this session, in this order:

| Commit | What |
|---|---|
| `07c0017` | `feat(asm)`: labels — branch/jump targets can be named (v1.18) |
| `025af04` | `fix(crossarch)`: CLS64's "scalar" row is a real loop now (closes **F32**) |
| `66aee85` | `docs(status)`: F32 closed, F35 recorded, one draft of ours retracted |
| `875d65f` | `docs`: the published tables still said 11 — corrected to 68 |
| `0013c8f` | `docs`: two stale counts in README, and the handoff |
| `edc24b4` | `docs`: the accelerator row said "not assemblable" — it assembles |
| `0216f91` | `docs`: the accelerator round-trip is stronger than §6.2 claimed |
| `84d7046` | `docs(status)`: F36 — the §3.6 table names operands the word cannot carry |
| `4f18f7d` | `docs(status)`: F36 grows — count's source and unit are undefined |
| `9a9b193` | `feat(vm)`: the §3.6 accelerators now dispatch, and refuse per op |
| `e3f3c15` | `docs(status)`: F36 implemented and verified; F37 recorded |
| `af24bac` | `feat(isa)`: **Amendment 1.18** — 11 of 13 accelerators now execute |
| `a5be79d` | `fix(x86-64)`: **F38** — REX.R/REX.B selected the wrong register for r8–r15 |
| `c414be5` | `feat(examples)`: six-kernel cross-architecture suite + **F39** verdict fix |
| `efa86bf` | `docs(status)`: F36 closed, F38 and F39 recorded |

**The previous handoff's blocking item is done.** The dirty tree it described is
committed, the 3 failing label tests pass, and the labels work is byte-verified.

### Gates, all run on a cold cache at `efa86bf`

```sh
rm -rf .zig-cache && ~/.local/zig/zig build test --summary all
  -> Build Summary: 51/51 steps succeeded; 932/932 tests passed   exit 0

~/.local/zig/zig build examples    -> exit 0, 6 kernels x 4 ISAs, all equivalent
tools/accel_e2e.sh                 -> 10/10 checks passed (run by hand; see below)

~/.local/zig/zig build crossarch   -> 8 rows, no !! warnings
~/.local/zig/zig build audit       -> 9/9 enforcement points, all 9 rejected when set
~/.local/zig/zig build live-check  -> all 232 recorded facts still reproduce
~/.local/zig/zig build bench       -> output unchanged (still the chunk=1 program)
fuzzer (inside build test)         -> checked=11839 identical=11839, 0 mismatches
```

The test count moved 570 -> 932 across this session: the labels work, the
accelerator amendment (11 of 13 opcodes now execute), the six-kernel example suite,
and the x86-64 REX fix.

### The goal is re-created and ARMED

`goal-ac15e6ba-696a-442f-822a-9c4270e7f8bf`, max 40 rounds. The objective treats the
§3.6 accelerators as part of the **core** encoding contract rather than as optional
extensions, which resolves the tension the previous handoff flagged. `get_goal`
returns null after a session boundary, so it must be re-armed again next time.

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
under a scalar label. `docs/comparison.md` §7/§8 and `docs/fidelity.md` §3.4 have
now been corrected in place (commit `875d65f`), with the superseded text marked
rather than deleted. `benchmarks/bench.zig` was **not** changed: its scalar path is
still `chunk = 1` `stream.add`s, its F32 comment already says so, and its 11 is
still the literal output of `zig build bench`. Do not read that 11 as CLS64's
scalar-loop result — it is a fused sequence at `chunk = 1`.

---

## 3. What remains

1. **The accelerators — now blocked on a CONTRACT decision, not on code.** The VM
   half is done (`9a9b193`): all thirteen §3.6 opcodes dispatch to
   `refuseAccelerator`, reserved bytes read differently, and none executes. The
   refusal is deliberate and is recorded as **F36**.

   **An earlier draft of this handoff said the work was "read a register as an
   address, derive the count, call the model, write back". That was wrong, and the
   error is worth keeping visible**, because it is the natural assumption and the
   teammate who hit it was right to stop rather than implement it. What the contract
   actually lacks:

   | Missing rule | Affects |
   |---|---|
   | Where a matrix **dimension** comes from — no field carries one, and "dimension" appears in neither `docs/isa-encoding.md` nor the architecture spec | `0x60` `det`, `0x61` `invert`, `0x62` `mul` |
   | Where `transform`'s 4×4 matrix `m` comes from (`count` IS defined; `m` is not) | `0x63` |
   | Whether `rd` is an ADDRESS or a VALUE, so `out` cannot be located | `0x64` `identity` |
   | Where an **output buffer** comes from — `rd`, `rs1` and `count` are all spoken for | `0x80` `compress`, `0x81` `decompress` |
   | What `count = 0` means: §3.6:490 says "derive the count from the destination register" and never says what `rd` holds | all thirteen |
   | Which **unit** `count` uses: fft says "element count", codec is byte-oriented, and a complex element is 16 bytes — a 16× difference | `0x70`–`0x73`, `0x80`–`0x83` |

   So the next step is **not** a VM change. It is a §3.6 amendment stating, per
   operation, where each dimension and output buffer comes from and what
   `count = 0` means — the same kind of amendment Amendment 1.1 already made for the
   operand layout. Until then, refusing is correct: a guessed dimension produces a
   wrong determinant that the simulator would report confidently.

   Two things that will bite when the amendment lands: the models take
   `[]f64`/`[]u8`/`[]Complex` views into a flat `[]u8` whose base alignment is **not**
   guaranteed (`Vm.init` accepts any `[]u8`; tests use an align-1 allocator), so an
   alignment check must precede any `@alignCast` — a misaligned cast panics. And the
   VM must not allocate inside the execution loop (AGENTS.md §4.1).

   The RTL half is **already done and is not part of this work.** `rtl/accel.sv`
   decodes the range, flags a non-zero reserved field, and raises
   `err_accel_not_impl_o` / `err_accel_unknown_o` with `result_valid_o` tied low.
   That is the *correct* contract: §3.6 states these operations' behaviour "is a
   software model", and `rtl/CROSSCHECK.md` §4/§5.7 records the RTL as deliberately
   decode-only rather than fabricating a result. Do **not** build
   matrix/FFT/codec datapaths in SystemVerilog to "complete" this.

2. **F37 — a decision, not a patch.** `decoder.zig:469-485` accepts every byte in
   `0x60`–`0x8F` as `.accelerator` with no registry lookup, so reserved-ness is not
   established by the decoder even though §3.6 says such opcodes "decode as an
   accelerator instruction with an unrecognised operation". Either teach the decoder
   the lookup, or reword §3.6 to say the *simulator* refuses them. Both defensible;
   picking one silently is not. Not a live defect today, because the VM does the
   lookup correctly.
3. **The example suite, analyzers, instruction counter** — the bulk of the goal,
   genuinely unblocked only after 1.
4. **`cap.*`** stays decode-only. §3.5 v1.12 explains why: the register pair has
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
- **A stale CLI binary reads exactly like a real result.** `zig-out/bin/celeris64`
  is only rebuilt by `zig build`. Verifying a `src/` change by running the CLI
  without rebuilding reports the PREVIOUS code, and nothing in `git status` or a
  clean `git diff` reveals it. This produced a false reading this session that
  nearly went into `docs/STATUS.md` as evidence. Rebuild before believing a CLI
  observation you intend to rely on.
- `zig fmt` was **not** clean on the baseline `src/vm.zig`; a change that rewraps
  those lines is not gratuitous churn.

### Three traps, all confirmed this session

- **`assembleSource` moves its arena into the returned `Program`.** `Program.arena`
  is a *value copy* sharing one node list, so `prog.deinit()` **and**
  `assembler.deinit()` frees the same nodes twice — a double free on the **success**
  path that aborts. On the failure path nothing was handed over, so the assembler
  must free.
- **Returning `prog.words` as a slice is unsafe on its own.** It is the live
  `ArrayList` buffer, and Zig 0.17's `ArenaAllocator` can *move* that allocation
  when it grows the same node; a stale slice then reads `0xAAAA…` poison. "The
  words are arena-owned" does not make a slice safe. Test helpers return `Program`.
- **A `Diagnostic` outlives the function that builds it.** Storing a rendered
  string in a function-local buffer and returning it in `.detail` or `.mnemonic`
  gives an empty or corrupt field at render time, silently. This was attempted and
  caught by an existing test; the value must point at storage that outlives the
  call. Related: `main.zig:379` renders into a fixed `[1024]u8` and discards
  overflow with `catch {}`, so an over-long diagnostic is truncated mid-word with
  no indication. Keep a rendered fault under ~900 bytes.

---

## 5. Documentation state

All published tables were reconciled with the code this session. The method used
throughout: the superseded text is **marked in place**, not deleted, so a reader who
saw the old number can find out what happened to it.

- `docs/comparison.md` §8 table — CLS64 scalar `11/88` → `68/544`, with RISC-V's
  `4.00` now marked as the best density on that row.
- `docs/comparison.md` §7 — F32's finding kept as the historical record. §7.4 is
  retitled ("could not be written *at the time*"), §7.5's first bullet is marked
  superseded, and §7.6 records the closure and the rewritten may-say list.
- `docs/comparison.md` §3.1 — the `11` is labelled "as found, pre-v1.18".
- `docs/fidelity.md` — the F32 block's claim that this "cannot be corrected without
  an ISA change" is corrected; the `zig build bench` output block is left alone
  because it is still that command's literal output (re-ran it to confirm rather
  than assume).
- `docs/STATUS.md` — F32 closed, F35 (labels) recorded.
- `README.md` was checked: it does not quote the crossarch table, so it needed no
  change. It does say "11,592 checked" for the fuzzer, which is a different number
  (round-trip fuzz cases) and is **stale** — the current run is 11,839. Low stakes,
  but it is a stale number in a public file; fix it if you touch that section.

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
