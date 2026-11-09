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
`~/.local/zig/zig build test` -> **49/49 steps succeeded, 555/555 tests passed, exit 0**.
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
- RTL (Phase 4) **is written, lint-clean, and now synthesized**. `rtl/pkg/celeris64_pkg.sv`,
  `regfile.sv`, `alu.sv`, `stream_engine.sv`, `select_unit.sv`, `field_unit.sv`,
  `core.sv`, `accel.sv`, plus three testbenches under `rtl/tb/`. Verilator 5.49 was
  installed via a prebuilt manylinux wheel into `~/.local/verilator` (no sudo, no
  source build). Whole-tree lint is clean and the testbenches run real assertions;
  see `rtl/CROSSCHECK.md`.
  **Synthesis works** (`zig build synth`, `tools/rtl-synth.sh`): 42,775 cells in
  Yosys's generic flow, and 22,069 cells mapped to iCE40 primitives (15,076 LUT4,
  4,924 carry, 2,063 flip-flops), flattened, 0 problems. That last figure exceeds an
  iCE40 HX8K (7,680 LUT4s), so the design does not fit the smallest plausible target.
  **It is still not timing-closed, not placed, not routed, and has no known clock
  frequency.** A cell count is not a timing result. No document may claim a clock
  frequency, a critical path, or an area-per-technology figure.
  Getting here needed `sv2v`: Yosys's Verilog frontend rejects `return` inside a
  function (which the package uses throughout) and rejects a part-select applied
  directly to a function call. Verilator accepts both. One such part-select existed
  in `rtl/stream_engine.sv` and was rewritten as an explicit width cast, which is why
  the design now converts and synthesizes at all.
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
~/.local/zig/zig build test     # 49/49 steps, 555/555 tests, exit 0
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

### Session close: 452/452, all gates green
Final state, every figure independently re-derived by the Lead on a clean-room tree
(`rm -rf .zig-cache zig-out`) and summed from the individual roots rather than read off a
headline. The count has moved three times as work landed — **442**, then **444** (F17's two
tests), then **452** (the round-trip fuzzer's eight) — and each figure was correct for the tree
it describes.

```
zig build        -> 0
zig build test   -> 39/39 steps, 452/452 tests, exit 0   (20 roots, summed = 452)
zig build bench  -> 0   (every line says "simulated")
zig build audit  -> 0   (9/9 reserved fields rejected when explicitly set; 1 exemption)
zig build live-check -> 0   (232 recorded facts re-derived from the current binary)
verilator --lint-only -Wall --top-module core <whole rtl/> -> 0 warnings
rtl/tb/alu_tb.sv    -> 80/80      (re-measured this round)
rtl/tb/stream_tb.sv -> 348/348, atomicity holds   (was 314; see F31 below)
rtl/tb/core_tb.sv   -> 159/159   (re-measured this round)
rtl/CROSSCHECK.md   -> 4/4 programs agree with the Zig simulator
grep -rn MUTANT rtl/ -> nothing
```

> **F31 count correction, measured.** The `314/314` line above was an arithmetic
> carried across sessions. Both vacuous checks F31 removed were *counting* toward
> it, so the figure was inflated by assertions that could not fail. After the fix,
> built and run on this host: **`stream_tb` 348 assertions, 0 failures, exit 0**;
> `alu_tb` 80/80; `core_tb` 159/159. The rise from 314 to 348 is the point — the
> two tautologies were replaced by four real assertions (a two-run signed-vs-
> unsigned status comparison, and three consequences of an oversized chunk). The
> replacement was mutation-tested: forcing the checked signal to `1'b0` produces
> `FAIL: §3.4 oversized chunk reports chunk_too_large: got 0 expected 1` and exit 1.

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

### F17: the benchmark streamed over its own code, and no test could notice

Found while writing `docs/comparison.md`, which forced the real number to be re-read against the
source rather than recalled. `docs/fidelity.md` §3.4 quotes `stream batch: 4 simulated
instructions`, but `zig build bench` printed **3**. The first instinct was a stale quote. It was
not.

**The defect.** Both benchmark programs set their stream pointer to address 0:

```zig
try words.append(arena, vm.encode(0x19, 1, 0, vm.aluOperand(0, .full, 0))); // R1 = 0
```

Address 0 is the program's own first instruction. `stream.add` then added the addend to the
addend itself across the instruction words while the program ran:

- **batch** (`chunk = 8`, 8-byte elements) covers bytes 0..63 — all four of its words, including
  its `halt` at byte 24. The `halt` word `0x0100000000000000` became `0x0100000000000005`, which
  the decoder correctly refuses ("a zero opcode with stray bits set"), so the run ended one
  instruction early.
- **scalar** (`chunk = 1`, 8-byte elements) covers bytes 0..47 and stops before its `halt` at
  byte 80. It corrupts its own instructions but still halts, so its count of 11 was right by luck.

Proven directly, not inferred: stepping the program showed `word[3] before stream =
0x0100000000000000`, `after = 0x0100000000000005`.

**Which number was wrong.** Git archaeology settled it. `bench.zig` was introduced in `40e0531`
and `R1 = 0` was in it from the start; running `zig build bench` in a worktree at that exact
commit prints **3**. So the benchmark never printed 4: `docs/fidelity.md` recorded the value the
program was *supposed* to produce, in the same commit batch that failed to produce it, one second
apart. The doc described the intent; the code disagreed; nobody ran the two against each other.

**Why nothing caught it.** Every existing assertion was relational:

```zig
try testing.expect(results.batch.instructions > 0);
try testing.expect(results.batch.instructions < results.scalar.instructions);
```

`3 < 11` passes exactly as happily as `4 < 11`. **No test asserted a count against a number.** A
program that silently truncated its own execution looked identical to a correct one, because the
only thing being checked was an inequality between two quantities that had both been distorted.

The fix sets the stream pointer to `data_base` (`1 << 12`), past any program these benchmarks
build. Batch now reports 4, matching the doc.

**Two tests added, and both are proven to fire.** Reverting `batchWords` to address 0 in a
throwaway copy fails them with `expected 4, found 3` and a self-modification byte mismatch.

The second test deserves a note. Its first version rebuilt the batch program inline instead of
calling `batchWords`, and it did **not** fire under mutation: it was testing a hand-copy of the
program, so the real builder could regress while the test stayed green — the same trap, one level
up. It now runs the actual builders, which is why `batchWords`/`scalarWords` are split out from
`batchAdd`/`scalarLoop` at all. A test that duplicates the thing it guards guards nothing.

**The pattern.** This is the first defect this session whose wrong value was in the *docs* and
whose *code* was the liar — every earlier one was the reverse. It is also the first found by
noticing two numbers disagree, rather than by running something new. Both numbers existed,
printed by the same repository, for the entire life of the project; nothing compared them.

### F18: "never been synthesized" was true for exactly as long as nobody tried

Same class as F16, caught the same way and on the same day. The repository asserted in **8
files, 15 places** that the RTL had never been synthesized:

- `docs/STATUS.md`: "This RTL has never been synthesized ... `yosys` is absent."
- `docs/fidelity.md` §4 heading: "RTL exists and is lint-verified; synthesis has not started"
- `README.md`: "RTL is written and lint-clean, but has never been synthesized or timing-closed"
- `rtl/CROSSCHECK.md` (three places), `tests/rtl_checks.md` (three places)
- `rtl/tb/alu_tb.sv`, `rtl/tb/core_tb.sv` — testbench messages printed **at runtime**

The claim was true when written, and "`yosys` is absent" was true at the time. It stopped being
true when the OSS CAD Suite was installed to `~/.local/oss-cad-suite` earlier in the same session.
Nobody re-read the sentences, because nothing links "I installed a toolchain" to "a document says
the toolchain is absent."

**What actually blocked synthesis was not toolchain absence but one line of source.**
`rtl/stream_engine.sv` contained:

```systemverilog
lane_msk_q = width_mask(elem_width_q)[BYTE_LANES-1:0];
```

a part-select applied directly to a function call. Verilator accepts this; Yosys's Verilog frontend
rejects it with `syntax error, unexpected '['`. The package also uses `return` inside functions
throughout, which Yosys rejects and which needs `sv2v` to lower. Both blockers were **in the
source**, not in the tooling, and both were invisible while the only tool ever run was Verilator —
a linter that accepts more than a synthesizer does.

The fix is one line: `lane_msk_q = BYTE_LANES'(width_mask(elem_width_q));` — an explicit width
cast. Verilator stayed at 0 warnings; the three testbenches re-ran at 80/80, 314/314 and 159/159;
and the whole design then converted with `sv2v` and synthesized with Yosys.

**The pattern, and why it keeps recurring.** F16, F17 and F18 are one defect wearing three hats:
a statement true at the time it was written, falsified by later work, and never re-read. Nothing in
this repository connects a change to the documents that deny it. F17 was caught because two numbers
disagreed and a human noticed; F18 because running a linter is not running a synthesizer and a
human noticed. Both were noticed by accident. There is no mechanism here that would have caught
either, and "we will remember to re-read the docs" is not a mechanism.

---

## F19–F30: twelve defects found by a differential fuzzer

F16–F18 were found by accident — two numbers disagreed, or a human re-read a sentence. **F19–F30
were found by running a program.** `tests/roundtrip_fuzz.zig` generates pseudo-random CLS64 words,
drives them through the disassembler and back through the assembler, and requires the original
word back. That is the contract's own `asm -> dis -> asm` byte-identity claim, tested on 20,000
generated words instead of on the handful of fixtures written to satisfy it.

**The fuzzer found twelve defects in its first hour.** Each is recorded below with a word that
reproduces it. Every one was verified by hand at the command line before being written down.

### How the fuzzer itself was wrong three times

Recorded first, because a fuzzer that lies is worse than no fuzzer.

1. **The first generator was nearly useless.** It OR'd a random 48-bit payload under a plausible
   opcode byte, so **19,458 of 20,000 words were rejected** by the decoder as having reserved bits
   set. Only **8** reached the encoders. It was a reject-path test wearing a round-trip label. The
   generator now builds each class from its own §3 layout, and the suite prints its coverage — now
   **11,592 words checked, 11,592 identical** — so this cannot silently regress.

2. **The first self-check could not fail.** `isSourceExpressible` filtered the words to test, and a
   *separate, duplicated* block counted why each was filtered. The two drifted within minutes: the
   counter mislabelled a `select`-with-`PC` word the predicate had already excluded, and reported it
   as "unexpected". Both now call one classifier, `unexpressibleReason`, so they cannot disagree.

3. **A test that passed under mutation.** See F30's entry — the assembler has its own encoder, so a
   mutation in `decoder.encode` was invisible to a round-trip that never calls it. Fixed by adding
   an encoder-agreement test, which was itself first written against fixtures containing **no
   `field.*` instruction at all**, and therefore missed the same mutation a second time. Only after
   driving it from the generator did it fire.

### The twelve findings

Each entry names the word, what the tools do, and which is wrong.

| ID | Class | Word | Symptom |
|---|---|---|---|
| **F19** | contract gap | `0x43BAB89E3BCCB87F` | `stream.setp` decodes `rs1` and `operand[47:40]`, names neither, and §3.4 requires neither to be zero |
| **F20** | **code bug** | `0x70275000E82AE96C` | `.raw` omits `rd`/`rs1`; `0x70275000E82AE96C` → `0x70005000E82AE96C` |
| **F21** | **code bug** | `0x1012300000000005` | ALU immediate form carries a live `rs2`; two distinct words render identically |
| **F22** | **code bug** | `0x1912000000000005` | `mov` ignores `rs1`, which the encoder still writes |
| **F23** | **code bug** | `0x91120000000000F1` | `thread.join`/`yield` write `rd`/`rs1`, name neither |
| **F24** | code/contract | `0x30512D3D00000000` | `field.*` range unenforced in the decoder; `dis` emits text `asm` rejects |
| **F25** | contract gap | `0x304C3101D0000000` | `field.extract` carries `src2`, which §3.3 assigns to `insert` only |
| **F26** | **code bug** | `0x42A4E724BC300000` | `stream.fill` **renders** `rs2` but the assembler never **parses** it |
| **F27** | contract contradiction | `0x124E02000995E499` | §4's table says `PC` is readable; its next paragraph says it is an error |
| **F28** | code/contract | `0x5075000000000000` | `cap.*` odd pair register; decoder accepts what §3.5 forbids |
| **F29** | contract gap | `0x201D830000000000` | `compare` has no layout for `operand[47:36]`, which is silently dropped |
| **F30** | **code bug** | `0x20D1600000000800` | §3.2.1 reserves `compare`'s `[35:0]`; routed through the ALU check, `[27:0]` is enforced by nothing |

### The dominant pattern: a field written but never named

**F20, F21, F22, F23, F25, F26 and F29 are one defect wearing seven hats.** The encoder writes a
field; the renderer does not print it; the assembler re-creates it as zero. A byte-identical
round-trip is therefore impossible, and the loss is **silent** — exit 0, no diagnostic.

The clearest case is F21, because it does not merely drop a bit, it **rewrites one valid word into
a different valid word**:

```
0x1012300000000005   add R1, R2, 3, 5     renders "add R1, R2, 5"
0x1012000000000005   add R1, R2, 5        renders "add R1, R2, 5"
```

Two words, one text. Re-assembling that text always yields the second. §3.1 says "if `imm28 != 0`,
the instruction is immediate-form and `rs2` is ignored" — but *ignored on read* is not *free to
differ on write*. The disassembler comments that it prints only one form "because printing both
would produce text that re-assembles to a different word": it defends the rule on the read side
while the write side breaks it.

F26 is the sharpest, because the two tools **disagree in public**: `stream.fill R10.b, [R4]+468156, PC`
assembles with `PC` silently discarded, and disassembles back as `, R0` — a different register,
exit 0 throughout.

### The second pattern: the decoder accepting what the assembler refuses

**F24, F27, F28 and F30 share a shape**, and it is the F8 shape this repository has met twice
before: *the assembler is not the only entry point.* `run-bin` loads a blob and never consults the
assembler.

- **F27 is the worst of them, and it is a contract self-contradiction.** §4's index table lists
  `PC` (14) as "**readable**". The paragraph immediately below says `PC` in `rs1`/`rs2` "**is a
  diagnostic error**". The two cannot both hold. The decoder follows the table and accepts;
  the assembler follows the paragraph and refuses; **`run-bin` executes it**. So:

  ```
  $ celeris64 dis w.bin        -> mul R4.w, PC, -107617127     exit 0
  $ celeris64 asm w.dis        -> refused, exit 1
  $ celeris64 run-bin w.bin    -> halted after 2 instructions, exit 0
  ```

  The disassembler emits text it cannot itself re-assemble. This is the same defect shape as F4:
  a table contradicting its own paragraph.

- **F30 is F6 repeating for a different opcode.** §3.2.1 reserves `compare`'s `operand[35:0]` and
  requires rejection. `0x20` is routed through `aluOrErr`, which enforces the **ALU** rule on
  `[39:28]`. So `[27:0]` is checked by neither rule: `0x20D1600000000800` decodes as
  `compare R1, 2048 -> LR`, and the `0x800` vanishes on re-assembly. `decoder.zig`'s own comment
  for F6 says "the RTL had implemented it while the decoder had not" — the decoder is still
  behind, now for `compare`.

- **F24** is worth separating from F27 because execution is *safe*: `vm.zig` and the assembler both
  enforce `offset + width <= 64`, so a bad word faults at run time. Only the **disassembler** is
  wrong — it renders a word the rest of the system refuses.

### A structural finding: there are two encoders

`decoder.encode` has **no production caller**. The assembler builds words itself in
`Instruction.word()`, and `decoder.encode` is reached only from decoder tests. The round-trip
therefore exercises the assembler's encoder and *never* the decoder's.

This is how F30 stayed invisible from both sides at once: `Instruction.word()`'s
`.compare_select` branch encodes `compare` with the **ALU** layout, and `decoder.encode` routes to
`encodeAlu` too. They agree with each other perfectly, and both contradict §3.2.1.

The duplication also hid a mutation. Deleting `src2` from `decoder.encode`'s `encodeField` broke
**nothing** — the fuzzer could not see it, and my first encoder-agreement test could not either,
because the four committed cross-check programs contain no `field.*` instruction at all. Two
encoders that must agree need a test that says so, driven from a generator rather than from
fixtures written for some other purpose. That test now exists and is proven to fire.

### Mutation proof

Both halves are proven to catch a real fault, in a throwaway copy, never on the shared tree:

| Mutation | Result |
|---|---|
| `assembler.zig`: `field_width +% 1` | `ROUND-TRIP FAILURE at iteration 75` — word, render and outcome named |
| `decoder.zig`: `encodeField` drops `src2` | `generated 0x310B023730000000: decoder.encode() gives 0x310B023700000000`, exit 1 |

The second survived the fixtures-only version of the test. That failure is why the generator
drives it.

### What the fuzzer does NOT cover

- **Semantics.** It compares *encodings*, not results. It cannot see a VM that adds when it should
  subtract. The RTL cross-check in `rtl/CROSSCHECK.md` compares behaviour, on four programs.
- **The RTL.** Nothing here touches `rtl/`.
- **The holes it found.** F19–F30 are excluded from the round-trip set by `unexpressibleReason`,
  which is honest only because the exclusion is counted and asserted non-zero. **A green suite does
  not mean these are fixed** — it means they are recorded. Every excluded arm names its defect ID
  in the source.
- **Reserved opcodes outside `0x60`–`0x8F`**, and `cap.*`/`thread.*` execution.

### The lesson, and the mechanism

F16–F18 were one defect — a claim true when written, falsified later, never re-read — and the
conclusion recorded then was that nothing in this repository connects a change to the documents
that deny it, and that "we will remember to re-read the docs" is not a mechanism.

F19–F30 supply the mechanism. **A fuzzer is a machine for re-reading.** It does not know which
sentence is stale; it only knows that two implementations must agree, and it says so when they do
not. Twelve defects, none of which any existing test could see, all of them found by a program that
was written in one sitting and is now part of `zig build test`.

Twelve of the twelve were found by *running* code, never by reading it.

---

## F31: two RTL assertions that could never fail

Found by reading `rtl/tb/stream_tb.sv` while re-running the testbenches, not by any tool. Both
were counted in the `314/314` figure that has been quoted as evidence of RTL coverage since
task-14.

```systemverilog
// line 654, after the signed/unsigned compare split:
// "And they must not be the same value."
check1 ("§3.2.1 signed view != unsigned view", 1'b1, 1'b1);

// line 827:
check1("§3.4 oversized chunk reports chunk_too_large", se_chunk_too_large || 1'b1, 1'b1);
```

`1'b1` equals `1'b1`, and `anything || 1'b1` is always `1'b1`. **Neither check can fail**, whatever
the DUT does. They are not weak assertions; they are assertions in name only, and they inflated an
assertion count that `rtl/CROSSCHECK.md` §5.6 cites as proof the oversized-chunk refusal works:

> "A larger chunk is refused loudly on `chunk_too_large_o`; it is **never** silently truncated."

That sentence was supported by a tautology. The RTL may well behave exactly as described — but
until now nothing in this repository had tested it. **This is the same defect class as the F17
benchmark whose assertions were all relational**: a test that cannot fail is worse than no test,
because it is counted as evidence.

Both are now driven for real:

- The signed/unsigned check captures the two `su_status` values from two actual runs and compares
  them, so a collapse into one status enum fails.
- The oversized-chunk check issues `chunk = 20'hFFFFF` and asserts **three** independent things:
  `se_chunk_too_large` is high, **no byte of memory changed**, and the pointer did not move. The
  middle one is the claim §5.6 actually makes ("never silently truncated"), and it had never been
  asserted at all.

**Honest note on the counts.** The `314` figure was reached before this fix and included these two
vacuous checks. The estimate written here at the time was `314 − 2 + 4 = 316`. **That estimate was
wrong: the measured value is 348.** The testbench was subsequently built and run (`stream_tb`, 348
assertions, 0 failures, exit 0), and the replacement assertions were mutation-tested to confirm they
can fail. The `316` is left standing here rather than overwritten because the gap between it and
`348` — a derived count off by 32 — is itself the lesson below.

The general lesson, and it is the third time this repository has met it in one session: **a count of
assertions is not a measure of coverage.** F17's mutations all passed relational assertions; F31's
two checks passed unconditionally. Nothing here counts how many assertions *could* fail.

---

## OPEN, AT THE TIME OF WRITING: these fixes are UNVERIFIED

Recorded because an unverified fix presented as a fix is the exact defect this document exists to
catch.

The F31 edits to `rtl/tb/stream_tb.sv` and the F19–F30 work are now **closed**:

| Item | State |
|---|---|
| `tests/roundtrip_fuzz.zig`, `tests/crosscheck/` | **Verified** — 452/452 tests, 39/39 steps, on a clean rebuild |
| F19–F30 findings and their reproducing words | **Verified by hand** at the command line, one at a time |
| Mutation proofs (both halves) | **Verified** — each fired, in a throwaway copy |
| `rtl/tb/stream_tb.sv` F31 edits | **COMPILED AND RUN.** 348 assertions, 0 failures, exit 0 |
| `rtl/tb/core_tb.sv`, `rtl/tb/alu_tb.sv` | Both re-run and measured: `core_tb` **159/159**, `alu_tb` **80/80** |
| F31 replacement assertions can fail | **Proven by mutation** — forced input reported `got 0 expected 1`, exit 1 |
| Commit | **NOT MADE.** The tree is dirty |

**The `316` figure was wrong, and that is the finding.** It was arithmetic
(314 − 2 + 4) and the measured value is **348**. Deriving a test count instead of
running the testbench produced a number that was off by 32. The rule this
establishes: a test count is a measurement, never a calculation.

**Root cause of the ENOSPC, now identified.** It was not build output and not a
runaway process. Verilator 5.49 generates `VK_PCH_I_FAST = $(CFG_CXXFLAGS_PCH_I)
$(VM_PREFIX)__pch.h.fast$(CFG_GCH_IF_CLANG)`; on GCC `CFG_CXXFLAGS_PCH_I` is empty
by design, so the precompiled header name is passed as a **bare positional
argument** with no `-include`:

```
c++ -Os -I. ... Vstream_tb__pch.h.fast -c Vstream_tb.cpp
```

GCC finds no such source file, treats it as a linker input, then falls through to
parsing the real 104 MB `Vstream_tb__pch.h.fast.gch` as C++ **source**, emitting
tens of thousands of `stray '\5' in program` / `null character(s) ignored`
diagnostics per translation unit. That flood is the 8 GB. Each `-Mdir` also held
**two ~100 MB PCH files**.

The fix is one flag, verified: `-MAKEFLAGS "VK_PCH_I_FAST= VK_PCH_I_SLOW="`. With
it, `stream_tb` builds in **5.1 s** to a 0.57 MB binary, and the log is 4 KB.
Earlier attempts at `VM_PCH=0`, `CFG_CXXFLAGS_PCH_I=`, `VM_PCH_H=` and
`CFG_GCH_IF_CLANG=.gch` all failed — they address variables that do not carry the
stray argument. The `--lint-only` path was never affected (287-byte log, exit 0),
which is why the F31 edit passed lint while the binary build kept dying.




---

## F19–F30 fixed: contract v1.16

Every defect recorded at v1.15 is closed. Sorting them by what was actually wrong
— rather than by their assigned numbers — collapsed twelve findings into four fixes:

| Group | Findings | Fix |
|---|---|---|
| A field written but never named | F20, F21, F22, F23, F25, F26, F29 | `.raw opcode, operand, rd, rs1` preserves every bit |
| Decoder accepts what the assembler refuses | F24, F27 (+F23's `rs1`) | the check added **in the decoder**, not only the assembler |
| Contract silent on a field | F19 | §3.4 now names `setp`'s pointer and reserves `rs1`/`operand[47:40]` |
| Enforced by nothing | F30 | **retracted — not a defect** |

### Two recorded findings were wrong

This is the part worth keeping. Both were caught by verifying the *recorded words*
against the *recorded claims* before writing any fix.

**F30 is retracted.** It claimed §3.2.1 reserves `compare`'s `operand[35:0]`. But
§3.2.1 contains **no bit layout at all** — it defines only the status enum table.
`compare` correctly follows §3.1's ALU layout, and the recorded word
`0x20D1600000000800` was handled correctly all along: `zero[39:28] = 0` and
`imm28 = 0x800 = 2048`. The claim that `0x800` was "dropped" was false; `0x800`
*is* the immediate. Had this not been checked first, the "fix" would have added a
reservation that contradicts §3.1 and broken a valid instruction.

**F29 was misattributed.** It recorded a lost `trueReg` (bits `[36:32]`). The word
`0x201D830000000000` has `imm28 = 0`, so it is register form and `rs2 = 8` is a
legitimate source — nothing was lost there. The actually-lost field is the **§5
width suffix** (nibble `3` = `.b`), which `compare`'s renderer never emitted:
`...83...` → `...80...`. Same defect class, different field.

**F28 is not a defect.** `cap.load R7, R5` has a zero operand and decodes legally.
Only the assembler's §3.5 even-index rule refuses the odd `rs1`. The decoder
accepting a well-formed word from a blob is the correct behaviour.

### A VM defect found while fixing F19

`vm.zig`'s `stream.setp` wrote `st.rs1` as the pointer register, but `setp` names
its pointer with `rd` — the assembler emits `stream.setp R1, -16` as `rd=1, rs1=0`,
and §3.4 gives `setp` no `rs1`. So the instruction updated **R0** and left the named
pointer untouched. It was invisible because the one test fixture that covered it set
`rs1` by hand, which made the wrong register coincidentally correct. F19's decoder
check turned that fixture into a rejected word, which is how the VM bug surfaced.

### A test fixture was encoding an illegal word

The same fixture wrote the stride as `@bitCast(@as(i48, -16))`, sign-extending into
`operand[47:40]` and producing `0xFFFFFFFFFFF0`. §3.4 gives `[39:0]` to the stride and
reserves `[47:40]`, and the assembler never emits that shape. Masked to 40 bits.

### Verification

```
zig build test --summary all  -> 39/39 steps, 452/452 tests, exit 0   (clean rebuild)
alu_tb / stream_tb / core_tb  -> 80 / 348 / 159, 0 failures
cross-check programs          -> 4/4 byte-identical through dis -> asm
zig build audit               -> 9/9 reserved fields rejected
zig build bench               -> 0   (every line says "simulated")
zig build live-check          -> 232/232 facts reproduce
fuzzer                        -> checked=11592 identical=11592, rejected 1669 -> 3923
```

The fuzzer line is the strongest evidence the tightening is correct: **the same
11,592 expressible words still round-trip byte-identically, while the number of
words correctly refused rose from 1,669 to 3,923.** Rejections up, fidelity
unchanged — a fix that lost round-trip fidelity would show `identical` below
`checked`, and one that was too permissive would leave `rejected` flat.

---

## F32: the benchmark's two rows are the same shape (found while adding a density axis)

The task was to add an honest **encoding-density** axis — bits per operation against
RISC-V, x86-64 and ARM64 — since density is static and needs no silicon, unlike the
speed comparison `docs/comparison.md` correctly refuses to make.

The axis could not be measured: **no ARM or RISC-V toolchain is installed** on this
host (`aarch64-linux-gnu-gcc` and `riscv64-linux-gnu-gcc` absent; only
`x86_64-unknown-linux-gnu` Rust std present). Stating counts from memory would have
produced exactly the fabricated figure this repository forbids, so the axis is
recorded as **unmeasured** rather than added.

Checking the CLS64 column first turned up something worse.

### The finding

`docs/comparison.md` §2 and `benchmarks/bench.zig` both describe the CLS64 scalar row
as *"an explicit software loop, one element per iteration"* and *"`chunk` separate
load/add/store triples: no fused engine, one element each."*

**Both sentences are false.** `scalarWords` emits `vm.encode(0x40, 0, 1,
streamOperand(2, 1, .full))`. Opcode `0x40` is `stream.add` — the fused engine — and
the batch path emits the identical word with `chunk = 8`. Neither program contains a
software loop; neither contains an unfused triple.

Both programs are `mov`, `mov`, N × `stream.add`, `halt`:

| Path | N | Retired | Formula |
|---|---|---|---|
| batch | 1 (`chunk = 8`) | 4 | `3 + 1` |
| scalar | 8 (`chunk = 1`) | 11 | `3 + chunk` |

At `chunk = 1` both paths retire the **same 4 instructions** — the "scalar" row is the
batch row with a smaller chunk. The published 4-vs-11 gap is therefore a property of
call granularity *in the benchmark source*, not of the stream engine, because the
engine is on both sides.

§4's "collapse finding" does not cover this. That finding is about C and Rust, where
two genuinely different bodies had to be kept from fusing; here there is only one
body, issued a different number of times, and no guard could create a difference that
the program does not contain.

### Why it cannot simply be fixed

The honest fix is to write the element-at-a-time path with load and store
instructions, as the C and Rust scalar paths do. **CLS64 has no general-purpose load
or store.** Every memory-touching opcode is `stream.add`/`copy`/`fill` (fused,
§3.4) or `cap.load`/`cap.store` (capabilities, decode-only per §3.5 v1.12).
`mov R5, [R4]` is rejected by the assembler; there is no memory operand form.

So a single-element fetch-modify-write, expressed without the stream engine, **is not
expressible in this ISA at all.** This is the stronger finding: the architecture's
central claim is that `stream.*` removes loop overhead, but the comparison offered as
evidence cannot exhibit a non-`stream.*` baseline, because the ISA provides no way to
write one.

### What was done

- `docs/comparison.md` gains §7 stating the finding, the arithmetic, the toolchain
  gap, and an explicit may-say / may-not-say list.
- `docs/fidelity.md` §3.4 is annotated so the 4/11 figures are not read as an
  engine-versus-loop result. The counts remain accurate; what changed is what they
  may be taken to mean.
- `benchmarks/bench.zig`, `workload.c` and `workload.rs` have the false claims
  corrected at the source. The C and Rust programs were recompiled and re-run to
  confirm they are unaffected (batch 1.89 ns / 1.72 ns, scalar 8.30 ns / 7.08 ns,
  both equivalence checks passing).

### What may and may not be said

- **May be said:** the simulator retires 4 instructions for `chunk = 8` and 11 for
  eight `chunk = 1` issues of the same instruction.
- **May not be said:** that this is a speedup, that it is the stream engine's
  advantage, or that it evidences §1.2's claim about loop overhead.
- **Not measured:** encoding density against any other ISA. No toolchain.

**Status: open.** Closing it needs either a load/store instruction in the contract, or
a restatement of §2 naming the two rows for what they are.

### CLOSED (v1.18) — the contract route, not the restatement route

The finding offered two ways out. This closes it by the first: **the load/store
instruction was added to the contract** in v1.17 (`load` 0x1A, `store` 0x1B, and
the conditional `branch` 0x05 that a loop also needs). With those, the
"not expressible in this ISA at all" paragraph above is no longer true, and the
scalar row can finally be written the way the other three ISAs' rows are.

`src/crossarch.zig` `cls64Program`'s scalar arm is now a real 13-word per-element
loop, not eight `chunk = 1` issues of the fused engine. The measured change:

| Row | Retired, before | Retired, after | Bytes, before | Bytes, after |
|---|---|---|---|---|
| CLS64 batch | 4 | 4 (unchanged) | 32 | 32 (unchanged) |
| **CLS64 scalar** | **11** | **68** | **88** | **544** |

**CLS64 now trails the scalar row instead of leading it** — 68 against RISC-V's
55, AArch64's 61 and x86-64's 60. That is the correct outcome and the reason the
fix is worth having: the old 11 was the fused engine's number wearing a scalar
label, and a comparison in which the subject's own row is not what its label says
is not a comparison. The batch row keeps CLS64's one genuine result (4 retired
against 52–60) and is untouched.

What may now be said, replacing the may-say list above:

- **May be said:** written as a per-element loop, CLS64's scalar row retires MORE
  instructions than any of the other three, because every CLS64 instruction is a
  fixed 8 bytes and its loop needs five instructions of bookkeeping per element.
- **May be said:** CLS64's fused engine retires 4 instructions for the same
  workload, and 8:1 is now a real algorithmic difference between two different
  programs rather than an artefact of call granularity.
- **May not be said:** anything about speed, cycles or silicon. The axis is still
  retired instructions in a simulator, and the encoding-density axis remains
  unmeasured for want of an ARM/RISC-V toolchain.

Verified: `zig build crossarch` prints all 8 rows with no `!!` warnings, and the
two "computes 5 in all 8 elements" tests pass for both shapes.

---

## F33: four ISAs executed by one measurement loop

**What was asked:** extend the VM so all architectures run under the same clock, for
apples-to-apples comparison.

**What was done, and the one part of that request that was declined.** The VM was
extended to execute real machine code for three more ISAs — RISC-V RV64I, AArch64 and
x86-64 — inside one shared counting loop, so that CLS64's column is now measured the
same way as the others instead of being a counter compared against wall-clock
nanoseconds. The "same clock" part was **not** implemented, and that was a deliberate
refusal: assigning a cycle cost per instruction would mean inventing a
microarchitecture for CPUs that are not present, and CLS64's own number would come
from the same invention. The result would look like a fair comparison while being a
statement about the model. `src/isaharness.zig` reports retired instructions and
encoded bytes, has no field for any timing quantity, and a test fails if one is added.

```
zig build crossarch
```

| ISA | shape | retired | code bytes | bytes/insn |
|---|---|---|---|---|
| Celeris-64 CLS64 | batch | 4 | 32 | 8.00 |
| RISC-V RV64I | batch | 54 | 216 | 4.00 |
| AArch64 A64 | batch | 60 | 240 | 4.00 |
| x86-64 | batch | 52 | 167 | 3.21 |
| Celeris-64 CLS64 | scalar | 11 | 88 | 8.00 |
| RISC-V RV64I | scalar | 55 | 220 | 4.00 |
| AArch64 A64 | scalar | 61 | 244 | 4.00 |
| x86-64 | scalar | 60 | 207 | 3.45 |

Every program's resulting memory is compared against the others, so a program that
ran but computed the wrong thing cannot appear as an equal participant.

### New code, and how it is verified

Roughly 1,800 lines of new decoder and interpreter code across five files. That is a
large amount of new risk, so none of it is verified against itself:
**`llvm-mc` is the oracle.** The encodings pasted into the tests were produced by
LLVM's integrated assembler and checked byte-for-byte, for all three ISAs.

This caught **three real bugs that every self-consistency test had passed**:

1. **RISC-V and AArch64 immediates** were sign-extended by shifting up to put the
   sign bit at bit 31 and then never shifted back. A `-8` branch offset decoded as
   `4194304`. Nothing in the ISA-execution tests noticed, because the same wrong
   understanding was in both the encoder and the decoder; only the oracle's
   independent bytes exposed it.
2. **x86-64 opcode `0xC7`** was grouped with the group-1 ALU opcodes. It is group 11
   — `MOV r/m, imm` — and its `reg` field is an opcode extension, not an ALU
   selector. `movq $5, %rax` therefore executed as an `ADD` and stored 5 instead of
   moving it.
3. **x86-64 SIB addressing** read a `disp32` for every `mod == 0` SIB operand. A
   `disp32` is present only when the SIB base field is 5, so the decoder consumed
   four bytes that did not exist and corrupted every following instruction.

Each is now pinned by a test that fails when the bug is reintroduced by mutation.
The store path was mutation-tested: replacing the stored register with the wrong one
makes both the unit test and the oracle test fail.

Two further bugs were found in the *programs* rather than the decoders, by the
memory-equality check: an x86-64 `jne` with `rel8 = -15` where `-18` was correct
(which ran the loop 11 times instead of 8), and a RISC-V `addi` used to load the
address `4096`, which exceeds `addi`'s signed 12-bit immediate — the encoder
truncated it to 0 and the program streamed over its own code. The second is the same
class as F17.

### A caveat that must travel with the table

CLS64's "scalar" row is **the same instruction at a lower granularity**, not a
second shape — §7's F32 finding. The other three ISAs' scalar rows are genuine
loops. **The CLS64 scalar row is therefore not comparable to theirs**, and putting it
in the same table invites exactly the reading that F32 forbids. It is included for
completeness and labelled in the report.

### Verification

```
zig build test --summary all  -> 49/49 steps, 555/555 tests, exit 0  (clean rebuild)
zig build crossarch           -> 8 rows, all computing the correct result
llvm-mc oracle tests          -> 3 ISAs, encodings checked byte-for-byte
```

Test count rose from 453 to 555: 43 in `crossarch.zig` plus 59 in the four ISA roots.

---

## F34: the ISA could not express a loop (v1.17)

**The request was to finish the core ISA. Finishing it revealed that it was not
merely incomplete — it could not express an ordinary program.**

Every revision through v1.16 defined `jump`, `call` and `ret`, **all
unconditional**, and nothing else. So:

- **No loop was expressible.** `compare` + `select` implement branchless *value*
  selection, which is the architecture's stated design, but `select` chooses a
  value, never a control-flow target.
- **No scalar memory access was expressible.** The only memory-touching opcodes were
  the fused `stream.*` engine and the decode-only `cap.*`. `mov R5, [R4]` was
  rejected by the assembler because no memory operand form existed.

Both facts were already recorded as *symptoms* without their cause being named:
`benchmarks/bench.zig`'s "element-by-element loop" was unrolled by the **Zig
generator at build time** because the ISA could not express the loop, and F32's two
"shapes" were one instruction at two chunk sizes because no second shape could be
written. The cause of both was this gap.

### What was added

| Opcode | Mnemonic | Why this form |
|---|---|---|
| `0x05` | `branch rs1, [MATCH], offset` | Tests the **status enum `compare` already produces**, so no flags register is introduced and the predication design is unchanged. Offset is **relative to the branch itself**, because a compiler can emit a relative offset for a forward reference without knowing the layout. |
| `0x1A` | `load rd, [rs1+off]` | Scalar counterpart to the fused engine. |
| `0x1B` | `store rs2, [rs1+off]` | No post-increment: auto-increment belongs to the engine, and a scalar access that moved its own base would be unusable for random access. |

### Four defects found while implementing it, three by the fuzzer in one run

1. **Every loop ran forever.** The assembler's `.control` encoder arm handled only
   `jump`/`call`, so a `branch` assembled to **operand 0** — testing `EQUAL` against
   an offset of 0, always falling through. The first loop written for CLS64 did not
   halt. Found by running it.
2. **"Validated but dropped" is not a rule.** `branch`'s width nibble was first
   specified as "checked for validity but not used". The fuzzer disproved it
   immediately: a word with a non-zero nibble decoded, **lost four bits on
   re-emit**, and re-assembled to a different word — the F20–F26 class exactly. The
   field is now reserved-and-rejected. *A field that is validated but dropped is
   worse than an undocumented one, because the validation implies it is handled.*
3. **The decoder accepted an unaligned branch offset** that the assembler refused.
   Fuzzer-found. Since every instruction is 8 bytes, such an offset cannot name an
   instruction boundary — a blob could branch into the middle of one. The F24/F27
   two-layer shape, now enforced in the decoder as well.
4. **`load`/`store` accepted a surplus operand and silently discarded it.** Found by
   hand after the other three. `load R6, [R1+0], R7` assembled and dropped `R7` —
   the F12/F19 class.

### Verification

```
zig build test --summary all  -> 49/49 steps, 556/556 tests, exit 0   (clean rebuild)
fuzzer                        -> checked=11839 identical=11839  (up from 11592)
end-to-end loop               -> sums 8 loaded elements to 180, halts in 63 instructions
round trip                    -> the new instructions are byte-identical through dis -> asm
```

The end-to-end loop is the proof that matters: it uses `compare` to produce the
status, `branch` to test it, and `load` to fetch each element, and it produces the
correct sum. Before v1.17 that program could not be written at all.

### What this does NOT close

`cap.*` remains decode-only (§3.5 v1.12: the register pair has no `length` bit
position, so a capability cannot be reconstructed — a §6 redesign, not a bug fix).
The accelerators remain unwired: `matrix.zig`, `fft.zig` and `codec.zig` are
imported by **no other file**, so `0x60`–`0x8F` decodes to an opaque payload and
executes nothing. That is the next piece of the core before the example suite.

*(Corrected in v1.18: this paragraph previously ended "and it is why the
cross-architecture table's CLS64 row still cannot be compared fairly." That is no
longer true — F32 is closed above by rewriting the CLS64 scalar row as a real loop.
The unwired accelerators are still a real gap, but they no longer block the
comparison, and the CLS64 row is now comparable and worst-of-four on it.)*

---

## F35: labels (v1.18) — and two numbers that did not survive re-derivation

Branch and jump targets were numeric byte offsets only, so a loop written by hand
required counting instructions and writing the magic number; any edit above the
target silently changed its meaning. `assembleSource` now resolves labels in three
passes (collect definitions and reject duplicates, assemble while recording
unresolved references, then patch now that every address is known). `branch` gets a
PC-relative signed 28-bit delta **from the branch instruction itself** (§3.0.1);
`jump`/`call` get an absolute 48-bit address. `splitLabel` is shared by passes 1
and 2 so the two cannot drift about which lines emit an instruction.

### Two corrections, recorded in place

Two numbers were inherited from the previous session and both were wrong. Neither
was a defect in the label implementation — which is why re-deriving them mattered,
since either could have been "fixed" by bending the product to match a wrong
number:

1. **The handoff's byte-identity claim holds, but the by-hand numbers behind it are
   easy to get wrong — demonstrated by getting them wrong.** The handoff states the
   label program "assembles to the same 12 words as the numeric-offset equivalent"
   and that both halt after 63 instructions. It never prints that numeric program,
   so the claim was reproduced rather than trusted.

   The first reproduction **faulted**, which briefly looked like a label bug. It was
   not: the transcribed program used a branch delta of `80` and `jump 24`, sending
   the exit past the 96-byte image and the back-edge to the setup word instead of
   the loop head. The label path assembles to a branch delta of `48` (branch at
   address 40 → `done` at 88) and an absolute jump of `32` (`loop`, instruction 4).

   So the finding is narrower than it first appeared and is about the *old*
   workflow, not a defect: two hand-counted numbers produced a program that does not
   run, on the first attempt, by an agent that had just read the encoding rules.
   Against the corrected numeric program the images are byte-identical (`cmp` clean)
   and both halt after 63 simulated instructions — the label implementation is
   correct and the handoff's claim is confirmed.
2. **The pre-existing test asserted `-16` for the backward branch; the correct value
   is `-8`.** The failing test carried over from the previous session expected `-16`.
   The encoder computes `target_addr - branch_addr`, so for `top: nop; branch
   R0,[EQUAL],top` the branch sits at address 8 and `top` at address 0, giving
   `0 - 8 = -8`. Re-deriving it from the encoder rather than from the neighbouring
   test changed the expected value. The assertion is load-bearing: setting it back
   to `-16` fails with `expected -16, found -8`. (The `-16` looks like it came from
   the target-minus-next-instruction convention, which this ISA does not use.)

   *A process note worth keeping: an intermediate draft of this section attributed
   both wrong numbers to the handoff. `-16` appears nowhere in HANDOFF.md, and the
   handoff never printed a numeric program at all. The two wrong numbers were the
   previous session's test data and this session's own first transcription. The
   attribution was corrected before this text was committed, which is the only
   reason the section is not itself a fabricated finding.*

### A trap worth recording, because the obvious fix is the dangerous one

The test helper returns `Program`, **not** the `[]u64` slice that seemed natural:

- `assembleSource` returns a *value copy* of its `ArenaAllocator`, and that copy
  shares the same node list. Deinit-ing both the returned `Program` and the
  assembler therefore frees one list twice — a double free on the **success** path,
  which aborts. The pre-existing comment at the "line that is only a label" test
  records the same trap.
- Returning `prog.words` instead is *also* unsafe, more subtly: it is the live
  `ArrayList` buffer, and Zig 0.17's `ArenaAllocator` can **move** an existing
  allocation when it grows the same node. A stale slice then reads back `0xAAAA…`
  poison rather than the word. "The words are arena-owned" does not make a slice
  safe.

The helper frees the arena exactly once on both the success and failure paths.

### Verification

```
zig build test (cold cache)   -> 49/49 steps, 570/570 tests, exit 0
labels filter                 -> 8/8 pass
byte identity                 -> label image vs corrected numeric image, cmp clean
decoder fuzz round trip       -> checked=11839 identical=11839, 0 mismatches
reserved-field audit          -> 9/9 enforcement points, all 9 rejected when set
live-check                    -> all 232 recorded facts still reproduce
```

---

## F36: the §3.6 accelerator table names operands the encoding does not carry

**Found** while scoping the last open core gap (wiring `0x60`–`0x8F` into the VM),
by grepping the contract rather than by running anything. **Status: open — the gap
is confirmed; the refusal behaviour it implies was being implemented at the time of
writing and is not yet verified.**

### The gap

`docs/isa-encoding.md` §3.6 (Amendment 1.1) fixes the accelerator operand layout
and assigns all 13 operations. The layout is:

```
rs2[47:44] | rs3[43:40] | reserved[39:32] | count[31:0]
```

Every operand a §3.6 operation can receive must be reachable from that word: two
registers, one optional third register, and a 32-bit count. Four operations need
something that is not there.

- **`matrix.det` (`0x60`), `matrix.invert` (`0x61`), `matrix.mul` (`0x62`)** all call
  a model function (`matrix.determinant`, `matrix.invert`, `matrix.multiply`) that
  takes a matrix whose **dimension** must be known. The word carries no dimension,
  and `takes_count` is false for all three, so `count` is not even available as a
  candidate. The spec does not say where `n` comes from, and does not record that it
  is missing.
- **`matrix.transform` (`0x63`)** is the subtle one. Its row reads
  *"`matrix.transformSoA(xs, ys, zs, m)`; the three streams are consecutive from
  `rs1`, `count` is elements per stream"*. So `count` is defined — but the model
  also takes a rigid-body matrix `m`, and the row never says where `m` comes from.
  A defined operand next to an undefined one reads as if the row were complete.
- **`codec.compress` (`0x80`) / `codec.decompress` (`0x81`)** take an input **and an
  output** buffer. `decompress`'s own doc comment says *"`out` must be large enough"*,
  but neither the word nor §3.6 names the output address or its size. `rd`, `rs1` and
  `count` are all already spoken for.

And one ambiguity that reaches **all thirteen** operations, found during
implementation by the teammate wiring this (their analysis, verified here):

- **`count`'s source and unit are both undefined for a caller that omits `count=N`.**
  §3.6 line 490 says: *"`count[31:0]` — element or byte count, unsigned. `0` means
  'derive the count from the destination register', which is the form the assembler
  emits when no count is written."* That sentence is unconditional — it applies to
  every accelerator op, and the assembler's `takes_count = false` merely means the
  *text* may not spell `count=N`. Two things are then missing:

  - **Source.** "Derive from the destination register" is the only occurrence of
    "derive" in the contract, and it never says what `rd` holds at that moment.
    (`R0` is not `ZERO`: `registers.zig:90` records index 0 as "a real, writable
    register", with `ZERO` a separate system register — so `rd = R0` is ordinary
    and the ambiguity is not resolved by the hardwired-zero rule.)
  - **Unit.** The same table calls the field an "element or byte count", then says
    "element count" for the fft rows, "elements **per stream**" for `transform`, and
    the codec ops are byte-oriented. For fft the difference is not cosmetic: a
    complex element is 16 bytes, so a 16-vs-256 reading of one field is a 16×
    error in a buffer length.

  There *is* precedent for reading `rd` as an input — `stream.setp` (`0x42`/`0x43`)
  reads it (`src/vm.zig:402`, `408`, `418`) — but it does not transfer. `setp`'s `rd`
  genuinely *names* the pointer register it updates, so its old value is the operand.
  For an accelerator op `rd` is the **result** register, so treating it as the count
  source imposes a calling convention in which a program must pre-load its own
  result register with a length. That is a contract decision, and the contract has
  not made it.

### Why this is a finding worth recording rather than a detail to paper over

The obvious way to make all 13 execute is to pick a convention — say `n` comes from
`rs2`, or `n` is always 4, or the output buffer starts right after the input. Every
one of those produces a **plausible-looking numeric result** from an arbitrary guess.
For a matrix determinant that is a wrong number the simulator would confidently
report, and the repository's whole position on fabricated results (`docs/fidelity.md`,
F32) is that an honest refusal beats a confident wrong answer.

There is a second reason: `count` is documented as *"`0` means derive the count from
the destination register"* (§3.6). That same convention is the natural place a
dimension would live, but it is not stated for the matrix operations, and inventing
it here would be fixing the contract in an implementation file — where the RTL, the
disassembler and any future backend would not see it.

### What may and may not be said

- **May be said:** the §3.6 table is complete about *operand names* and incomplete
  about *address and shape arithmetic* and about *the count's source and unit*; on
  the strict reading, **none** of the thirteen operations can be executed from the
  information the encoding carries.
- **May be said:** the accelerator range assembles, disassembles and round-trips
  byte-identically — verified, including `matrix.det` and `codec.compress`. The gap
  is execution semantics, not encoding.
- **May not be said:** that the accelerators "work". They do not execute. It is also
  not true that they are undecodable — `decoder.decode` returns a populated
  `.accelerator` payload for every one of them.
- **May not be said:** that `codec.fnv1a` is the "easy one that obviously works". It
  was the Lead's first pick for a proof-of-wiring test, on the assumption that a
  one-input one-result op has no shape problem. It has the count problem: nothing
  states where fnv1a's byte length comes from. That assumption is recorded here
  because it is the exact mistake this finding is about — reaching for the
  convention that makes the code run.

### What closing it needs

A §3.6 amendment stating, per operation: where each matrix dimension comes from,
where each output buffer comes from, and what `count = 0` means (which register, and
in what unit) — the same kind of amendment 1.1 already made for the operand layout.
That is a contract change on the scale of the one F32 needed, and like F32 it should
be made in the contract rather than in whichever component hits the problem first.

Until then the correct simulator behaviour is to **refuse all thirteen** with a
plain-language diagnostic that names the missing rule, and to keep a *reserved*
opcode byte (`0x60`–`0x8F` with no table row) faulting differently from a
*defined but unexecutable* one. The two are different findings and should not read
the same.

### F36 implementation status (v1.18) — refused, and verified

The refusal is implemented and verified. All thirteen §3.6 opcodes now reach
`refuseAccelerator` in `src/vm.zig` instead of the generic `execute` else arm; **none
executes.** Reserved bytes reach the same function and read differently, so
"defined but unexecutable" and "not in the table at all" are distinguishable by a
reader. Verified in the CLI, not only in-process — the defined case names the
operation (`the instruction "matrix.det"`) and the reserved case does not.

Properties asserted by test, because a refusal that half-executes is worse than one
that crashes: the refused word does **not** retire, PC does **not** advance past it,
and no register is written. `cap.check` immediately after an accelerator word is
unaffected, so the arm does not disturb its neighbours.

**Two defects were found in review and fixed, both invisible to the unit tests and
both in the user-visible path** — which is the argument for running the CLI rather
than trusting a green suite:

1. **The refusal was silently truncated.** It rendered to exactly 1025 bytes and was
   cut mid-word at `docs/`. `main.zig:379` renders into a fixed `[1024]u8` and
   discards the overflow with `catch {}`, so the reader received a sentence that
   looked complete and was not. Fixed by tightening the prose to 723 bytes; a test
   now renders into a literal `[1024]u8` and requires a trailing period. Confirmed
   load-bearing by re-injecting the defect in a throwaway copy — the guard fails.
2. **The message said "which is not valid here".** That is the renderer's
   malformed-*operand* clause. Nothing was malformed: `matrix.det R1, R2` is a
   well-formed instruction whose semantics the contract declines to define. Telling
   the reader their operands are invalid sends them to fix an instruction that is
   not broken.

**A third defect was found and rejected before it shipped.** An attempt to improve
the reserved-byte phrasing (so it read as a description rather than as a mnemonic)
stored the new text in a function-local buffer via `bufPrint` and returned it inside
the `Diagnostic`, which outlives that frame. The reserved case rendered as
`the instruction ""` — an empty name, silently. Caught by the existing test, reverted,
and the original phrasing kept; the cosmetic gain was not worth a use-after-scope.
Recorded because it is the same silent-loss class as defect 1, committed by the same
review that found defect 1.

---

## F37: the decoder does not reject a reserved accelerator byte (F8 shape, again)

**Found** while implementing F36, by the teammate wiring it.

> **RESOLVED (amendment 1.20) — the decoder is RIGHT and the contract's wording was
> ambiguous. The finding as first written is partly retracted below, in place.**
>
> The entry offered two options and said both were defensible. **Only one survives
> contact with the rest of the contract and the suite**, and the deciding evidence was
> already in the tree when the finding was written:
>
> - `src/disassembler.zig:552` has a **passing, load-bearing** test — *"a RESERVED
>   accelerator opcode round-trips as raw bytes, not as a neighbour"* — which requires
>   `decode` to return `.ok` for a reserved byte. The disassembler reaches its `.raw`
>   fallback **only** through the `.accelerator` arm
>   (`disassembler.zig:109` → `accelerator`, `disassembler.zig:117-125`). Making the
>   decoder return `.err`, option (a), breaks that test.
> - §3.6's own sentence has three clauses. Clause 1 ("decodes as an accelerator
>   instruction with an unrecognised operation") and clause 2 ("must round-trip as raw
>   bytes") both **require** a successful decode. Option (a) contradicts the sentence
>   it was meant to satisfy.
>
> So option (b) was not merely "cheaper and matching the code" — it is the only reading
> under which §3.6 is self-consistent. **Amendment 1.20** writes the three clauses out
> normatively in §3.6 and names the layer for each: the decoder accepts (and must not
> be changed), the bytes round-trip as `.raw`, and the **simulator** refuses at
> execution — a fault, not a decode error.
>
> **Part of the original finding is retracted.** It described the decoder's behaviour
> as "a rule enforced in one layer while another path reaches the same input ungoverned"
> — the **F8 shape**. That framing was wrong: no rule was being bypassed, because §3.6
> never required a decode error. The decoder is not an ungoverned path; it is the
> governed one, doing exactly what clause 1 specifies. What was genuinely missing was a
> statement of *which layer owns the refusal*, and the ambiguity is what made the
> decoder look ungoverned.
>
> **Pinned so it cannot regress, in two places that must agree:**
> - `src/decoder.zig` — *"F37 / amendment 1.20: a RESERVED accelerator byte DECODES OK
>   — the simulator refuses it"*, with a comment at the `.accelerator` arm saying the
>   absent registry lookup is deliberate and pointing at amendment 1.20.
> - `src/vm.zig` — *"a RESERVED §3.6 byte still refuses DIFFERENTLY from a defined
>   one"*, which already asserted the simulator half.
>
> **Load-bearing, proven by mutation in a throwaway copy** (never the shared tree):
> making the decoder return `.err` for `0x6F` — exactly option (a) — makes the new test
> fail with `reached unreachable code` and the test process abort. Reverted in the copy;
> the shared tree was never mutated.
>
> **What may and may not be said.** May be said: the contract now names the refusing
> layer for all three clauses, and both layers are pinned by tests. May **not** be said:
> that a reserved opcode is rejected at decode time — it is not, and amendment 1.20 says
> so. This resolution changes **no encoding**: no bit moved and no opcode was added.

### The original entry, kept for the record

**Status at the time: open.** Not fixed, because `src/decoder.zig` is outside that
change's scope.

`docs/isa-encoding.md` §3.6 says: *"An opcode in `0x60`–`0x8F` that is not in this
table is **reserved**: it decodes as an accelerator instruction with an unrecognised
operation, must round-trip as raw bytes, and must not be silently reinterpreted as a
neighbouring operation."*

`decoder.zig:469-485` accepts **every** byte in `0x60`–`0x8F` as `.accelerator` with
no lookup in the §3.6 registry; the only rejection there is a non-zero
`reserved[39:32]`. So the reserved-ness of an opcode is not established by the
decoder at all. Reproduced: `.raw 111, 0, 0, 0` assembles (111 = `0x6F`),
disassembles back to the same text, and `decode` returns `.ok` for it.

This is the **F8 shape** — a rule enforced in one layer while another path reaches
the same input ungoverned — and it is the same shape as F24/F27, where a rule the
assembler enforced was unenforced on the `run-bin` path. It is not currently a live
defect, because the VM's `refuseAccelerator` does the registry lookup and refuses
reserved bytes correctly; the distinction is made, just one layer later than the
contract's wording implies. It becomes live if any future consumer of
`decoder.decode` treats `.accelerator` as meaning "a defined operation".

**What closing it needs:** a decision, not a patch — either the decoder gains the
registry lookup and returns `.err` for a reserved byte (making the contract's
sentence literally true of the decoder), or §3.6 is reworded to say the *simulator*
must refuse it, which is what actually happens today. The second is cheaper and
matches the code; the first is stricter and matches the existing sentence. Both are
defensible; picking one silently is not.

### A verification trap hit while recording this

Verifying F37 by hand produced a **false reading** worth recording, because it nearly
went into this file as evidence. Three reserved bytes were run through the CLI and
all three reported the *improved* phrasing `"opcode 0x6f, which the §3.6 table does
not list"` — text that was **not in the source**. The source had been reverted; the
`zig-out/bin/celeris64` binary had not been rebuilt, so the CLI was running a
discarded experiment. After `zig build`, the same three inputs reported
`"an accelerator operation the encoding table does not list"`.

The lesson is the one the previous session already recorded about test counts: **a
stale artifact reads exactly like a real result.** `git status` was clean for
`src/vm.zig` and the source was correct, so no file diff would have revealed it.
Rebuild before believing a CLI observation, especially when that observation is
being used as evidence in a document.

---

## F36 CLOSED (v1.18, Amendment 1.18) — eleven of thirteen accelerators execute

The finding offered no route out except a contract change, because every available
implementation would have invented a convention. **Amendment 1.18 is that change**,
and it stayed inside the existing four fields (`rs2`, `rs3`, `reserved`, `count`) —
no bit layout moved and no field was added, which is what kept F36 a contract gap
rather than an encoding gap.

**Result: 11 of 13 execute. 2 remain refused**, and the two refusals are now
properties of the *operations*, not of a missing constant:

- **`matrix.mul` (0x62)** needs three addresses and two orders — five inputs for four
  fields. Reading an order from `count`, deriving the product's address from an
  input's extent, and aliasing one matrix's header into another's data were each
  considered and rejected. The honest fix is a second opcode, which an amendment that
  does not change the encoding may not add.
- **`codec.decompress` (0x81)** needs an `out.len` bound. Reusing `compress`'s 256-byte
  workspace would silently reject valid inputs whose decompressed form exceeded 256
  bytes — a narrowed domain, which is worse than a refusal because it looks like it
  works.

The load-bearing decisions are recorded in the version-history row for 1.18, including
where each matrix dimension comes from and why `matrix.identity`'s old table row was
unreachable from source (`.sources = 0` could not fill `rs1`, where its order lives,
and `.takes_count = true` invited the one spelling the VM rejects).

**§3.6 line 490 is retracted in place**, not deleted: the struck sentence, the
retraction and the current rule all sit at the line where the old rule lived, so a
reader who lands there first is not misled. Tested directly — with `rd` pre-loaded to
8 and no `count`, `codec.fnv1a` refuses and leaves `rd` at 8, where a count-reading
implementation would have hashed 8 bytes and succeeded.

**A false premise in the amendment's own first draft, caught in review and kept as a
retraction.** Rule C originally said the `codec.compress` workspace sits in "the 64 KiB
memory image every execution entry point allocates". That is false: `crossarch.zig`
allocates 4 672 bytes and `examples.zig` 20 480, and `Vm.init` accepts any slice, so
65 536 is a CLI convention rather than a machine property. The rule now states the
precondition, refuses below it with a sentence naming the required address, the
required length and the actual image length, touches no byte, and is proven in both
directions.

**What may and may not be said.**

- **May be said:** eleven §3.6 operations execute with the results their models
  compute, verified end to end through the CLI — `codec.fnv1a`'s value checked against
  an FNV-1a computed independently in Python, `matrix.identity` shown writing a real
  2×2 matrix into memory with sentinels around the block so a no-op cannot pass.
- **May be said:** the change is encoding-neutral. The round-trip fuzzer is unchanged
  at `checked=11839 identical=11839`.
- **May not be said:** that the accelerators are "done". Two refuse by design and need
  a second opcode or a wider operand field.
- **Not independently verified:** CLS64 has no LLVM backend, so every word quoted for
  these operations is checked against this repository's own decoder and encoder pair.
  That is self-consistency, not an outside oracle.

---

## F38: REX.R and REX.B selected the wrong register for r8–r15 (x86-64)

**Found** by the agent writing the example suite, which worked around it by keeping
its hand-written x86-64 programs in r0–r7. **Fixed** in `a5be79d`.

The REX prefix bits were stored unnormalised: `rex_r = @truncate(b & 0x04)` yields 4,
not 1, so `rex_r << 3` is 32 and truncates to 0 in a `u4`. Both REX.R (the ModRM.reg
extension) and REX.B (the r/m extension) therefore resolved to their low counterparts,
silently, for every instruction naming an extended register.

Reproduced before the fix: `4C 8B 00`, which `llvm-mc` encodes for
`movq (%rax), %r8`, loaded into **RAX** and left R8 at zero. After the fix R8 receives
the value and RAX is untouched. Both bits are normalised to their own position now.

**Why no test caught it, which is the part worth keeping:** every test in the file used
r0–r7 in its hand-written encodings, so the entire r8–r15 space was unexercised. Checked
rather than assumed: in the file as it stood before the fix, the string `r8` occurs
exactly twice, and both are in one comment naming the `MOV r/m8, r8` opcode — no test
word ever named an extended register. The ORACLE tests do compare against LLVM's bytes,
but they check the *length and decoding of words LLVM produced*, and none of those used
one either. A whole register file was untested while the suite stayed green.

This is the **F8 shape** once more: here it is not a rule enforced in one layer and
absent in another, but a *wrong* rule that both this repository's encoder helpers and
its decoder shared, so every self-consistency check agreed. `llvm-mc` was the only
thing in the repository that disagreed, and only because a new program happened to be
written for r8. The regression test uses LLVM's own encodings for a load into R8 and a
store from it, and was confirmed load-bearing by reverting the normalisation in a
throwaway copy.

---

## F39: the example suite's verdict logic called a real loss "WRONG"

**Found** by the Lead while reviewing the first run of the example suite. **Fixed**
in `c414be5`.

The verdict compared CLS64's retired count against the other three ISAs and tested a
declared *loss* as `most` — CLS64 retiring more than **every** other ISA. That is a
strictly stronger claim than losing. `fused_stream_add` retires 1802 against RISC-V's
1801 and x86-64's 1799, so CLS64 genuinely loses both comparisons, while AArch64's
2057 is worse than CLS64 — so `most` was false and the report printed **WRONG**,
presenting a confirmed loss as a falsified prediction.

"Win" is now "beats all three" and "loss" is "beaten by at least one". The two are not
complements, which is exactly why the old encoding of `loss` as `most` could not
express the four-way case, and the source note says so.

**Why this matters beyond the one row:** the verdict column is the suite's own
falsification machinery. A verdict that reports a confirmed expectation as failed is
the mirror of the defect this whole suite exists to avoid — and it was one line, in
the reporting layer, invisible to every equivalence test because the *programs* were
all correct. The equivalence checks were sound; the summary was not.

---

## F40: the RTL still says 0x65 is reserved, and its testbench asserts it

**Found** by the Lead while checking `rtl/` for consistency after amendment 1.20.

> **CLOSED — fixed and verified by running the Verilator testbench, both directions.
> The original entry is kept below.** The fix took the decision this entry named,
> option (a): the RTL **recognises 0x65 and raises `not_implemented`** like the other
> thirteen, staying uniformly decode-only. No matrix datapath was built.
>
> **Three sites changed:** `rtl/pkg/celeris64_pkg.sv` gained
> `OP_MATRIX_MULOUT = 8'h65`; `rtl/accel.sv`'s exhaustive `unique case` gained it (and
> its header comment, which had named 0x65 as the *example of a reserved byte*, now
> explains the decode-only choice instead); `rtl/tb/core_tb.sv`'s
> `check_recognised_table()` table changed from `(b <= 8'h64)` to `(b <= 8'h65)`.
>
> **Verified by running, before and after:**
>
> | | result |
> |---|---|
> | Before the fix | `ok §3.6 all 13 normative opcodes recognised (13), 35 reserved rejected` — **PASS, 159/159, exit 0** |
> | After the fix | `ok §3.6 all 14 normative opcodes recognised (14 observed), 34 reserved rejected` — **PASS, 159/159, exit 0** |
> | Mutant (0x65 removed from `accel.sv`) | `FAIL §3.6 recognition table: expected 14 recognised / 34 reserved, got 13 recognised and 35 reserved` — **failures=1, exit 1** |
>
> The mutant run matters most: it proves the corrected table is **load-bearing**, and
> that the before-fix PASS was a genuine blind spot rather than a latent failure.
>
> **A second defect found and fixed while closing this, in the same task.** The
> closing `$display` printed `ok ... all 13 ... (13), 35 reserved` **unconditionally** —
> it emitted the word "ok" and the *expected* count even when a byte had been
> misclassified. Under mutation the old code therefore printed a passing line beside
> the failure. That is the **F31 shape again**: a message that cannot fail. It now
> counts what the RTL **actually** reports, separately from what the test expects,
> and prints `ok` only when the count is right — the mutant output above is that
> change working, reporting `13 recognised and 35 reserved` instead of the expected 14.
>
> **What may be said now:** the RTL's §3.6 recognition table matches the contract at
> 14 recognised / 34 reserved, verified by executing the testbench, and the check that
> asserts it fails when the table is wrong. **Still not claimed:** any timing, area or
> silicon result, and the RTL remains decode-only for every accelerator — 0x65 included
> — which is the documented choice, not a gap.

### The original entry, kept for the record

**Status at the time: open.** Not fixed, because it needs an RTL change plus a re-run
of the Verilator testbench, and the contract question it raises should be settled first.

**Amendment 1.19 added a fourteenth §3.6 opcode, `matrix.mulout` (0x65), to the
contract and to the simulator — and nothing in `rtl/` was touched.** The RTL still
encodes the v1.18 table, which is 13 opcodes. The §3.6 range is 48 bytes wide
(`0x60`–`0x8F`), so the counts move with it:

| | recognised | reserved |
|---|---|---|
| Contract, after 1.19 | **14** | **34** |
| `rtl/accel.sv` and `rtl/tb/core_tb.sv` | 13 | 35 |

Three places disagree with the contract, and the third is the serious one:

1. `rtl/pkg/celeris64_pkg.sv:152-155` has no `OP_MATRIX_MULOUT` constant at all.
2. `rtl/accel.sv:120-130` lists 13 opcodes in its `unique case`, and the comment
   directly above it at **line 117-118** reads: *"a range check would report 0x65
   (reserved) as recognised because 0x64 is"* — it names 0x65 as its example of a
   reserved byte.
3. `rtl/tb/core_tb.sv:1040-1042` encodes the table as
   `(b <= 8'h64) || (b >= 8'h70 && b <= 8'h73) || (b >= 8'h80 && b <= 8'h83)`, and
   `check_recognised_table()` then **fails any byte in that list that decodes as
   recognised**. So the RTL testbench does not merely omit 0x65 — it **asserts that
   0x65 must raise `unknown_op`**, which is now the opposite of the contract. Its
   `$display` at line 1061 prints "all 13 normative opcodes recognised ... 35 reserved
   rejected", which is a stale count presented as a passing result.

This is the **F8 shape** for the third time in this file (see F24/F27 and F37): a rule
enforced in one layer while another layer reaches the same input differently. Here the
layers are the contract and the RTL rather than the assembler and the decoder, and the
RTL is the one that is now wrong.

**Why it did not show up.** `rtl/tb/core_tb.sv` is not part of `zig build test`. The
RTL is exercised only by an explicit Verilator run, which the v1.19 change did not make,
because v1.19 touched only `docs/isa-encoding.md`, `src/assembler.zig`,
`src/disassembler.zig`, `src/vm.zig` and `tests/mulout_e2e.sh` — all of them outside
`rtl/`. So every gate that ran for v1.19 was green while the RTL silently disagreed with
the contract that v1.19 had just amended. **A green `zig build test` says nothing about
`rtl/`.**

**What closing it needs — and the decision it contains.** The mechanical part is easy:
add `OP_MATRIX_MULOUT = 8'h65` to the package, add it to `accel.sv`'s recognition case,
change the testbench's table to `(b <= 8'h65) || ...`, and update the two counts to
14/34. The part that needs a decision is **what the RTL should do with 0x65**: v1.19
made `matrix.mulout` *execute in the simulator*, while every other accelerator in the
RTL is **decode-only** (`rtl/CROSSCHECK.md` §4/§5.7: `result_valid_o` tied low, no
fabricated answer, because §3.6 calls the behaviour "a software model"). So either

- (a) the RTL recognises 0x65 and raises `not_implemented` like the other 13 — cheap,
  consistent with the existing decode-only contract, and honest; or
- (b) the RTL gains a matrix datapath — a large change that would make it the only
  accelerator with one, unevenly, and is exactly what the previous handoff warned
  against ("Do **not** build matrix/FFT/codec datapaths in SystemVerilog to 'complete'
  this").

**Option (a) is the one that matches the repository's stated position**, but it is a
real choice and picking it silently is what F37 taught this file not to do. Recorded
rather than patched.

**What may and may not be said.** May be said: the RTL and its testbench encode the
13-opcode table and the contract now has 14, verified by reading all three sites above.

**CONFIRMED BY RUNNING, and the result is subtler than "it fails".** The core testbench
was built with Verilator 5.49 to a fresh path (the stale-binary trap in
`rtl/CROSSCHECK.md` §2.3 was avoided by using a new `-o` target and checking the build's
exit status first) and executed:

```
ok §3.6 all 13 normative opcodes recognised (13), 35 reserved rejected
=== checks=159 failures=0 ===
PASS: all 159 core vectors matched (simulation only; RTL is NOT timing-closed, NOT on silicon)
```

So the testbench is **green, exit 0, 159/159** — and that is the finding, not a
refutation of it. `check_recognised_table()` classifies 0x65 as reserved *because the
testbench itself encodes the old table*, so the check that exists to catch exactly this
disagreement cannot see it. **The RTL does not fail; it passes while contradicting the
contract**, which is the same shape as F31 in this file (assertions that could never
fail) and is strictly harder to notice than a red test. A fix must therefore change the
expected table *and* confirm the new table is load-bearing — the current run cannot
distinguish "0x65 is correctly reserved" from "0x65 is wrongly reserved", because
nothing in `rtl/` knows the contract changed.

May **not** be said: that anything is red, or that the RTL is broken in synthesis. The
RTL synthesises and its testbench passes; what is wrong is the *table it asserts*, and
that is only visible against `docs/isa-encoding.md` §3.6 — not against itself.

**This is the second time in this session that a green gate hid a disagreement** (F37's
decoder was the first). Both were found by asking what a passing check actually
*asserts*, not by watching for failure.
