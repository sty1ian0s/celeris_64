# Celeris-64 FPGA Prototyping Procedure

Document Version: 1.0
Status: **SYNTHESIS RUNS; BOARD BRING-UP NOT EXECUTED.**

> ## ⚠ SYNTHESIS NOW RUNS; BOARD BRING-UP HAS NOT
>
> The toolchain blockers in earlier revisions of this file are gone. The OSS CAD
> Suite is installed at `~/.local/oss-cad-suite` (Yosys 0.70, nextpnr, iverilog,
> GTKWave) and `sv2v` at `~/.local/sv2v`. **Synthesis runs today**: `zig build
> synth` reports 42,775 cells in Yosys's generic flow, and 22,069 cells mapped to
> iCE40 primitives (15,076 LUT4, 4,924 carry, 2,063 flip-flops). The iCE40 figure
> exceeds an HX8K (7,680 LUT4s), so this design does not fit the smallest plausible
> target. That is a measured result, not an estimate.
>
> **Everything about a physical board remains unexecuted.** There is no FPGA, no
> vendor toolchain, and still no constraint file for any board (`.xdc`, `.pcf`,
> `.lpf` or `.sdc`), so there is no board target to synthesize *against*. No step
> below has been run, no bitstream exists, and nothing has been placed, routed,
> timed or loaded onto silicon.
>
> **A cell count is not a timing result.** No clock frequency, no critical path and
> no resource-utilisation figure for a real part is claimed anywhere in this
> repository. Synthesis establishes that the design maps to gates and says nothing
> about how fast it runs.
>
> What follows is what a person *would* do for board bring-up, written down
> precisely. **Do not read any step below as completed.**

This document is the Phase 4 procedure from `celeris_64-implementation-roadmap.md`.
It is a **specification artifact**. For the consolidated status of every
subsystem, see `docs/fidelity.md`.

---

## 0. Why this document exists at all

The architecture specification describes hardware. This repository contains a
*software model* of that hardware, plus an RTL implementation of the encoding
that is verified **in simulation only** — elaboration and testbenches, never
gates. Writing an FPGA procedure that has not been executed is only honest if it
says so on its face, which is why this section is first rather than last.

The single most valuable word in this file is **NOT EXECUTED** — for every step
that touches a physical board. Synthesis itself is no longer in that category: it
runs, and its cell counts are recorded.

---

## 1. Prerequisites — current state on this machine

Every row below was checked by running the command shown.

| Prerequisite | Command used to check | Observed result |
|---|---|---|
| RTL source | `ls rtl/` | **Exists** — 11 SystemVerilog files, lint-clean under Verilator. |
| Verilator | `ls ~/.local/verilator/bin/verilator` | **Installed**, 5.49. (`command -v verilator` returns nothing only because `~/.local/bin` is not on `PATH`; the earlier "not installed" row used that check and was wrong.) |
| Icarus Verilog | `ls ~/.local/oss-cad-suite/bin/iverilog` | **Installed** (OSS CAD Suite, 2026-11-08 release). |
| Yosys | `ls ~/.local/oss-cad-suite/bin/yosys` | **Installed**, 0.70+360. Synthesis runs; see §3. |
| sv2v | `ls ~/.local/sv2v/bin/sv2v` | **Installed**, v0.0.13. Required: Yosys rejects `return` in functions and a part-select on a function call. |
| GTKWave | `ls ~/.local/oss-cad-suite/bin/gtkwave` | **Installed** (OSS CAD Suite). |
| Board constraint file | `find . -name '*.xdc' -o -name '*.pcf' -o -name '*.sdc'` | **None.** No board target exists. |
| Privileged install | `sudo -n true` | `sudo: interactive authentication is required` |
| FPGA board | — | **None attached** |
| Vendor toolchain (Vivado / Quartus / Gowin) | — | **Not installed** |

Consequence: **RTL exists, is verified in simulation, and now synthesizes to
gates — but no board bring-up is possible here.** Verilator elaborates and
simulates; Yosys maps to gates; neither places, routes or produces a bitstream
without a target. No board constraint file exists, so there is nothing to
synthesize *against* and no pinout to honour. Per `tests/contract.md` P4.1,
neither unverified RTL nor verified-in-simulation RTL may be presented as working
hardware. This repository presents none, and the cell counts in §3 are labelled as
gate counts rather than as evidence of a working chip.

---

## 2. What would have to exist first

Before any step in §3 can mean anything, the following must exist. Item 1 now
exists (the RTL is written and simulation-verified); the rest still do not.

1. **`rtl/` SystemVerilog** for the modules the roadmap names:
   - `registers.sv` — `R0`–`R11`, `ZERO`, `PC`, `SP`, `LR`, `FLAGS`, with
     sub-width writes that zero-extend the upper bits (`AGENTS.md` §2.1). The
     zero-extension is the observable contract; a synthesised version that
     preserves upper bits is a *different architecture*.
   - `alu.sv` — the §3.1 operations, plus the signed 28-bit immediate path.
   - `stream_engine.sv` — `stream.*` per `docs/isa-encoding.md` §3.4, including
     the **atomic bounds rule**: a chunk that does not fully fit must modify
     zero elements. In RTL this means the bounds check must complete before any
     write is asserted — a naive implementation that checks per element will
     produce partial application and must be rejected in review.
   - `core.sv` — top level tying the above together over a flat memory port.
2. **An RTL testbench** that can drive those modules without a board.
3. **A simulator or synthesis tool** (§1) — **both present now.** Verilator for
   simulation and the OSS CAD Suite for synthesis. The remaining gap is a board
   constraint file (`.xdc`/`.pcf`/`.lpf`/`.sdc`) and a physical board.

---

## 3. Procedure (NOT EXECUTED)

The steps below are written as a competent engineer would run them. **None has
been run here.**

### 3.1 Install a simulator without root

`sudo` is unavailable in this environment, so any tool must be built into
`~/.local`. Verilator is the usual choice and can be built from source:

```sh
# NOT RUN IN THIS REPOSITORY.
mkdir -p ~/.local/src && cd ~/.local/src
git clone https://github.com/verilator/verilator
cd verilator && autoconf && ./configure --prefix="$HOME/.local"
make -j"$(nproc)" && make install
~/.local/bin/verilator --version
```

Expect this to take on the order of 10–20 minutes. Icarus Verilog
(`iverilog`) is a lighter alternative for simulation-only work and is packaged
in most distributions, but installing it here would still require root.

### 3.2 Lint every module before simulating

```sh
# NOT RUN IN THIS REPOSITORY.
for f in rtl/*.sv; do
  ~/.local/bin/verilator --lint-only -Wall --top-module "$(basename "$f" .sv)" "$f"
done
```

A module passes only when each of those commands exits 0 **and** the warnings
have been read rather than ignored. `-Wall` is not decoration: an inferred latch
in the stream engine is exactly the kind of defect that makes a bound check
non-atomic, which is the failure mode §3.4 forbids.

### 3.3 Simulate the contract, not just the code

```sh
# NOT RUN IN THIS REPOSITORY.
~/.local/bin/verilator --binary --timing -Wall rtl/core.sv tb/core_tb.sv
./obj_dir/Vcore
```

The testbench must assert the same properties the software model asserts, so
that the two can be compared rather than merely both existing:

| Property | Source of truth | What the testbench must show |
|---|---|---|
| Sub-width write zero-extends | `AGENTS.md` §2.1 | Set all 64 bits, write `.b`, read back zero in the upper 56 |
| `field.extract offset=12 width=3` | contract P1.5 | The documented bits, hand-derived |
| `stream.*` pointer advance | contract P1.3 | Register advances by `chunk * elementSize` |
| `stream.*` atomicity | contract P1.3 | A chunk that does not fit leaves memory byte-for-byte unchanged |
| `compare` status enum | contract P1.4 | Signed vs unsigned differ for a negative operand |
| Unknown opcode | contract P1.6 | Faults, does not hang, does not silently continue |

**A testbench that only checks "it produces some output" proves nothing.** The
comparison target is the software model in `src/`, which is itself only a model.

### 3.4 Synthesis — **EXECUTED** (open toolchain, no vendor tools needed)

```sh
# RUN. Reproducible now:
zig build synth
# or: tools/rtl-synth.sh all
```

Recorded result (`sv2v` v0.0.13, Yosys 0.70+360, OSS CAD Suite 2026-11-08):

| Flow | Cells |
|---|---|
| Yosys generic `synth` | 42,775 |
| `synth_ice40 -flatten` | 22,069 — 15,076 `SB_LUT4`, 4,924 `SB_CARRY`, 2,063 flip-flops (0 problems) |

The iCE40 figure exceeds an HX8K (7,680 LUT4s), so this design does not fit the
smallest plausible target. Anyone wanting board bring-up needs a larger part.

Two source-level blockers had to be removed first, and neither was toolchain
absence: Yosys rejects `return` inside a function (the package uses it
throughout — `sv2v` lowers it) and rejects a part-select applied directly to a
function call (`rtl/stream_engine.sv`, rewritten as `BYTE_LANES'(...)`).

**What these numbers are not.** A cell count is a count of gates. There is no
placement, no routing, no timing analysis, no part, and no bitstream. Nothing here
is a maximum frequency, a critical path, or a utilisation report for a fitted
design. Vendor-tool synthesis (Vivado/Quartus) has still never been run, and any
figure it produces would likewise be a **tool estimate for a part that was never
programmed**. See §5.

### 3.5 On-hardware bring-up (requires a board)

```sh
# NOT RUN IN THIS REPOSITORY. No board is attached.
openFPGALoader -b <board> bitstream.bit
```

Then, and only then, would the following be checkable **on hardware**:

1. Program a program into memory, run it, and compare the final register and
   memory state against the software model's result for the same program.
2. Confirm that an out-of-bounds `stream.*` chunk leaves memory byte-for-byte
   unchanged on real silicon, not merely in simulation.
3. Confirm that an unknown opcode raises the fault line rather than executing
   garbage.

Until a board runs those checks, the RTL status is **unverified**, and this
repository describes it as such.

---

## 4. What would NOT be proven even if all of §3 ran

Synthesis and a bitstream do not establish any of the following. Stating them
explicitly, because the temptation to imply them is the reason this document
exists:

- **Not** timing closure. A tool reporting a maximum frequency is reporting an
  estimate for one corner, one part, one set of constraints. That is not
  closing timing.
- **Not** silicon correctness. An FPGA implementation is a different artifact
  from a fabricated chip. Proving one says nothing about the other.
- **Not** that the architecture is sound. The hardware would implement the
  model's behaviour; if the model's behaviour is wrong, the RTL would faithfully
  implement something wrong.
- **Not** a performance result. See §5.
- **Not** that `cap.*` or `thread.*` work. Those opcodes are **not wired in the
  software model** (`docs/fidelity.md` §6.1). An RTL implementation would have
  no reference behaviour to compare against.

---

## 5. Claims this repository must never make

The following are prohibited, because none can be supported by anything in this
repository:

| Prohibited claim | Why |
|---|---|
| A clock frequency ("runs at N MHz") | Synthesis maps to gates and stops there. No placement, no routing, no timing analysis, and no part exists. |
| Timing closure of any kind | Never attempted. |
| A silicon performance figure | There is no silicon. |
| A resource-utilisation figure (LUT/FF/BRAM counts) **for a real part** | Cell counts exist (see §3 and `docs/STATUS.md`), but they are pre-placement gate counts, not a utilisation report for a fitted design. BRAM usage is not estimated at all. |
| "The RTL works" | It lints clean, passes 553 testbench assertions, and synthesizes. It has never been placed, routed, timed or run on hardware. |
| "Verified on an FPGA" | No board, no toolchain. |
| Any speedup or throughput number | Those are simulator instruction counts; see `docs/fidelity.md` §3.4. |

The one honest sentence about Celeris-64 hardware is:

> Celeris-64 is an architecture specification with an executable software model,
> and no hardware implementation exists.

---

## 6. Current status, in one line

**Phase 4 is PARTIALLY DONE: RTL exists, is verified in simulation, and now
synthesizes to gates; board bring-up is NOT STARTED.** The `rtl/` directory lints
clean under Verilator 5.49 with three testbenches passing (553 assertions), and
`zig build synth` maps the whole design to 42,775 generic cells / 22,069 iCE40
cells. No board constraint file exists, no board is attached, and **no step in
this document that touches hardware has been executed.** Timing closure, placement,
routing, bitstream generation and hardware realization all remain at zero, and the
design does not fit the smallest plausible target (an HX8K holds 7,680 LUT4s; this
needs 15,076).
