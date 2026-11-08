# Celeris-64 Session Status

Living status record. Updated by the Lead. Every claim here was observed by running
something; claims that were not observed are marked as such.

## Toolchain

| Item | Value | Verified by |
|------|-------|-------------|
| Zig | 0.17.1 (official newest release, 2026-11-02) | `~/.local/zig/zig version` -> `0.17.1` |
| Location | `~/.local/zig/zig` -> `~/.local/zig-x86_64-linux-0.17.1` | symlink created and exercised |
| Host | `x86_64-linux` | `uname -m` |
| Install method | official tarball into `~/.local`, no sudo | download + extract + smoke test |

No system `zig` on `PATH`. `sudo` is unavailable in this session, so system packages
and apt-installed RTL tools are out of reach.

## Verified working

`~/.local/zig/zig build` -> exit 0.
`~/.local/zig/zig build test` -> **33/33 steps succeeded, 260/260 tests passed, exit 0**.
`~/.local/zig/zig build bench` -> exit 0.

| Check | Command | Result |
|-------|---------|--------|
| Register file | `zig test src/registers.zig` | **8 tests** |
| Memory model | `zig test src/memory.zig` | **4 tests** |
| Diagnostics | `zig test src/diagnostics.zig` | **8 tests** |
| Assembler | `zig test src/assembler.zig` | **26 tests** |
| Disassembler | `zig test src/disassembler.zig` | **46 tests** |
| Decoder | `zig test src/decoder.zig` | **22 tests** |
| VM core | `zig test src/vm.zig` | **67 tests** |
| field / select / stream | `zig test src/{field,select,stream}.zig` | **7 / 6 / 12 tests** |
| capability / thread | `zig test src/{capability,thread}.zig` | **9 / 15 tests** |
| matrix / fft / codec | `zig test src/{matrix,fft,codec}.zig` | **7 / 8 / 10 tests** |
| stdlib ui / gfx / net | `zig test src/stdlib_*.zig` | **7 / 8 / 13 tests** |
| Benchmarks | `zig test benchmarks/bench.zig` | **4 tests** |
| Adversarial suite | via `zig build test` (vm_tests root) | **37 tests** |

The full per-subsystem ledger, with the command behind every claim and the model
limits named, is [fidelity.md](fidelity.md).
| Decoder | `zig test src/decoder.zig` | **0 tests — still owed** |

Total: 74 module tests + 33 independent adversarial tests, all passing.

The mandatory architectural invariant is proven, not asserted: setting all 64 bits and
then writing a sub-width value leaves the upper bits **zero** (AGENTS.md §2.1).

## End-to-end pipeline, observed

```
$ ./zig-out/bin/celeris64 asm spec.asm spec.bin
  assembled 5 instructions into "spec.bin" (40 bytes).
$ ./zig-out/bin/celeris64 dis spec.bin
  000000:  compare R0, R1 -> R2
  000008:  select R3, R2, [EQUAL], R4, R5
  000016:  field.extract R0, R1, offset=12, width=3
  000024:  stream.add R0, [R1]+64, R2
  000032:  halt
$ ./zig-out/bin/celeris64 trace call.asm
  000000  call 16   # LR <- 0x0000000000000008, PC <- 0x0000000000000010
```

All four architecture-spec assembly examples parse and disassemble correctly, and the
`asm -> dis -> asm` round trip is **byte-identical** (`cmp` verified).

## Bugs found and their status

| # | Bug | Found by | Status |
|---|-----|----------|--------|
| 1 | `build.zig.zon` fingerprint rejected; value differs per invocation | verifier + core-vm + lead | **FIXED**, verified over two consecutive runs |
| 2 | `b.args` does not exist in Zig 0.17.1 `std.Build` | lead | **FIXED** |
| 3 | `std.fs.File` / `std.fs.cwd` removed in 0.17.1 (moved to `std.Io`) | lead | **FIXED** |
| 4 | `Vm.snapshot()` stored `mem_len` (a length), not contents — could not detect memory divergence | verifier | **FIXED** with a Wyhash digest; byte-exact check kept |
| 5 | Assembler compile errors | verifier | **NOT A BUG** — mid-write race |
| 6 | Module-graph error: `registers.zig` belonged to two modules | tooling | **FIXED** in `build.zig` |
| 7 | `decodeAlu` hardcoded `.add` for all ten ALU opcodes; `compare` decoded as `add` | tooling (via round-trip) | **FIXED** |
| 8 | `.imm` never null, so register-form instructions did not round-trip | tooling | **FIXED** |
| 9 | `call` decoded with the `.jump` tag, so `LR` was never set — every subroutine call broke silently | verifier | **FIXED**; verified by trace |
| 10 | Reserved width 4..15 silently executed as full width | verifier | **FIXED** at the decoder |
| 11 | `loadWords` was not atomic — wrote words before failing bounds | lead + verifier | **FIXED** |
| 12 | Test-helper alignment mismatch crashed 9 tests | lead | **FIXED** |
| 13 | Ungrammatical diagnostics ("could not be decoding this word") | verifier | **FIXED**, with a guard test |
| 14 | Empty location clause rendered `"error: at  while ..."` | verifier + lead | **FIXED** |
| 15 | `encode(decode(w)) == w` not yet implemented in the decoder | contract | **FIXED** — implemented and tested over all 30 opcode-map words |
| 16 | Spill warning (AGENTS.md §4.3) was unreachable dead code — `max_gpr_seen > 12` can never be true when only 12 GPRs exist | tooling | **FIXED** — reimplemented as live-register pressure, 3 tests |
| 17 | Three stdlib modules passed in isolation but were in no test root, so 28 tests never ran under `zig build test` | lead (while integrating) | **FIXED** — per-module test roots added |
| 18 | `Capability.covers` used a saturating add, so an access overflowing the address space appeared to fit a top-of-range capability | lead | **FIXED** — overflow-checked add, regression test |
| 19 | Test-side aliasing: the naive DFT was passed the same buffer as input and output | lead | **FIXED** — mine was the test, the FFT was correct |

## False-green hazards caught

These matter more than the passing tests, because each would have shipped a
misleading signal:

1. **`zig build` exit 0 was vacuous.** The Lead's stub `main.zig` imported only `std`,
   so it never compiled `vm.zig` or `decoder.zig`. Tooling caught this. A green build
   proved nothing about the VM graph.
2. **`snapshot().eql()` was too weak.** It compared a memory *length*. Two runs
   differing in every memory byte compared equal. The determinism guarantee was not
   actually enforced by the API.
3. **`call` looked correct.** The disassembler always printed `call`, so the bug was
   invisible except in execution, where `LR` stayed 0 and every `ret` returned to
   address 0. Caught only by a decode-tag harness.
4. **Reserved widths silently became full widths.** The validation function existed and
   worked; the decode path bypassed it entirely.
5. **A green suite can test nothing.** Verifier's `PENDING:` placeholder asserts nothing
   and says so in its own body.

## Honest limits

Current, verified state. Superseded claims are removed rather than left to mislead.

- **Wired and executing**: all ALU ops, `compare`, `select`, `field.extract`,
  `field.insert`, `stream.add/copy/fill/setp`, `jump`, `call`, `ret`, `halt`, `nop`,
  and as of task-19 `thread.spawn/join/yield`. Verified end-to-end through the CLI,
  not just in unit tests.
- **`thread.*` (0x90–0x92) now executes** against the `thread.zig` scheduler. It is a
  **deterministic modelled interleave**: no timing, no real concurrency, no speedup
  claim. `thread.spawn` with an empty mask is legal and starts nothing (Amendment
  1.1); `thread.yield` with no runnable slot faults rather than advancing.
- **`cap.*` (0x50–0x52) and the accelerator range (0x60–0x8F) remain non-executing.**
  Accelerator words fault with a plain-language "not wired into this build yet"
  diagnostic naming the word and PC. `cap.load`/`cap.store` are **decode-only by
  ruling** (§3.5 Amendment 1.11) because the encoding carries no address field;
  `cap.check` status is recorded in `docs/fidelity.md` §6.1. *Not wired is not the
  same as broken* — where the contract does not define the semantics, the machine
  refuses rather than guesses.
- `src/capability.zig` is **not cryptography**, not unforgeable and **not a security
  boundary**. `src/thread.zig` is **interleaved, not parallel**. `src/codec.zig`'s
  hash and checksum are **not authentication**. Each limit is asserted by a test
  named `MODEL LIMITS: ...` so the claim is auditable.
- `matrix.*`, `fft.*`, `codec.*`, capability checks and SMT threads are **software
  models**, per `docs/isa-encoding.md` §8. No acceleration, no cycle claims.
- RTL (Phase 4) **is written and lint-clean**: `rtl/pkg/celeris64_pkg.sv`,
  `regfile.sv`, `alu.sv`, `stream_engine.sv`, `select_unit.sv`, `field_unit.sv`,
  `core.sv`, `accel.sv`, plus three testbenches under `rtl/tb/`. Verilator 5.49 was
  installed via a prebuilt manylinux wheel into `~/.local/verilator` (no sudo, no
  source build). Whole-tree lint is clean and the testbenches run real assertions;
  see `rtl/CROSSCHECK.md`.
  **This RTL has never been synthesized, never been timing-closed, and has no known
  clock frequency.** `yosys` is absent. It is a lint-clean simulation model, not
  silicon, and no document may claim otherwise.
- Cycle counts and benchmarks are **simulator instruction counts**, never a claim
  about silicon. Every benchmark line says "simulated" for that reason, and two
  tests enforce it.
- `compare`/`select` end-to-end is asserted at unit level but deliberately **not**
  in the adversarial suite, because a PC-accounting question was open when that
  suite was written and encoding a possibly-wrong value was judged worse than the gap.
- **Round trip now works verbatim** (fixed after being recorded as a defect here).
  Two separate problems were involved, both verified by running the commands a user
  would actually type:

  1. **Success output went to stderr.** `asm`, `dis` and `run` printed to stderr, so
     `celeris64 dis prog.bin > prog.asm` produced an empty file. Fixed: success text
     now goes to stdout, diagnostics remain on stderr.
  2. **The disassembler's own output could not be re-assembled.** `dis` prefixes
     every line with an address (`000000:  ...`), and the assembler rejected its own
     disassembler's output. Every earlier "byte-identical" round-trip proof in this
     session contained a manual `sed` strip of that prefix — the claim was true only
     under a condition that was never stated. The assembler now strips a hex-only
     address prefix itself.

  Verified with no stripping and no redirection tricks:

  ```
  $ celeris64 asm prog.asm prog.bin
  $ celeris64 dis prog.bin > prog.dis
  $ celeris64 asm prog.dis again.bin
  $ cmp prog.bin again.bin     ->  IDENTICAL
  ```

- **Residual round-trip gap: 0x60–0x8F and zero-mask 0x90–0x92.** These words
  still cannot be re-assembled, and the disassembler no longer pretends otherwise —
  the accelerator range now renders as a commented byte dump
  (`# accelerator opcode 96 (0x60), rd=R0, rs1=R0, operand=0x...`), which is honest
  about the bits and cannot be mistaken for input the assembler would accept.
  `thread.*` reassembles correctly with a non-zero slot mask; only a zero mask
  fails, because the assembler requires at least one slot. Closing this properly
  requires the accelerator operand layout, which `docs/isa-encoding.md` §3.6
  deliberately leaves to the model modules — so it stays a recorded gap rather than
  invented syntax.
- **`T-none` placeholder removed.** A zero thread-slot bitmask rendered as an
  invented name; it now reads `no slots`.

## Reproducing the state above

```sh
rm -rf .zig-cache zig-out
~/.local/zig/zig build          # exit 0
~/.local/zig/zig build test     # 33/33 steps, 260/260 tests, exit 0
~/.local/zig/zig build bench    # exit 0
```

Per-subsystem evidence, with the command behind every claim, is in
[fidelity.md](fidelity.md).


---

## Phase 4 opening — contract v1.3 and the Verilator route

### The toolchain blocker was solved, not accepted

Task-8 was previously left pending because no HDL tool existed here and `sudo` is
unavailable. Reconstruction of that finding:

- Missing: `verilator`, `iverilog`, `yosys`, `gtkwave`, `bison`, `flex`, `autoconf`.
- The GitHub source tarball ships `configure.ac` with **no generated `configure` and no
  pre-generated parser**, so building from source requires bison/flex/autoconf. Dead end.
- **PyPI ships a prebuilt manylinux x86_64 wheel containing the real `verilator_bin`**
  and the full runtime. No compiler toolchain needed. Extracted to `~/.local/verilator`.

Verified rather than assumed — a distribution that cannot reject bad input proves nothing:

```sh
~/.local/verilator/bin/verilator --lint-only -Wall t.sv      # valid module
# exit 0
~/.local/verilator/bin/verilator --lint-only -Wall bad.sv    # missing semicolon
# %Error: bad.sv:4:1: syntax error, unexpected endmodule
# exit 1
```

### Two corrections found by teammates, both to Lead-owned artifacts

**1. `--version` is not v5.48.0.** It prints `rev vUNKNOWN-built20260516-4e853d8` and
self-reports as Verilator 5.49. The wheel's build metadata does not carry the release
tag. `rtl-core` reported the artifact it measured rather than the version it was told;
that is the correct behaviour and the version string in the task text was wrong.

**2. `-Wall` makes warnings fatal — so exit 1 does NOT mean broken.** The Lead's framing
had been "a clean module lints exit 0, so exit 0 means something", which quietly implied
exit 1 meant broken. Reproduced:

```sh
~/.local/verilator/bin/verilator --lint-only -Wall warn2.sv   # valid, one unused param
# %Warning-UNUSEDPARAM: ... 'UNUSED_P'
# %Error: Exiting due to 2 warning(s)
# exit 1
```

The correct claim is **zero warnings on these modules**, not an exit code. Also:
passing two top modules in one invocation trips `MULTITOP`; name `--top-module`.

### Contract amendments: three defects found in the normative document itself

The encoding contract is Lead-authored and was declared normative. It had never been
independently reviewed, and it contained a self-contradiction.

| Ver | Defect | Resolution |
|-----|--------|------------|
| 1.1 | §3.6 deferred the accelerator operand layout to the model modules, which is why `0x60`–`0x8F` could not re-assemble | Layout fixed: `rs2[47:44]`, `rs3[43:40]`, `reserved[39:32]`, `count[31:0]`. 13 opcodes assigned. §3.7 zero slot mask made legal and round-trippable |
| 1.2 | **§3.1's diagram drew `imm28[39:0]` (40 bits) while its prose said "signed 28-bit"** | 28 bits: `imm28[27:0]`, `zero[39:28]` reserved. Found by `rtl-core` while cross-checking the RTL against `decoder.zig` |
| 1.3 | §3.2 `operand[35:0]` undocumented; §3.2/§3.3/§3.4 reserved fields had no rejection rule; §2 claimed a "wide immediate form" that §3.1 never defined | All reserved fields now state rejection-when-set; stale sentence removed |

The v1.2 defect is the important one. `rs2[47:44]` + `width[43:40]` + 40 bits = exactly 48,
so the 40-bit drawing was *geometrically self-consistent* and survived review on that
basis. `assembler.zig` enforces the signed-28-bit range and `decoder.zig` reads a `u28`,
so the divergence was unreachable through the normal path — it could only be found by
implementing the diagram literally in a second engine and comparing. Both `rtl-core`
reporting it instead of silently picking a side, and `verifier` being asked to attack the
rest of the document on the same pattern, come from the same lesson: three false-green
incidents this session were each caught only by executing a claim.

All six operand layouts were then audited arithmetically and confirmed to sum to exactly
48 bits: §3.0 `imm48`; §3.1 `4+4+12+28`; §3.2 `4+4+4+36`; §3.3 `8+8+4+28`;
§3.4 `4+20+4+20`; §3.6 `4+4+8+32`.

### A vacuous-green hole closed in `build.zig`

`tooling` found that `zig build test` reported **260/260 green while all 56 disassembler
tests never ran**. The tooling root was `src/assembler.zig` (28 tests), and
`assembler.zig` does not import `disassembler.zig`, so the file was never compiled into
the suite. Every accelerator round-trip test written for task-11 was invisible.

Fixed by adding an explicit `src/disassembler.zig` root. **Proven by fault injection, not
by inspection:** injecting an unconditional error into the first disassembler test turned
the suite red — `Build Summary: 32/35 steps succeeded (1 failed)`, compile error pointing
at `src/disassembler.zig` — where previously the same file was never opened. Restored
byte-identically and re-verified green.

This is the fourth instance of the session's recurring failure mode: a green signal that
tested nothing. It was caught by a teammate who noticed the arithmetic (28 = assembler
alone) rather than by reading the summary.

### Toolchain workarounds now centralised

Both hit every RTL teammate; recorded once so nobody rediscovers them:

- `verilated.mk` ships an empty `CFG_CXXFLAGS_STD`; `--binary` needs
  `-CFLAGS "-std=c++20" -LDFLAGS "-std=c++20"` or `verilated_timing.cpp` fails on
  `std::suspend_never`.
- `verilated.mk` hardcodes `python`; the host has only `python3`. A shim now lives at
  `~/.local/bin/python`. The Verilator install is not modified.

### Status

RTL subtasks 8a (`task-12`) complete, 8b (`task-13`) and 8c (`task-14`) in progress,
independent verification (`task-15`) in progress. Nothing here is synthesized, timing
closed, or placed on silicon, and no clock frequency is claimed anywhere.

### Independent verification found six more defects — five of them in the contract

`verifier` attacked the normative document on the pattern that produced the imm28 bug
(a normative claim contradicted by another section, or by the code). It worked. Every
item below was reproduced by the Lead before being acted on.

| ID | Severity | Defect | Resolution |
|----|----------|--------|------------|
| F3 | contract | §2 promised a "wide immediate form" that §3.1 never defined and no implementation has | Removed in v1.3 |
| F4 | **contract, serious** | §3.1's v1.2 amendment said bits `[39:28]` "are reserved and must be zero" as a *global* fact, but §3.4 legally defines `operand[39:0]` as a 40-bit stride for `stream.setp`. Read literally, the amendment rejected every legal `setp` | v1.4: reservations are scoped **per instruction class, never global** |
| F5 | contract | §6 said `length` is 64-bit "stored in `permissions[23:0]`" — impossible, and `capability.zig` carries it as a full `u64` | Line removed; it described an implementation never written |
| F6 | **code, open** | §3.1 reserves the ALU bits and declares a violation a diagnostic error; the decoder does not check. RTL *does* (`rtl/alu.sv:69`) | task-16 |
| F7 | **CRITICAL** | `thread.spawn T0-T7, R0` — a verbatim v1.4 example — **aborts with SIGABRT** | task-16 |
| F8 | **silent** | §4's PC rules unimplemented: `add PC, ...` assembles, and the write is silently discarded by `vm.zig:246` | task-16 + task-17 |
| F9 | contract | §4 said "any read of index `15` … where a zero is required is not defined", but index 15 is `FLAGS` per §4's own table | Deleted in v1.4 |

The dominant failure mode of this document is now clear: **a normative sentence
contradicted by another section or by the code.** Four confirmed instances (imm28, F4,
F6, F9) plus one dead description (F5). The contract needed an adversary far more than it
needed another author.

### F7: the contract's own example aborts the assembler

```
$ printf "thread.spawn T0-T7, R0\n" > ex.asm
$ celeris64 asm ex.asm ex.bin
thread 50309 panic: shift amount is greater than the type size
src/assembler.zig:934:66 in parseSlots: while (i <= b) : (i += 1) mask |= @as(u5, 1) << i;
EXIT=134
```

Two bugs on one line: `var i: u3 = a` overflows at 7→8 for `T0-T7`, and `@as(u5,1) << i`
would be an illegal shift at `i=8` regardless. It is the one slot-range shorthand §3.7
advertises, so it fails on the *happy* path, and a Zig stack trace breaches §7's
no-panic rule outright. `verifier` tested all six §3.7 examples verbatim: five
round-trip, this one aborts.

### F8: silent is worse than loud

`add PC, R1, R2` assembles with exit 0. At run time the ALU computes a value, writes it
to PC, and `vm.zig:246` overwrites it with the normal advance. The trace prints
`PC <- 0x0000000000000008`, which is the *advance*, not the computed value. A user can
write a computed jump, be told nothing, and not jump. The fix is split deliberately: the
assembler rejects it at assembly time with a line number (§4's own words are "a
diagnostic error"), and the VM faults so a hand-encoded binary cannot slip through.

### Verifier discipline worth recording

`verifier` filed a failure, then **retracted it** on discovering it was a stale-artifact
false positive — the RTL files were newer than the compiled artifact. Re-running clean
gave 80/80. A verifier whose errors are hidden is worthless, and catching your own false
positive before it reaches the record is the behaviour that makes the rest of the report
trustworthy. The mid-write rule has now prevented three false reports.

It also volunteered two arithmetic slips of its own in a testbench ("80/80 only means
something if you know four failed first") and corrected two garbled messages rather than
letting them stand.

### The lint criterion was wrong twice, and both times a teammate proved it by measurement

The Lead's acceptance criterion was "`verilator --lint-only -Wall` exits 0". It turned out
to be unmeetable, for two independent reasons, each demonstrated with a reproduction
rather than an assertion.

**Reason 1 — per-module `UNUSEDPARAM` (found by `rtl-core2`, confirmed by Lead).** A package
localparam that a given top does not reference draws `UNUSEDPARAM`, which `-Wall` makes
fatal. `rtl/regfile.sv` is the only consumer of `REG_SP/LR/PC/FLAGS` and
`GPR_COUNT/GPR_INDEX_MAX`, so only a top instantiating regfile can reach zero alone:
```
$ verilator --lint-only -Wall --top-module alu rtl/pkg/celeris64_pkg.sv rtl/regfile.sv rtl/alu.sv
%Warning-UNUSEDPARAM: ... 'GPR_COUNT','GPR_INDEX_MAX','REG_SP','REG_LR','REG_PC','REG_FLAGS'
EXIT=1
$ verilator --lint-only -Wall --top-module regfile rtl/pkg/celeris64_pkg.sv rtl/regfile.sv
EXIT=0
```
Ruled: whole tree, single invocation, `--top-module core`, no suppressions.

**Reason 2 — a Verilator false positive on packed structs (found by `rtl-core2`).** That
ruling left exactly one warning: `core.sv:199 'word_d'[39:0]`, on a field that is
demonstrably used (line 215 reads `word_d.operand`, lines 317-323 read `imm28`,
`imm_sext`, `alu_zero`). The Lead settled it with a decisive probe: reading the **entire**
48-bit `operand` field once into an output still fires the warning, and names the range
`[55:48]` — which does not correspond to `operand` at `[47:0]` at all. Verilator's
flattened bit numbering for packed structs is wrong here.

Ruled **(D)**: one region-scoped `lint_off UNUSEDSIGNAL` in `core.sv`, with the
reproduction pasted into the comment and `CROSSCHECK.md`. Rejected: **(G)** hand-slicing
the word would duplicate the package's `unpack_word` and recreate the §2 decode drift the
package exists to prevent; **(E)** `-Wno-UNUSEDSIGNAL` tree-wide would surrender a warning
class that already caught a real defect (`stream_engine.sv:101`); **(F)** is (B) again.

The standard applied: a suppression is acceptable when it is file-local, region-scoped,
and justified by a reproduction a reader can re-run — and unacceptable when it hides real
signal in a file third parties compile against. Same standard as the Lead's own contract
defects.

Down from 29 whole-tree warnings to 1. The other 28 were genuine: undefined `st_issue`, a
stale `ptr_q_i` pin, `MULTIDRIVEN` from a duplicated assign block, empty pin connections.

### Known RTL narrowness, recorded rather than tidied away

`rtl/stream_engine.sv` walks at most 8 elements per pass (`WALK_LIMIT`, 3-bit counter) and
refuses larger chunks on `chunk_too_large_o`, while §3.4's chunk field is 20 bits. The
model refuses loudly instead of silently doing less than asked, and the limit must be
stated in `CROSSCHECK.md` so that "the four cross-check programs agreed" is never read as
"the RTL implements §3.4's full chunk range".

### Test count reconciled: 348 — and the Lead published a wrong number first

Three figures circulated for the same suite: `348` (tooling), `177` (Lead), and a
per-file sum of `421`. The truth is **348/348 across 35/35 build steps**, and it is the sum
of exactly 17 test roots:

```
vm 77 | vm_tests 37 | assembler 35 | disassembler 67 | stream 12 | field 7 | select 6
decoder 26 | memory 4 | registers 7 | stdlib_gfx 8 | stdlib_net 13 | capability 9
thread 15 | matrix 7 | fft 8 | codec 10        == 348
```

**The Lead's 177 was wrong and was reported as if complete.** The cause: the `--summary all`
output was still streaming while teammates were mid-write, so a `tail` captured roughly
half the roots and the partial total was treated as the answer. The per-file sum of 421 is
also not the right comparison — standalone `zig test` on a file counts tests that the
in-suite root reaches differently (`registers.zig` is 8 standalone, 7 via its root), so
only the build summary is authoritative.

This is the same error class the Lead has been enforcing on everyone else all session — a
number true only under an unstated condition (here: "I captured the whole output"). It was
caught only by summing the individual roots rather than trusting either headline figure.
Recorded because the discipline has to bind the Lead too.

### The contract went from 1.0 to 1.8 in one session — every version a defect found by someone else

Ten defects, and the Lead authored every one of them:

| Ver | Defect | Found by |
|-----|--------|----------|
| 1.1 | §3.6 deferred the accelerator operand layout, making `0x60`–`0x8F` un-round-trippable | Lead (round-trip gap) |
| 1.2 | §3.1 diagram drew `imm28[39:0]` (40 bits) while the prose said 28 | `rtl-core`, cross-checking RTL vs `decoder.zig` |
| 1.3 | §3.2 `[35:0]` undocumented; reserved fields had no rejection rule; §2 claimed a "wide immediate form" that never existed | Lead + `verifier` (F3, independently) |
| 1.4 | §3.1's reserved rule read as *global* while §3.4 legally reuses those bits; §6's 64-bit `length` "stored in 24 bits"; §4 described FLAGS as ZERO | `verifier` (F4, F5, F9) |
| 1.5 | §4 contradicted itself on writing PC: "a diagnostic error" vs "index 12–15 in `rd` … is legal" | `core-vm` |
| 1.6 | §3.7 declared the slot mask as `operand[4:0]` — **five bits for eight slots** — so the section forbade the word its own slot range required | Lead arithmetic check, exposed by fixing F7 |
| 1.7 | §3.3 left `[27:0]` unmentioned; §3.0 implied `jump`/`call`/`ret` bits were unconstrained | `tooling` bit-position audit |
| 1.8 | §6 claimed a diagnostic for reserved permission bits that cannot fire | `verifier` (F10) |

**The single dominant defect mode: a normative sentence contradicted by another section, by
the code, or by arithmetic.** Seven confirmed instances. Not one was found by a value-based
test — every one required either deriving a width from the architecture, or implementing the
same spec twice and comparing.

Two observations worth keeping:

1. **Fixing one defect exposed the next.** The `T0-T7` abort (F7) *masked* a malformed word;
   repairing the abort surfaced the five-bit slot mask (v1.6). The imm28 bug was found only
   because the RTL implemented the diagram literally. Errors here come in layers, and the
   layer below is invisible while the one above is crashing.

2. **Two teammates independently declined to implement rules the contract had not actually
   stated.** `tooling` found §3.3's `[27:0]` and §3.0's `rd`/`rs1` unmentioned, and left them
   alone rather than inventing a rejection — then said so. That is the correct instinct: it
   located the omission in the document instead of guessing at intent. Both are now explicit
   reservations in v1.7, and `tooling` is implementing them.

### Reserved fields: four normative reservations, none implemented

§3.1 ALU, §3.4 stream, §3.6 accelerator and §3.7 thread all declared reserved bits that must
be rejected. Only the accelerator one was ever implemented. `verifier` found the ALU gap
(F6) partly because the **RTL had implemented it while the decoder had not** — two
implementations of one spec disagreeing, which is the same shape as imm28. All four are now
enforced, each with a positive control proving the fix did not over-reach into a neighbouring
layout that legally uses the same bits (`stream.setp`'s 40-bit stride is the standing case).

The pattern that found them: *set the reserved bits explicitly and see whether anything
complains.* Value-based tests never did, because no test ever constructed such a word.

### A toolchain defect that would have silently corrupted the RTL

`rtl-primitives` found this while fixing their testbench. The Lead verified it with a
minimal case:

```systemverilog
assign a = 64'd0   +| 64'd32;   // measured: 1     correct: 32
assign b = 64'd100 +| 64'd5;    // measured: 101   correct: 105
assign c = {64{1'b1}} +| 64'd2; // measured: 0x0   correct: saturate to all-ones
```

**This Verilator build (5.49, the only simulator available here) does not implement
SystemVerilog's saturating-add operator.** It wraps instead, and reports plausible-looking
wrong numbers rather than failing loudly. A design using `+|` for a pointer or address
would be silently wrong with no diagnostic.

Confirmed the defect is **Verilator-only, not a language problem** — Zig's `+|` is correct
in the same environment:
```
0 +| 32  = 32        (correct)
max +| 2 = 2^64-1    (saturates correctly)
```
So `src/vm.zig` and `src/memory.zig`, which use `+|` for `pc +| instruction_bytes` and for
bounds arithmetic, are **not affected**. No Zig code was changed.

`rtl/stream_engine.sv` was the only file using the operator; it now uses an explicit
widen-and-clamp `sat_add` with the measurement recorded in a comment. The rest of the tree
was grepped clean. The lesson is not "avoid `+|`" but "the only simulator here has a defect
that produces silent wrong answers" — which is precisely the reason no RTL claim in this
repository is stronger than lint plus simulation.

The operator is deliberately *not* simply deleted where saturation is wanted: `pc +| bytes`
is a real idiom in the verified Zig VM, and a wrapping add in the RTL would be a genuine
behavioural divergence from the model it is being cross-checked against.

### RTL atomicity is now genuinely verified — the claim held open since Phase 4 began

The stream testbench failed 117/309 when `verifier` first ran it, and they correctly refused
to attribute the failure to the stream engine or to exonerate it, reporting three tells that
pointed at the harness. `rtl-primitives` then fixed the **design**, not the harness:

- `mem_wr_byte_o [7:0]` → `mem_wr_data_o [XLEN-1:0]`, and likewise the read port. One byte
  cannot express a 64-bit element, so an 8-bit lane mask over a byte port was genuinely
  ambiguous — the harness had been replicating a single byte across eight addresses.
- This also exposed a **real functional bug invisible from outside**: per-lane byte
  derivation was wrong for `add`, because each lane needs a *different* value.
- The testbench memory now decodes the full 64-bit address and **refuses** out-of-range
  access instead of truncating it into a 32-byte array. That truncation was why the
  atomicity vector had been observing another vector's fill constant at byte 0 — it was
  testing address aliasing, not atomicity.

Independently re-run by the Lead: **314 assertions, 0 failures**, with the atomicity line
explicit. The overrun-by-exactly-one-element case asserts every byte still holds its fill
value, the snapshot is unchanged, the pointer did not advance, and the bounds error is
raised.

Mutation testing (4 injected, 4 caught) is what makes the suite credible: removing the
atomicity gate produced 80 failures **correctly shaped as a partial write**, swapping the
signed LESS/GREATER enum values was caught by the `-1 vs 1` divergence vector, an 8-bit
offset+width sum was caught by a wrap counterexample, and dropping the `width==64` mask
special case was caught. Sources restored byte-identically.

The general lesson from this and the `+|` defect: the RTL is only as trustworthy as its
harness, and a passing testbench that tests aliasing instead of the property is worse than
no testbench, because it produces a green signal attached to the wrong claim.

### Process rule: never mutation-test in place on a shared tree

`rtl-primitives` ran a fault-injection loop directly in `rtl/` while `rtl-core2` was
compiling the same tree. Mutants cycled through `select_unit.sv`, `field_unit.sv` and
`stream_engine.sv` one at a time, each written, built, and restored in sequence — so the
tree was transiently wrong repeatedly over several minutes, and any compile landing in that
window read a corrupted module.

The failure mode was worse than a single bad window: under `-Wall`, the injected fault
became a **fatal warning**, so the compile aborted and `rtl-core2`'s simulator binary
silently remained the *previous* build. They spent real time on it and initially read it as
their own bug, before identifying the cause and reporting it without blaming anyone.

**Rule: mutation-test on a copy under `/tmp`, never in place on a file another agent may be
compiling.** If an in-place run is ever unavoidable, announce the start and the restore.

**This was the Lead's miss, not the teammate's.** The Lead asked for mutation testing without
stating where it may run, on a project whose whole method is concurrent agents sharing one
filesystem. `rtl-primitives` had actually built a `mutate.sh` wrapper that copies pristine
sources in first, then bypassed it with a hand-rolled loop — the discipline was lost exactly
where the process did not name it. The rule is recorded here as a process rule, not a
criticism, and the teammate disclosed it, restored the tree, and verified the restoration.

Restoration verified independently by the Lead, not taken on report:

```
$ grep -rn "MUTANT" rtl/            -> no output, exit 1 (clean)
$ sha256sum rtl/stream_engine.sv rtl/select_unit.sv rtl/field_unit.sv
c996bbaf1592b081095539bbcad5a85888ee897747c266bb7f226d686a6b9544  rtl/stream_engine.sv
4f0d733f2b6a126033acf4e1cf6bb4de5bd0c9caf027c2a82b17807dadb6704d  rtl/select_unit.sv
1946e11e2780c82b0d222451fb9deaae4d6836bb98bf2262d747e8e0a4d3be01  rtl/field_unit.sv
```
All three match the teammate's pre-mutation baseline, and the three specific mutated lines
are back to their real forms. The 314/314 testbench run was then reproduced on the restored
files, so the passing result is attached to the code now on disk.

The mutation results themselves stand and are valuable: 6 injected, 6 caught, including the
two contract-v1.9 reserved-field requirements that had been added after the module was first
written. Removing the atomicity gate produced 80 failures **correctly shaped as a partial
write**, which is what makes the 314/314 credible rather than merely green.

### `tools/audit-reserved.sh` — a mechanical guard for the defect class that recurred twice

The team independently hit the same structural problem from two directions:
`verifier` found §3.1's ALU reserved bits declared-but-unimplemented (F6), and
`rtl-primitives` found that two contract-v1.9 amendments (§3.2.2 `operand[35:0]`,
§3.3 `operand[27:0]`) had been added *after* their modules were written, so the modules
did not implement them either. `rtl-primitives` put it best: *"contract amendments outrun
implementations — the risk is structural rather than incidental."*

So the pairing is now checked mechanically instead of by prose reminder. The script does two
things, and the second is the one that matters:

1. **Presence** — greps `src/decoder.zig` for an enforcement point per declared reservation.
2. **Falsification** — constructs a word with each reserved field **explicitly set** and
   requires the disassembler to reject it.

The distinction is not academic. With one guard disabled in the decoder, the **grep half
still reported OK for every field** — it found the function name and was satisfied. Only the
behavioural half caught it:

```
RESULT: every audited declaration has an enforcement point named above.
falsification -- each reserved field set explicitly, must be REJECTED:
  SILENT (BAD)  §3.0 nop operand set       -> 000000:  nop
  rejected OK   §3.0 jump rd set
  ... seven more rejected OK ...
RESULT: 1 reserved field(s) accepted silently -- contract says reject.   (exit 1)
```

The mutation was then reverted byte-identically and the audit returned to exit 0. That is
what makes the guard trustworthy rather than merely present — and it is the same standard
applied to every other test on this project: a check that cannot fail is worthless.

Eight enforcement points are audited: §3.0 (two), §3.1, §3.2.2, §3.3, §3.4, §3.6, §3.7.

**Why value-based tests could never have found this class:** they build *legal* words. A
reserved field that is never checked stays invisible no matter how many legal words are
tested. The technique that does find it — *set the bits and see whether anything complains* —
closed four defects (F6, §3.4, §3.7, and the two v1.9 amendments), every one of which had
been latent through multiple contract revisions. The companion discipline is the **positive
control**: after adding each rejection, re-assert that legal words sharing those bits still
round-trip (`stream.setp`'s 40-bit stride and `field.extract offset=12,width=3` are the two a
careless global check breaks). A reserved-field sweep without positive controls is a
regression generator.

### Phase 4 closed, with one task re-dispatched after a message was lost

State at this point, verified by the Lead running each command on a quiescent tree:

```
zig build        -> 0
zig build test   -> 35/35 steps, 369/369 tests, exit 0
zig build bench  -> 0   (every line says "simulated")
zig build audit  -> 0   (all 8 reserved fields rejected when explicitly set)
verilator --lint-only -Wall --top-module core <whole rtl/> -> 0 warnings
rtl/tb/alu_tb.sv    -> 80/80
rtl/tb/stream_tb.sv -> 314/314, atomicity holds
rtl/CROSSCHECK.md   -> 4/4 programs agree with the Zig simulator
```

`grep -rn MUTANT rtl/` returns nothing; the three RTL files match their pre-mutation
baseline hashes.

**One process failure, caught by re-checking rather than by trusting the summary:** the
`task-18` message to `tooling` was never delivered — a harness glitch ate it. The task was
created on the board and sat unclaimed while the Lead believed it dispatched. It was found
by re-running the `stream.*` width check on the rebuilt binary and seeing `width[23:20]=0`
for all four suffixes, i.e. the bug was still live. Re-sent.

The lesson is the same one this project keeps teaching: a dispatch is not a delivery, and a
task on the board is not work in progress. The only thing that established the gap was
executing the check again on the current tree.

### Session close: 442/442, all gates green

Final state, every figure independently re-derived by the Lead on a clean-room tree
(`rm -rf .zig-cache zig-out`) and summed from the individual roots rather than read off a
headline:

```
zig build        -> 0
zig build test   -> 37/37 steps, 442/442 tests, exit 0   (18 roots, summed = 442)
zig build bench  -> 0   (every line says "simulated")
zig build audit  -> 0   (9/9 reserved fields rejected when explicitly set; 1 exemption)
zig build live-check -> 0   (232 recorded facts re-derived from the current binary)
verilator --lint-only -Wall --top-module core <whole rtl/> -> 0 warnings
rtl/tb/alu_tb.sv    -> 80/80
rtl/tb/stream_tb.sv -> 314/314, atomicity holds
rtl/CROSSCHECK.md   -> 4/4 programs agree with the Zig simulator
grep -rn MUTANT rtl/ -> nothing
```

**Superseded (kept for the record).** This session closed twice earlier. The first read
**375/375** at contract v1.10; the second read **418/418** after task-19/20/23/24. Both
were correct when written. The count is now 442 because the independent verifier's 24-test
suite was wired into the build as an 18th root — it had been passing standalone for the
whole session while being invisible to `zig build test`, which is exactly the failure
already recorded when the disassembler's 56 tests were unreachable. Older figures are
retained rather than overwritten because this file's value is that a stale number can be
seen to have been stale.

The contract reached **v1.10**. Every version from 1.1 onward was a defect in a document the
Lead wrote and declared normative — eleven in total, none found by the author.

### task-18: three defects where one was reported

`rtl-core2` found one (`stream.*` element width unencodable). `tooling` found three:

1. **The reported bug** — `runStream` used `parseReg`, which discards the §5 suffix, so
   `stream.add R0` and `stream.add R0.w` encoded to the same word.
2. **Found while verifying the round trip** — the disassembler rendered the suffix on the
   *chunk*, not the element register: `stream.add R0, [R1]+4.l, R2`. That text was not
   reassemblable to its own word, so it would have failed the round trip even after fixing
   #1. Verifying the round trip is what surfaced it.
3. **Found by probing the sibling op** — `stream.setp R0.w, 128` produced the *same word* as
   without the suffix. §3.4 gives `setp` no element-width field, so it is now refused with a
   sentence while the legal stride form still encodes exactly.

That is the **third** silent-input-discard in one file's scope, after `add PC, ...`. All three
shared a signature: an operand accepted, parsed, and dropped without a diagnostic. The
technique that found the third — test the sibling operation of the one you are fixing — is
worth keeping alongside the reserved-field sweep method.

### Process failures this session, recorded rather than tidied

- The Lead published **177** for a suite that was **348**, from a partial capture during
  concurrent writes, and reported it as complete.
- The Lead's dispatch of task-18 was **never delivered** by the message channel; the task sat
  unclaimed while the Lead believed it sent. Found only by re-running the width check on the
  current binary and seeing the bug still live.
- `rtl-primitives` ran mutation tests **in place** on a shared tree, transiently corrupting
  modules another teammate was compiling. The Lead's miss for not stating where mutation
  testing may run; the rule is now written down.
- The Lead deleted `.zig-cache` while background `zig` processes held it, hanging a build for
  eleven minutes with a zero-byte output file. Recovered by killing the stragglers and
  rebuilding.
- The RTL stream testbench failed 117/309 and `verifier` reported it **neither way**, because
  the failure signature pointed at the harness. That restraint was correct: the harness was
  testing address aliasing rather than atomicity, and fixing the design rather than the
  harness then exposed a genuine per-lane `add` bug.

The through-line: **a green signal is only as good as the claim it is attached to.** Fourteen
defects this session were found by executing something, and none by reading a summary.

### F16: stale absence claims survived the phase that falsified them

Found while answering "how far along are we?" by measuring the roadmap against the code, rather
than by recalling it. Phase 4 landed — `rtl/` exists, lints clean, three testbenches pass — but
four documents still asserted the opposite:

- `docs/fidelity.md` §4: "`rtl/` SystemVerilog — **Does not exist.** No directory, no file."
- `docs/fidelity.md` §2 table: RTL row "**Not started**", evidence `ls rtl/` -> "No such directory".
- `docs/fpga-prototyping.md`: "There is **no `rtl/` directory**", and the prerequisite table row
  "RTL source — `ls rtl/` — **No such directory.**"
- `docs/fpga-prototyping.md` §6: "**Phase 4 is NOT STARTED.** No `rtl/` directory exists."

The `Verilator not installed` rows are a distinct and more interesting failure. They were
recorded as `command -v verilator` -> nothing, which **is** what that command returns — because
Verilator was installed to `~/.local/verilator/bin`, which is not on `PATH`. The check was
truthful about the command and wrong about the world. A negative result from a check that cannot
succeed is not evidence of absence; it is evidence of a bad check. Both rows are now recorded as
installed, with the misleading-check mechanism written down so the next person does not
"correct" it back.

This is the same class as the RTL header version strings corrected earlier the same session:
a statement was true when written, a later change falsified it, and nothing re-read the
statement. Documentation that names a phase as "not started" needs to be revisited by the
phase that starts it. Nothing enforces that today.

Also corrected: `docs/fidelity.md`'s legend had no category for lint-clean-but-unsynthesized
RTL, so the new table row used a label the legend did not define. Added
**Simulation-verified spec**, defined as weaker than a software model for correctness claims
because no physical implementation exists to measure.
