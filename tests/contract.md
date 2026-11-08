# Acceptance Criteria Contract

Every task on the Celeris-64 task board is judged against the criteria below. A task is
complete when a *different* agent can run the listed command and see the listed result.
"The code looks right" is not completion. Nothing here is satisfied by a passing claim
that was not observed.

## 0. Global Rules

1. **Toolchain.** Zig 0.17.1 is installed at `~/.local/zig/zig` (symlink) pointing at
   `~/.local/zig-x86_64-linux-0.17.1`. There is no system `zig` on `PATH`. Every command
   in this repo must use `~/.local/zig/zig` or a shell alias; do not assume `zig` resolves.
2. **Build and test.**
   - Build: `~/.local/zig/zig build`
   - Test: `~/.local/zig/zig build test`
   - Both must exit `0`. A skipped or empty test suite is a failure, not a pass.
3. **No unverified claims.** Any statement that the code works must be backed by a
   command that was actually run, with its output shown. If a thing could not be run,
   say so explicitly and mark the task incomplete.
4. **Diagnostics.** No user-visible error may be a bare hexadecimal code
   (AGENTS.md §4.2). Failing diagnostics must be plain sentences naming the operand.
5. **No hidden fidelity.** Modelled behaviour is labelled as modelled, per
   `docs/isa-encoding.md` §8. Benchmark numbers must print the word "simulated".
6. **Encoding is normative.** `docs/isa-encoding.md` §2–§5 is the interface. Changing it
   requires updating assembler, decoder, VM, disassembler and tests together.
7. **Zero dynamic allocation inside the execution loop** (AGENTS.md §4.1). All buffers
   allocated at VM init. A decoder or VM that allocates per instruction fails review.

## 1. Foundation

### F1 — Toolchain available and verified
- `~/.local/zig/zig version` prints `0.17.1`.
- `~/.local/zig/zig run` and `~/.local/zig/zig test` both work on a scratch file.
- Status: **PASS** (observed during recon).

### F2 — Build system
- `~/.local/zig/zig build` exits 0 from a clean checkout (no `zig-out/`, no `.zig-cache/`).
- `~/.local/zig/zig build test` exits 0 and reports a non-zero test count.
- The build exposes the `celeris64` executable artifact.

### F3 — Encoding contract
- `docs/isa-encoding.md` exists and defines word layout, opcode map, register indices,
  width suffixes, capability layout, diagnostics and the fidelity ledger.
- Status: **PASS** (authored by lead).

## 2. Phase 1 — Instruction Set Simulator

### P1.1 — Register file
- `R0`–`R11`, `ZERO`, `PC`, `SP`, `LR`, `FLAGS` all exist.
- Writing `ZERO` is a no-op; reading it returns 0. Proven by a test.
- Sub-width write (`.l`, `.w`, `.b`) **zero-extends** the upper bits. Proven by a test
  that sets all 64 bits, then writes a sub-width value, then reads back and asserts the
  upper bits are zero. This test is mandatory: it is the observable guarantee of
  spec §2.2.
- A width value outside `0..=3` produces a plain-language diagnostic.
- Register spill past 12 GPRs during assembly/simulation produces a diagnostic warning
  (AGENTS.md §4.3).

### P1.2 — Flat memory model
- Memory is a flat `[]u8`, allocated once at VM init, no per-access allocation.
- Little-endian 8/16/32/64-bit read and write. Proven by a test that writes a known
  value and asserts the exact byte layout in memory (this catches endianness and is not
  satisfied by a round-trip alone).
- Out-of-bounds access fails with a diagnostic naming address, base and length — it
  must not truncate and must not return 0.

### P1.3 — stream engine
- `stream.add`, `stream.copy`, `stream.fill`, `stream.setp` behave per
  `docs/isa-encoding.md` §3.4.
- Pointer auto-advance by `chunk * elementSize` is proven by a test asserting the
  pointer register's value after the operation.
- **Atomic bounds rule:** a chunk that does not fully fit modifies **zero** elements.
  Proven by a test that snapshots memory and asserts byte-for-byte equality after the
  failed operation. Partial application is a failure.

### P1.4 — select and compare
- `compare` produces the correct status enum for all five cases, including the signed
  vs unsigned split (`LESS` vs `UNSIGNED_LESS` must differ for a negative operand).
- `select` picks the correct arm for both matching and non-matching status.
- A test must assert deterministic behaviour: running the same select 1000 times gives
  the same result (no dependence on branch predictor state or hidden state).

### P1.5 — field slicing
- `field.extract` and `field.insert` handle non-power-of-two widths: at minimum `U1`,
  `U3`, `U5` round-trip.
- `offset == 12, width == 3` (the spec's literal example) extracts the documented bits.
- `width == 0` and `offset + width > 64` both produce diagnostics.
- A round-trip test: insert a value, extract it, assert equality — across the full
  64-bit register, at several offsets.

### P1.6 — Fetch-decode-execute loop
- The loop is in-order, deterministic, and advances `PC` by the fixed 64-bit width
  except for jump/call/ret.
- Running a program twice produces identical final register and memory state. Proven by
  a test that runs a program twice and compares full VM state.
- An unknown opcode produces a plain-language diagnostic naming the opcode value and
  the `PC` at which it was found. It must not panic and must not exit with a bare code.
- No allocation occurs inside the loop (review criterion, checked by reading the loop).

### P1.7 — Assembler
- Text source using the spec's syntax compiles to encodable instruction words.
- Whitespace, comments (`#`), and blank lines are tolerated.
- Every example in the architecture spec parses: `stream.add R0, [R1]+CHUNK_SIZE, R2`,
  `compare R0, R1 -> R2`, `select R3, R2, [EQUAL], R4, R5`,
  `field.extract R0, R1, offset=12, width=3`.
- A malformed line produces a diagnostic with the line number and the offending text.
  It must not crash and must not silently skip the line.
- Sub-register suffixes (`R0.l`, `R0.w`, `R0.b`) parse into the width encoding.

### P1.8 — Binary loader
- Assembled programs serialize to a flat little-endian image and load back.
- Round-trip: assemble → serialize → load → run produces the same result as
  assemble → run directly. Proven by a test.
- A truncated or misaligned image produces a diagnostic, not a panic.

## 3. Phase 2 — Diagnostics and Tooling

### P2.1 — Plain-language diagnostics engine
- Every diagnostic renders as a sentence. A test asserts that rendered output contains
  no standalone `0x`-only error token and does include the offending operand.
- Diagnostics carry: what was attempted, which operands, what was expected.
- Spill diagnostics fire when software exceeds the 12 GPRs.

### P2.2 — Disassembler
- Decoding a word produces the mnemonic and operand text that re-assembles to the same
  word. Round-trip test: `asm → decode → asm` equals the original bytes, for every
  opcode in the map.
- Step-by-step trace mode shows register mutations and stream pointer movement in plain
  text.
- A trace of a known program is asserted against an expected transcript.

## 4. Phase 3 — Benchmarking and Ecosystem

### P3.1 — Comparative benchmarks
- Simulator instruction counts for a stream batch vs an element-by-element loop.
- Output must print the word "simulated" (per the fidelity ledger §8).
- No claim of real-world speedup. The benchmark measures instruction counts in a model,
  and says so on its face.

### P3.2 — Native standard library modules
- Lean modules for UI layout, graphics and networking primitives.
- Each has a test. Each is honest about being a model, not a hardware path.

## 5. Phase 4 — RTL and FPGA

### P4.1 — RTL specification
- SystemVerilog under `rtl/` mapping the register file, ALU, stream engine.
- **Toolchain reality (updated):** Verilator 5.49 **is** installed at
  `~/.local/verilator/bin/verilator`, built from source without sudo, as this
  clause originally required. `command -v verilator` still returns nothing
  because `~/.local/bin` is not on `PATH`; check the explicit path. iverilog,
  yosys, nextpnr and gtkwave are **also installed now**, via the OSS CAD Suite at
  `~/.local/oss-cad-suite`, and `sv2v` at `~/.local/sv2v`. `sudo` remains
  unavailable in this session (approval prompts are rejected), which is why every
  tool lives under `~/.local`. This clause has now been wrong twice in the same
  way: it read "no Verilator is installed" until Verilator was built, and "iverilog,
  yosys and gtkwave remain absent" until they were installed. Both times the
  sentence was true when written and became false when a tool arrived.
- **Satisfied:** Verilator lints the RTL with exit 0
  (`--lint-only -Wall --top-module core`, whole tree, 0 warnings) and runs three
  testbenches with real assertions: `alu_tb` 80/80, `stream_tb` 314/314,
  `core_tb` 159/159 — 553 in total.
- Simulation is **not** synthesis, but synthesis now also runs: `zig build synth`
  maps the design to 42,775 generic cells / 22,069 iCE40 cells (see P4.2). It is
  still not timing-closed, not placed or routed, and never on silicon, and no clock
  frequency is claimed. Verified-in-simulation RTL must
  not be presented as working hardware any more than unverified RTL may.

### P4.2 — FPGA prototyping
- **Board bring-up cannot be satisfied in this repository.** No FPGA, no vendor
  toolchain, no board, and no constraint file (`.xdc`/`.pcf`/`.lpf`/`.sdc`) exists.
  No document may claim otherwise.
- **Synthesis is now satisfied and reproducible:** `zig build synth` (or
  `tools/rtl-synth.sh`) lowers the SystemVerilog with `sv2v` and synthesizes with
  Yosys. Recorded result: 42,775 cells in Yosys's generic flow, and 22,069 cells
  mapped to iCE40 primitives (15,076 LUT4, 4,924 carry, 2,063 flip-flops), flattened,
  0 problems. The iCE40 figure exceeds an HX8K (7,680 LUT4s), so the design does not
  fit the smallest plausible target.
- **Explicitly NOT satisfied, and not to be inferred from a cell count:** timing
  closure, placement, routing, a clock frequency, a critical path, or any
  area-per-technology figure. A cell count is a count of gates, not a result about
  speed.
- Deliverables in place: `tools/rtl-synth.sh` (exits non-zero when `sv2v` or Yosys is
  missing rather than skipping quietly), the `synth` build step, and the procedure in
  `docs/fpga-prototyping.md`.

**Was:** "Cannot be satisfied in this repository. No FPGA, no vendor toolchain.
Deliverable is a documented synthesis and test procedure, marked not executed."
That wording predated a working synthesis flow and became false the moment one
existed — the same staleness class as F16 and F18.

## 6. Verification Protocol

The verifier owns this and writes to `tests/vm_tests.zig` only.

1. Run `~/.local/zig/zig build test` on the integrated tree. Record the count.
2. Independently re-derive at least three claimed results by hand — e.g. the
   `field.extract offset=12,width=3` value, the stream pointer advance, and the
   sub-width zero-extension result — and assert them in tests the author did not write.
3. Attempt to falsify the atomicity claim: make a stream operation fail on the last
   element and assert nothing changed.
4. Attempt to falsify determinism: run the same program twice, diff full VM state.
5. Grep the execution loop for allocations.
6. Report failures with the exact command and output. A green suite that skips the
   falsification attempts is not verification.
