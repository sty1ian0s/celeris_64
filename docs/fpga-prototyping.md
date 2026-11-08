# Celeris-64 FPGA Prototyping Procedure

Document Version: 1.0
Status: **NOT EXECUTED — PROCEDURE ONLY.**

> ## ⚠ THIS PROCEDURE HAS NEVER BEEN RUN
>
> Nothing in this document has been executed in this repository. There is **no
> `rtl/` directory**, no FPGA board, no vendor toolchain, and no open-source RTL
> simulator or synthesis tool installed on this machine. Verilator, Icarus
> Verilog, Yosys and GTKWave are all absent, and `sudo` is unavailable.
>
> What follows is what a person *would* do, written down precisely, so that the
> work is specified rather than implied. **Do not read any step below as
> completed.** Anything you find here that looks like a measurement is a
> description of a measurement that was never taken.

This document is the Phase 4 procedure from `celeris_64-implementation-roadmap.md`.
It is a **specification artifact**. For the consolidated status of every
subsystem, see `docs/fidelity.md`.

---

## 0. Why this document exists at all

The architecture specification describes hardware. This repository contains a
*software model* of that hardware and nothing else. Writing an FPGA procedure
that has not been executed is only honest if it says so on its face, which is
why this section is first rather than last.

The single most valuable word in this file is **NOT EXECUTED**.

---

## 1. Prerequisites — current state on this machine

Every row below was checked by running the command shown. All of them are
**absent or unavailable**.

| Prerequisite | Command used to check | Observed result |
|---|---|---|
| RTL source | `ls rtl/` | **No such directory.** No RTL exists to synthesise. |
| Verilator | `command -v verilator` | **Not installed** |
| Icarus Verilog | `command -v iverilog` | **Not installed** |
| Yosys | `command -v yosys` | **Not installed** |
| GTKWave | `command -v gtkwave` | **Not installed** |
| Privileged install | `sudo -n true` | `sudo: interactive authentication is required` |
| FPGA board | — | **None attached** |
| Vendor toolchain (Vivado / Quartus / Gowin) | — | **Not installed** |

Consequence: **any RTL produced in this repository would be unverified.** Per
`tests/contract.md` P4.1, unverified RTL must not be presented as working
hardware. This repository therefore presents none.

---

## 2. What would have to exist first

Before any step in §3 can mean anything, the following must exist. None does.

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
3. **A simulator or synthesis tool** (§1) — none is present.

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

### 3.4 Synthesis (requires a vendor toolchain)

```sh
# NOT RUN IN THIS REPOSITORY. Requires Vivado/Quartus, which are not installed.
vivado -mode batch -source synth.tcl     # or quartus_sh --flow compile ...
```

Whatever the tool reports — LUTs, FFs, DSPs, BRAMs, maximum frequency — is a
**tool estimate for a part that was never programmed**, not a property of this
repository. If such figures are ever recorded, they must be recorded with the
exact tool version, part number, and command that produced them, and they still
do not constitute a performance claim. See §5.

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
| A clock frequency ("runs at N MHz") | No synthesis has run; no tool was involved; no part exists. |
| Timing closure of any kind | Never attempted. |
| A silicon performance figure | There is no silicon. |
| A resource-utilisation figure (LUT/FF/BRAM counts) | No synthesis has run. |
| "The RTL works" | No RTL exists. |
| "Verified on an FPGA" | No board, no toolchain. |
| Any speedup or throughput number | Those are simulator instruction counts; see `docs/fidelity.md` §3.4. |

The one honest sentence about Celeris-64 hardware is:

> Celeris-64 is an architecture specification with an executable software model,
> and no hardware implementation exists.

---

## 6. Current status, in one line

**Phase 4 is NOT STARTED.** No `rtl/` directory exists, no RTL simulator or
synthesis tool is installed, no board is attached, and nothing in this document
has been executed.
