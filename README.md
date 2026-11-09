# Celeris-64 (CLS64)

A 64-bit scalar architecture designed around Data-Oriented Design, plus a working
software simulator, assembler, disassembler and test suite written in Zig.

**This repository contains a software model of a processor that does not exist.**
There is no silicon, no RTL synthesis, no timing analysis and no FPGA. Every count
this project prints is a *simulator instruction count*, never a performance claim.
See [docs/fidelity.md](docs/fidelity.md) for the per-subsystem ledger.

## Status

| Check | Result |
|-------|--------|
| `zig build` | exit 0, produces `zig-out/bin/celeris64` |
| `zig build test` | **49/49 steps, 570/570 tests, exit 0** (cold cache; a warm cache reports a stale count) |
| `zig build bench` | exit 0, prints clearly-labelled simulated counts |
| `zig build audit` | every reserved field the contract declares is rejected — 9/9 enforced, 1 declared exemption, exit 0 |
| `zig build live-check` | re-derives the verifier's 232 recorded facts from the current binary; catches snapshot drift |
| `verilator --lint-only -Wall --top-module core` over `rtl/` | zero warnings (one documented false-positive suppression in `core.sv`) |
| End-to-end pipeline | assemble → binary → disassemble → run → trace, all working |
| Round trip | `asm → dis → asm` is **byte-identical for every word a source line can express** — fuzzed over 20,000 generated words, and **12 defects deep** (F19–F30). The earlier claim of unconditional byte-identity was false. |
| Differential fuzzer | `tests/roundtrip_fuzz.zig` — 11,839 checked, 11,839 identical; every exclusion names its defect ID |

## Requirements

Zig **0.17.1**. There is no system `zig` on `PATH` in this environment; the toolchain
lives at `~/.local/zig/zig` (official tarball, no sudo required):

```sh
~/.local/zig/zig build
~/.local/zig/zig build test
~/.local/zig/zig build bench
~/.local/zig/zig build audit
```

Verilator **5.49**, for the Phase 4 RTL under `rtl/`, also installed without sudo (a
prebuilt wheel, no compiler toolchain needed):

```sh
export VERILATOR_ROOT=$HOME/.local/verilator
export PATH="$HOME/.local/bin:$PATH"          # provides the `python` shim verilator needs
~/.local/verilator/bin/verilator --binary ... -CFLAGS "-std=c++20" -LDFLAGS "-std=c++20"
```

Two host packaging gaps are worked around rather than fixed: `verilated.mk` ships an empty
`CFG_CXXFLAGS_STD`, and it hardcodes `python` while only `python3` exists. One toolchain
**defect** is documented because it produces silently wrong answers: this Verilator build
mis-simulates SystemVerilog's saturating-add operator (`64'd0 +| 64'd32` evaluates to `1`),
so `rtl/stream_engine.sv` uses an explicit widen-and-clamp function instead. Zig's `+|` is
unaffected and correct.

## Quick start

```sh
cat > hello.asm <<'EOF'
mov R0, 7
halt
EOF

~/.local/zig/zig build
./zig-out/bin/celeris64 asm   hello.asm hello.bin   # assemble to a flat image
./zig-out/bin/celeris64 dis   hello.bin             # disassemble
./zig-out/bin/celeris64 run   hello.asm             # assemble and execute
./zig-out/bin/celeris64 trace hello.asm             # step-by-step trace
```

The trace shows register mutations and program-counter movement in plain text:

```
Celeris-64 step trace (a software model, not silicon):
  000000  mov R0, 7   # R0 <- 0x0000000000000007, PC <- 0x0000000000000008
  000008  halt   # no register changed
  halted after 2 simulated instructions. The program executed halt.
```

## The architecture in brief

- **12 general-purpose registers** `R0`–`R11`, plus `ZERO`, `PC`, `SP`, `LR`, `FLAGS`.
- **Sub-width addressing** `.l` (32-bit), `.w` (16-bit), `.b` (8-bit). A sub-width
  write **zero-extends** the upper bits — this is mandated, observable behaviour.
- **Little-endian** throughout.
- **Dedicated primitives**: `stream.*` (fused batch memory ops), `select.*`
  (branchless masking over explicit status enums), `field.*` (non-power-of-two
  bitfield slicing).

All four assembly examples from the architecture specification parse and round-trip:

```asm
compare R0, R1 -> R2
select R3, R2, [EQUAL], R4, R5
field.extract R0, R1, offset=12, width=3
stream.add R0, [R1]+CHUNK_SIZE, R2
```

## Layout

| Path | Contents |
|------|----------|
| `src/registers.zig` | Register file, sub-width zero-extension |
| `src/memory.zig` | Flat little-endian byte-array memory |
| `src/decoder.zig` | 64-bit word → tagged instruction; `encode`/`decode` inverse pair |
| `src/vm.zig` | Fetch-decode-execute loop and instruction wiring |
| `src/field.zig` | `field.extract` / `field.insert` |
| `src/select.zig` | Comparison status enums and branchless select |
| `src/stream.zig` | Stream engine with all-or-nothing chunk semantics |
| `src/assembler.zig` | Text source → instruction words |
| `src/disassembler.zig` | Instruction words → text, plus trace mode |
| `src/diagnostics.zig` | Plain-language diagnostic rendering |
| `src/main.zig` | CLI |
| `src/capability.zig` | CHERI-style bounds model (**not** cryptographic) |
| `src/thread.zig` | SMT-8 slot model (**interleaved**, not parallel) |
| `src/matrix.zig`, `src/fft.zig`, `src/codec.zig` | Functional accelerator models |
| `src/stdlib_*.zig` | UI, graphics and networking primitives (models) |
| `tests/vm_tests.zig` | Independent adversarial test suite |
| `docs/isa-encoding.md` | **Normative** instruction encoding contract |
| `docs/fidelity.md` | What is real, what is modelled, what is unverified |

## What is NOT implemented

Stated plainly, because the difference between "modelled" and "working" matters:

- `thread.*` (0x90–0x92) **executes**, as a **deterministic modelled interleave** —
  no timing, no real concurrency, no speedup.
- `cap.*` (0x50–0x52) is **partially executing**: `cap.load`/`cap.store` are
  **decode-only by ruling** because the encoding carries no address field, so they
  refuse loudly rather than guessing; `cap.check`'s status is in `docs/fidelity.md`.
- The accelerator range (0x60–0x8F) is **not wired into the VM**. The models exist
  and are tested, and the decoder builds a real payload, but the opcodes fault with
  a plain-language diagnostic rather than executing. They also cannot be written
  from source at all — the assembler accepts no accelerator mnemonic.
  *Not wired is not the same as broken.*
- `matrix.*`, `fft.*`, `codec.*`, capability checks and SMT threads are
  **software models**, not hardware. No acceleration, no cycle claims.
- **RTL is written, lint-clean, and synthesized to gates; it is not timing-closed and
  has no known clock frequency.** Verilator 5.49 runs three testbenches with real
  assertions (`rtl/`, `rtl/CROSSCHECK.md`). `zig build synth` reports 42,775 cells in
  Yosys's generic flow and 22,069 mapped to iCE40 primitives (15,076 LUT4) - more than
  an HX8K holds. Cells are not timing: no frequency, no critical path, no area claim.
  On GCC 15 the testbenches need two workarounds: add
  `-CFLAGS -fcoroutines` (GCC 15 requires it explicitly for `--timing`) and pass
  `-MAKEFLAGS CFG_GCH_IF_CLANG=.gch` (GCC 15 names precompiled headers `.gch`, which
  Verilator 5.49's makefile does not expect). Without them the C++ build fails; the
  RTL itself is unaffected.
- Benchmarks report **retired-instruction counts in a model**. They say
  "simulated" on every line, deliberately. They are not a speedup claim.

## Design rules this project holds itself to

1. **No bare hexadecimal error codes.** Every failure is a plain-language sentence
   naming the offending operand, per the architecture mandate.
2. **Zero dynamic allocation inside the execution loop.** Memory is allocated once
   at VM init; a grep test enforces this.
3. **All-or-nothing bulk operations.** A stream chunk or a program load that does
   not fit modifies *zero* bytes. Partial application is forbidden and tested.
4. **Claims are backed by commands.** If something could not be run, it is labelled
   unverified rather than implied.
