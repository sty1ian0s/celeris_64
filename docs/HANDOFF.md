# Session handoff — 2026-11-09 (third session)

Supersedes the second-session handoff of the same date. Everything below was verified by
running something; claims that were not observed are marked as such.

---

## 1. Repository state

```
HEAD         b081f6f  docs(status): F41 — correct the shift semantics
remote       origin/main, IN SYNC as of b081f6f (pushed)
working tree CLEAN (at b081f6f)
```

Four commits landed this session, in this order:

| Commit | What |
|---|---|
| `7b4e5b5` | `feat(contract)`: **amendment 1.20** names the layer that refuses a reserved opcode (**closes F37**), + **F40** recorded, + analyzer breadth |
| `f3826f2` | `fix(rtl)`: the §3.6 recognition table matches the contract (**closes F40**) |
| `69dbdca` | `docs(status)`: **F41** — the eighth example kernel was attempted twice and landed neither time |
| `b081f6f` | `docs(status)`: F41 — correct the shift semantics |

### Gates, all run on a cold cache at `b081f6f`

```sh
rm -rf .zig-cache && ~/.local/zig/zig build test --summary all
  -> Build Summary: 53/53 steps succeeded; 1016/1016 tests passed   exit 0

bash tests/mulout_e2e.sh           -> 6/6 checks passed        exit 0
~/.local/zig/zig build examples    -> 64 "simulated" lines, 7 kernels x 4 ISAs
~/.local/zig/zig build audit       -> 9/9 enforcement points, all 9 rejected when set
~/.local/zig/zig build live-check  -> all 232 recorded facts still reproduce
~/.local/zig/zig build crossarch   -> 8 rows, no !! warnings
Verilator core_tb                  -> 159/159 checks, exit 0
```

The test count moved 1004 -> 1016. The `failed command:` lines that `zig build test
--summary all` prints are **stderr from tests that legitimately exercise negative paths**
(the analyzer's warnings, the examples suite's deliberate NOT-equivalent control at
`src/examples.zig:1232`, the fuzzer's coverage line). They are not failures: the summary
said 1016/1016 and exit 0, and there were **zero** `error:` lines. Confirmed by reading
the log, not waved off.

### The goal

Re-created this session as `goal-3b894c6f-c09f-4bed-bcc8-aa9f16608544`, max 40 rounds,
status active/armed. `get_goal` returns null after a session boundary, so it must be
re-armed again next time. The objective treats the §3.6 accelerators as part of the
**core** encoding contract, which resolves the tension the second handoff flagged.

---

## 2. F37 is CLOSED — and the decoder was RIGHT all along

F37 was filed as "the decoder does not reject a reserved accelerator byte" and left open
as a decision with two defensible readings. **Only one survives**, and the deciding
evidence was already in the tree:

- `src/disassembler.zig:552` is a passing, load-bearing test — *"a RESERVED accelerator
  opcode round-trips as raw bytes, not as a neighbour"* — and it **requires**
  `decode` to return `.ok` for a reserved byte. The disassembler reaches its `.raw`
  fallback **only** through the `.accelerator` arm (`:109` into `accelerator`, `:117-125`).
- §3.6's sentence has three clauses. Clause 1 ("decodes as an accelerator instruction with
  an unrecognised operation") and clause 2 ("must round-trip as raw bytes") **both require
  a successful decode**. Rejecting in the decoder contradicts the sentence it was meant to
  satisfy.

So **amendment 1.20** writes all three clauses out normatively and assigns each a layer:
the decoder accepts (**must not** be changed to reject), the bytes round-trip as `.raw`,
and the **simulator** refuses at execution — a fault, not a decode error. **No encoding
changed: no bit moved and no opcode was added.**

**Part of F37 is retracted in place.** It filed the decoder's behaviour as the *F8 shape*
("a rule enforced in one layer while another path reaches the same input ungoverned").
That framing was wrong — no rule was bypassed, because §3.6 never required a decode error.
The decoder is the governed path doing what clause 1 specifies; what was missing was a
statement of **which layer owns the refusal**, and that ambiguity is what made the decoder
look ungoverned.

Pinned in two places that must keep agreeing: `src/decoder.zig`'s *"F37 / amendment 1.20"*
test plus a comment at the `.accelerator` arm, and `src/vm.zig`'s *"a RESERVED §3.6 byte
still refuses DIFFERENTLY from a defined one"*. **Load-bearing, proven by mutation in a
throwaway copy:** making the decoder return `.err` for `0x6F` makes the new test fail with
`reached unreachable code` and the process abort.

---

## 3. F40 is CLOSED — the RTL was one opcode behind, and its testbench ASSERTED the wrong thing

Amendment 1.19 added a fourteenth §3.6 opcode, `matrix.mulout` (0x65), to the contract and
the simulator, and **touched nothing in `rtl/`**. The range `0x60`–`0x8F` is 48 bytes, so
the RTL was 13 recognised / 35 reserved against the contract's **14 / 34**.

Three sites disagreed, the third seriously:

1. `rtl/pkg/celeris64_pkg.sv:152-155` had no `OP_MATRIX_MULOUT` constant.
2. `rtl/accel.sv`'s exhaustive `unique case` listed 13 opcodes, and the comment above it
   named **0x65 as its example of a reserved byte**.
3. `rtl/tb/core_tb.sv:1040-1042` hard-coded `(b <= 8'h64) || ...`, and
   `check_recognised_table()` **fails any byte in that list that decodes as recognised** —
   so the testbench asserted 0x65 **must raise `unknown_op`**, the opposite of the contract.

**Fixed by taking the decision F40 named:** the RTL recognises 0x65 and raises
`not_implemented` like the other thirteen, staying **uniformly decode-only**. **No matrix
datapath was built** — §3.6 calls these operations a software model and
`rtl/CROSSCHECK.md` §4/§5.7 records that choice deliberately.

### The before-state is the interesting part, and it is the lesson of this session

| | result |
|---|---|
| Before the fix | `ok §3.6 all 13 normative opcodes recognised (13), 35 reserved rejected` — **PASS, 159/159, exit 0** |
| After the fix | `ok §3.6 all 14 normative opcodes recognised (14 observed), 34 reserved rejected` — **PASS, 159/159, exit 0** |
| Mutant (0x65 removed from `accel.sv`) | `FAIL ... got 13 recognised and 35 reserved` — **failures=1, exit 1** |

**The testbench did not fail before the fix — it PASSED while contradicting the contract**,
because it encoded the old table, so the check written to catch exactly this could not see
it. That is the **F31 shape**, and it is strictly harder to notice than a red test. The
mutant run proves the corrected table is load-bearing.

**A second defect found and fixed in the same task:** the closing `$display` printed `ok`
and the **expected** count **unconditionally**, so under mutation it emitted a passing line
beside the failure. It now counts what the RTL **actually** reports, separately from what
the test expects. The mutant output above is that change working.

**This was the second time this session that a green gate hid a disagreement** (F37's
decoder was the first). **Both were found by asking what a passing check actually
*asserts*, not by watching for failure.** Expect the same from `rtl/` next time.

---

## 4. F41 — the example breadth item is NOT delivered, and that is an honest result

`src/examples.zig` is **byte-identical to `b081f6f`**. The suite still passes: 7 kernels x
4 ISAs, `zig build examples` exit 0. **No eighth kernel landed.** Two attempts, both
stopped by a teammate, **both correctly**: each wrote a kernel whose CLS64 program did not
compute what the other three did, caught it against the reference, and reverted rather than
shipping it.

The full findings are in `docs/STATUS.md` F41 and on shared **task-2**. The essentials:

- **CLS64 needs MORE instructions than the other three for the same operation, and cutting
  them does not make the program faster — it makes it WRONG, silently**, with no assembler
  or decoder complaint. The second draft computed `x << 3` where the other three computed
  `rotl(x, 3)`; it assembled, ran, and produced a plausible count. Caught only by reference
  comparison, at **64 of 64 words mismatched**.
- **The verified CLS64 rotate shape** is `shl -> store to scratch -> shr 32 -> load
  original -> or -> store back`. The scratch round trip is **load-bearing**; removing it —
  the "obvious optimisation" — silently stops the program being a rotate.
- **Why, precisely** (`src/vm.zig:1058-1059`): `shl`/`shr` are **full-width and
  saturating** — computed over all 64 bits, yielding **zero** at a count of 64 or more,
  *not* masking the count to six bits the way x86-64's `shl` does. Truncation happens only
  on the **write** (`writeWidth`, `src/vm.zig:1066`), while x86-64's `imulq $8` **keeps**
  the high bits. So the extra instructions are a **correctness requirement**.
- **Measured** via this repository's own decoders: x86-64 454 retired, RISC-V 776, AArch64
  710. CLS64 will lose it; declare `.expected_loss`.
- **Two traps:** (a) **`llvm-mc` is an oracle for the three REAL ISAs ONLY** — it does not
  validate against this repository's subsets (an AArch64 `LSR` immediate `llvm-mc` accepts
  is not in the A64 subset here; the shift exists only as an ADD/SUB field, 0x8B/0xCB).
  Check **every** word against `src/isa_*.zig`. (b) A RISC-V branch label resolved as
  `j.eq .+8`.
- **A dead end, do not retry:** a data-driven table-walk kernel needing a "dead destination
  register" primitive. x86-64's decoder has **no shift handler at all** (falls to
  `UnknownOpcode`) and AArch64 has no standalone LSL.
- **Procedural lesson:** both attempts burned their whole budget on **generation plumbing**
  (three scratch toolchains) and never reached measurement. Next attempt: pick a kernel
  needing **no calibration or fixed-point argument**, **hand-write** the four programs
  rather than generating them, and verify all four through the decoders **before**
  measuring.

---

## 5. Analyzer breadth — delivered and independently verified

Three new sound rules in `src/analyzer.zig`: `select` with the same register in both arms,
`field.extract` at offset 0 width 64, `field.insert` at offset 0 width 64. Each is decided
by the instruction word alone, which is the module's soundness rule.

**Seven rejected rules** are recorded in the module header with the correct program that
breaks each — including `matmul_8x8`'s legitimate repeated arithmetic, `p1_zeroext`'s
deliberate write chain, and `tests/mulout_e2e.sh`'s intentional `jump 400000` fault trap.
**A rejected rule honestly documented is worth as much as an accepted one here.**

`src/diagnostics.zig` grew **50 lines, additive only** — verified mechanically as 50
insertions / 0 deletions, with `git diff -U0 | grep '^-[^-]'` empty. New constructors live
beside the existing ones; **no existing message text was touched**, which matters because
tests quote those strings and `live-check` replays 232 recorded facts.

**Load-bearing, verified by the Lead by mutation in a throwaway copy:** inverting the
`select` rule failed **three** tests, including the repo-wide corpus test — proving that
test really exercises the shipped programs rather than only fixtures.

---

## 6. What remains

1. **The example suite's eighth kernel (F41).** Not blocked by any defect; blocked by
   implementation cost. Follow §4 above and do not restart from zero.
2. **More analyzers** — breadth, not mechanism. The module header lists what is unsound and
   why; read it before proposing anything.
3. **The accelerators.** 11 of 13 execute. `matrix.mul` (0x62) and `codec.decompress`
   (0x81) are **refused by design**, each for a stated reason that is a property of the
   operation, not a missing constant (F36 in `docs/STATUS.md`). `0x65 matrix.mulout` was
   added by 1.19 and **executes**. **Do not "complete" the refusal by inventing a
   convention.**
4. **`cap.*`** stays decode-only. §3.5 v1.12 explains why: the register pair has no
   `length` bit position, so a capability cannot be reconstructed. Needs a §6 redesign, not
   a bug fix.
5. **CLS64 loses every example kernel**, and loses worst of four on `matmul_8x8` (11044
   against x86-64's 4838). **That is the intended result.** Do not "fix" it by changing the
   programs.

---

## 7. Environment facts that cost time

- Zig **0.17.1** at `~/.local/zig/zig`. No system `zig`.
- Verilator **5.49** at `~/.local/verilator/bin/verilator`.
- **`zig fmt` is NOT usable as a gate on this tree.** It flags `src/decoder.zig` and
  `src/vm.zig`, but **both were already flagged at HEAD** — and this toolchain's formatter
  wants a **semantic rewrite** (`@enumFromInt` → `@fromBackingInt`), not whitespace.
  Running it produces large unrelated churn. Verify with `git stash` that a file was
  already unformatted before blaming your change. **Do not run bare `zig fmt` on the tree.**
- `zig build test --summary all` prints `failed command:` lines for tests that write to
  stderr. Trust the **summary line and the exit code**, and confirm with
  `grep -c 'error:'` on the captured log.
- **A stale CLI binary reads exactly like a real result.** `zig-out/bin/celeris64` is only
  refreshed by `zig build`. `tests/mulout_e2e.sh` already refuses to run when the binary is
  older than `src/vm.zig` — keep that guard.
- **`rm -rf .zig-cache` while another build is running corrupts the run.** This produced a
  spurious batch of `NOT equivalent` failures this session. `tests/mulout_e2e.sh` runs
  `zig build` itself, so it must not race a cold wipe. Serialise, or check
  `pgrep -af 'zig build'` first.
- Verilator: use a **fresh `-o` path** and check the build's exit status before running —
  `rtl/CROSSCHECK.md` §2.3 records that a failed compile leaves the previous binary in
  place, so a "new" simulator can report old results. Build the testbench with
  `-Mdir <fresh dir>`.
- Two encoders exist (`assembler.zig` `Instruction.word()` and `decoder.zig` `encode()`);
  the fuzzer checks they agree. Keep it that way.

### Three traps, still confirmed

- **`assembleSource` moves its arena into the returned `Program`.** `prog.deinit()` **and**
  `assembler.deinit()` frees the same nodes twice — a double free on the **success** path.
- **Returning `prog.words` as a slice is unsafe on its own** — the arena can move it, and a
  stale slice reads `0xAAAA…` poison. Test helpers return `Program`.
- **A `Diagnostic` outlives the function that builds it.** A rendered string in a
  function-local buffer gives an empty or corrupt field, silently.

---

## 8. Honesty constraints this repository enforces

Load-bearing. Do not relax them.

- Every benchmark line contains the word **"simulated"**.
- **No clock frequency, timing figure, area figure or silicon performance claim appears
  anywhere.** `src/isaharness.zig` has no field for a timing quantity and a test fails if
  one is added.
- Models are labelled as models; RTL is synthesised but **never timing-closed and never on
  silicon**.
- A finding that turns out to be wrong is **retracted in place**, not deleted. This session
  retracted part of F37 for exactly this reason, and corrected F41's own shift-semantics
  note rather than quietly rewriting it.
- Mutation tests run in **throwaway copies**, never on the shared tree.
- **A comparison must not favour the subject.** When the honest fix makes CLS64 look worse,
  report the worse number.
- **A green test that asserts the wrong thing is worse than a red one.** This session found
  two (F37's decoder, F40's RTL table). Ask what a passing check *asserts*.

---

## 9. Goal in flight

```
Finish the CLS64 core ISA (no extensions/accelerators), then build a
non-cherry-picked cross-architecture example suite: multiple examples including
large ones, written idiomatically per ISA (CLS64, RISC-V, AArch64, x86-64), with
Zig analyzers producing findings, and an instruction counter that simulates
efficiency per assembly program. Every example must be verified equivalent
across all four ISAs and must not favour CLS64.
```

**No goal is active in this session's successor** — `get_goal` returns null across a
session boundary, so it must be re-created. The id used here was
`goal-3b894c6f-c09f-4bed-bcc8-aa9f16608544` (max 40 rounds). The accelerators are treated
as part of the core encoding contract (§3.6) rather than as optional extensions.
