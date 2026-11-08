# Celeris-64 Fidelity Ledger

Document Version: 1.0
Status: **Consolidated honesty record.**

This document exists because this repository describes a processor that does not
exist. Every number in it is either a count taken from a software model, or the
word **unverified**. Nothing here was measured on silicon, because there is no
silicon.

It mirrors `docs/isa-encoding.md` §8, which is the normative fidelity statement.
Where the two disagree, §8 wins and this document is a bug.

**Rule for every row below:** a claim with no command behind it says
`unverified` in the Evidence column. That word is the most useful thing in this
file; an empty cell pretending to be coverage is the failure mode this document
was written to prevent.

---

## 1. How to reproduce every number here

All figures were produced on this machine with these commands. Re-run them; if
your counts differ, yours are correct and this table is stale.

```sh
# Toolchain. There is NO system `zig` on PATH.
~/.local/zig/zig version            # -> 0.17.1

# Clean-room build and full test suite.
rm -rf .zig-cache zig-out
~/.local/zig/zig build              # -> exit 0
~/.local/zig/zig build test --summary all
# -> Build Summary: 33/33 steps succeeded; 258/258 tests passed

# A single module's tests, independently of the build graph.
~/.local/zig/zig test src/<module>.zig

# The benchmark, which is runnable.
~/.local/zig/zig build bench
```

Observed on the tree at the time of writing: `zig build` exits 0, and
`zig build test` reports **33/33 steps, 258/258 tests passed, exit 0**.

### Toolchain facts

| Fact | Value |
|------|-------|
| Zig version | `0.17.1` (`~/.local/zig/zig version`) |
| Install path | `~/.local/zig/zig`, symlink to `~/.local/zig-x86_64-linux-0.17.1` |
| System `zig` on `PATH` | **No.** Every command in this repo must use the full path. |
| Installed with | Official tarball unpacked into `~/.local`. No `sudo` was used or available. |

---

## 2. Subsystem status

Legend for **What it is**:

- **Executable model** — real behaviour computed in software, fully tested. This
  is the strongest claim in this repository, and it still means "software".
- **Software model** — implements as much of a declared contract as software
  can, with limits that are named in the file and cited below.
- **Spec artifact** — a document or description, not running code.
- **Not started** — does not exist.

| Subsystem | What it is | Evidence (command actually run) | Observed result |
|-----------|------------|--------------------------------|-----------------|
| Register file (`src/registers.zig`) | Executable model | `~/.local/zig/zig test src/registers.zig` | All 8 tests passed |
| Flat memory (`src/memory.zig`) | Executable model | `~/.local/zig/zig test src/memory.zig` | All 4 tests passed |
| ALU + fetch/decode/execute (`src/vm.zig`) | Executable model | `~/.local/zig/zig test src/vm.zig` | All 67 tests passed |
| Decoder (`src/decoder.zig`) | Executable model | `~/.local/zig/zig test src/decoder.zig` | All 22 tests passed |
| `stream.*` engine (`src/stream.zig`) | Executable model | `~/.local/zig/zig test src/stream.zig` | All 12 tests passed |
| `select.*` / `compare` (`src/select.zig`) | Executable model | `~/.local/zig/zig test src/select.zig` | All 6 tests passed |
| `field.*` slicing (`src/field.zig`) | Executable model | `~/.local/zig/zig test src/field.zig` | All 7 tests passed |
| Diagnostics (`src/diagnostics.zig`) | Executable model | `~/.local/zig/zig test src/diagnostics.zig` | All 8 tests passed |
| Assembler (`src/assembler.zig`) | Executable model | `~/.local/zig/zig test src/assembler.zig` | All 26 tests passed |
| Disassembler (`src/disassembler.zig`) | Executable model | `~/.local/zig/zig test src/disassembler.zig` | All 46 tests passed |
| CLI (`src/main.zig`) | Executable model | `./zig-out/bin/celeris64 run prog.asm` | exit 0, halts with a simulator instruction count |
| Capability pointers (`src/capability.zig`) | **Software model** — see §3.1 | `~/.local/zig/zig test src/capability.zig` | All 9 tests passed |
| SMT threads (`src/thread.zig`) | **Software model** — see §3.2 | `~/.local/zig/zig test src/thread.zig` | All 15 tests passed |
| `matrix.*` (`src/matrix.zig`) | Functional model — no acceleration, no cycle claims | `~/.local/zig/zig test src/matrix.zig` | All 7 tests passed |
| `fft.*` (`src/fft.zig`) | Functional model — no acceleration, no cycle claims | `~/.local/zig/zig test src/fft.zig` | All 8 tests passed |
| `codec.*` (`src/codec.zig`) | Functional model — see §3.3 | `~/.local/zig/zig test src/codec.zig` | All 10 tests passed |
| UI layout (`src/stdlib_ui.zig`) | Software model — no GPU, no framebuffer, no display | `~/.local/zig/zig test src/stdlib_ui.zig` | All 7 tests passed |
| Graphics (`src/stdlib_gfx.zig`) | Software model — writes an ordinary byte buffer, no rasteriser | `~/.local/zig/zig test src/stdlib_gfx.zig` | All 8 tests passed |
| Networking (`src/stdlib_net.zig`) | Software model — **performs no network I/O at all** | `~/.local/zig/zig test src/stdlib_net.zig` | All 13 tests passed |
| Benchmarks (`benchmarks/bench.zig`) | Advisory simulator counts only | `~/.local/zig/zig build bench` | 4 tests passed; prints 8 lines, each containing "simulated" |
| Independent verifier suite (`tests/vm_tests.zig`) | Executable model | `~/.local/zig/zig build test` | 37 tests passed |
| RTL / SystemVerilog (`rtl/`) | **Not started** | `ls rtl/` | **No such directory.** See §4. |
| FPGA procedure | **Spec artifact, NOT EXECUTED** | see `docs/fpga-prototyping.md` | **Never run.** No toolchain. See §4. |

---

## 3. Named model limits

These are the claims most likely to be misread, so they are stated here in the
same words as the code, with the test that makes each one auditable.

### 3.1 Capability pointers are NOT a security boundary

`src/capability.zig` is a software model of a CHERI-style descriptor.

- It is **not cryptography**. There is no tag bit, no sealing, no provenance.
- It is **not unforgeable**. A caller can write a `Capability{ .base = …,
  .length = … }` literal by hand and the model cannot tell.
- It is **not a security boundary** and must never be described as one.

Auditable by test: **`MODEL LIMITS: this is not cryptography and does not resist
forgery`** (`src/capability.zig`). That test constructs a forged descriptor which
real CHERI hardware would reject and asserts this model accepts it.

What it *does* provide: bounds and permission checks at one choke point, so an
access either names its authority or fails with a plain-language diagnostic. That
is useful for testing program logic. It is not useful against an attacker.

### 3.2 SMT threads are INTERLEAVED, not parallel

`src/thread.zig` models eight slots `T0`–`T7` with private register files.

- The slots are stepped **one at a time on a single OS thread**. No concurrency
  exists anywhere in this repository.
- It does **not** model shared L1/L2 caches, DRAM latency, or latency hiding,
  which is the entire architectural point of hardware SMT (spec §4.1).
- "Zero-cycle switching" is an aspiration of the specification. Nothing here
  measures cycles, and no cycle figure is claimed.

Auditable by test: **`MODEL LIMITS: this is interleaving, not parallelism`**
(`src/thread.zig`).

### 3.3 Hash and checksum are NOT authentication

`src/codec.zig` provides an FNV-1a hash and a checksum.

- They are **not collision-resistant against a motivated attacker**.
- They are **not keyed** and are **not a MAC**.
- They detect accidental corruption. They do not authenticate anything.

Auditable by test: **`MODEL LIMITS: these are integrity checks, not
authentication`** (`src/codec.zig`).

### 3.4 Benchmark figures are instruction counts in a model

`benchmarks/bench.zig` compares a `stream.*` batch against an element-by-element
loop. Both are real Celeris-64 programs executed by `src/vm.zig`.

Observed output (`~/.local/zig/zig build bench`):

```
Celeris-64 benchmark: simulated instruction counts only.
This simulated report comes from a software model, not from silicon.
No simulated figure was measured on hardware; no hardware exists.
A simulated count is not a claim about any physical device.
  stream batch: 4 simulated instructions retired to process 8 elements (0.50 simulated instructions per element).
  element-by-element loop: 11 simulated instructions retired to process 8 elements (1.38 simulated instructions per element).
The simulated difference above is a property of the simulated stream.
It is a simulated count of instructions, not a claim about speed.
```

These are retired-instruction counts. They are **not** cycles, **not** a clock
frequency, **not** IPC, and **not** a speedup. Two tests enforce that
permanently: one asserts every non-blank output line contains the word
"simulated", and one asserts no line contains "speedup", "faster", "%", "cycle"
or "throughput".

Verified mechanically, not by eye:

```sh
~/.local/zig/zig build bench 2>&1 | grep -v "^$" > /tmp/bench.txt
grep -iv "simulated" /tmp/bench.txt                              # -> no matches (8/8 lines carry it)
grep -inE "speedup|faster|%|cycle|throughput|ghz" /tmp/bench.txt # -> no matches
```

---

## 4. RTL and FPGA: deliberately not started

| Item | Status |
|------|--------|
| `rtl/` SystemVerilog | **Does not exist.** No directory, no file. |
| Verilator | **Not installed** (`command -v verilator` -> nothing) |
| Icarus Verilog | **Not installed** |
| Yosys | **Not installed** |
| GTKWave | **Not installed** |
| `sudo` | Unavailable. `sudo -n true` -> "interactive authentication is required". |
| Any synthesis | **Never run.** |
| Any timing closure | **Never attempted.** |
| Any FPGA or silicon | **Never happened.** |

Verilator can in principle be built from source into `~/.local`, but on this
machine no RTL simulator or synthesis tool exists, so **any RTL written here
would be unverified**. Per the task contract, unverified RTL must not be
presented as hardware. The honest state is therefore: **not started**, and
`docs/fpga-prototyping.md` records a procedure that has **not been executed**.

**No clock frequency, timing figure, area figure or silicon performance claim
appears anywhere in this repository.** If one is ever added, it is a bug.

---

## 5. Two commands that look broken but are not

Both of these fail by design. They are not defects; do not "fix" them.

```sh
$ ~/.local/zig/zig test tests/vm_tests.zig
tests/vm_tests.zig:40:20: error: no module named 'vm' available within module 'test'
```

```sh
$ ~/.local/zig/zig test benchmarks/bench.zig
benchmarks/bench.zig:23:20: error: no module named 'vm' available within module 'test'
```

Both files reach the `src/` graph under the module name `vm`, which only
`build.zig` can inject (Zig 0.17.1 refuses `@import("../../src/vm.zig")` — a file
may not be imported from outside its module root). Use `zig build test` instead,
which supplies the module.

---

## 6. Gaps, stated plainly

These are the honest holes. None of them is hidden behind a passing test count.

### 6.1 cap.* and thread.* status

| | |
|---|---|
| `thread.spawn` / `thread.join` / `thread.yield` (0x90–0x92) | **Executed** as of task-19. Wired into the VM against the `thread.zig` scheduler. This is a **deterministic modelled interleave** — no timing, no real concurrency, no speedup claim. |
| `cap.check` (0x52) | **In flight** at the time of writing — task-20 was wiring it. Do not read this row as a completion claim; check `src/vm.zig` for a `.cap_check` dispatch arm before relying on it. |
| `cap.load` / `cap.store` (0x50–0x51) | **Decode-only by ruling** (§3.5 Amendment 1.11). The encoding carries no address field, so the simulator refuses them rather than guessing. |
| Accelerator range 0x60–0x8F (`matrix.*`, `fft.*`, `codec.*`) | Models exist and are tested. **Not assemblable from source, and not executed.** The decoder does build a real payload for these words; see §6.2. |

The original form of this section said all of the above were "not wired into the
VM". That was true when written and is no longer true for `thread.*`, so it is
recorded here rather than silently edited away.

Observed behaviour today, from the CLI — an accelerator word, which remains
decode-only and is the honest example now that `thread.*` executes:

```
$ ./zig-out/bin/celeris64 run accel.asm       # a hand-built 0x60 word; halt
error: at PC 0: while executing this instruction the instruction word
0x6012000000000005 could not be decoded. Expected an instruction this simulator
implements. This opcode is defined by the encoding contract but is not wired into
this build yet.
$ echo $?
1
```

That is **not a crash and not a silent success**: it is a plain-language
diagnostic naming the opcode and the PC, with a non-zero exit. Not wired is not
the same as broken.

*(The earlier revision of this section showed the same transcript for
`cap.check`. That example is no longer representative: `cap.check` is being wired
into the VM under task-20, so quoting it here would be stale. The `cap.*` row in
the table above is the current statement of its status.)*

The assembler is stricter still: `matrix.invert R0, R1` is **not assemblable at
all** and is reported as an unknown mnemonic, because §3.6 leaves the operand
field to the model modules and this build does not define it.

### 6.2 `encode(decode(w)) == w` is tested only for words the parameter is defined on

`src/decoder.zig` has `encode`, and the disassembler round-trip (asm → decode →
asm, byte-identical) is proven for every opcode in the §3 map. It is **not**
proven for the accelerator range.

**Correction (v1.11 docs pass).** An earlier revision of this line said the
accelerator range "cannot be decoded". That is wrong, and it understates what
works: `decoder.zig:407` routes 0x60–0x8F through `isAcceleratorByte` into a real
`.accelerator` payload with its reserved field checked, and `encode` re-emits it
(`decoder.zig:673`). What is actually true is narrower and had two parts:

- **The disassembler** renders those words as `.raw 96, 5` rather than a mnemonic,
  so round-trip is proven at the *word* level, not as re-assemblable text.
- **The assembler** accepts no accelerator mnemonic at all, so such a word cannot
  be produced from source by this toolchain. Reproduced:
  `printf 'codec.enc R0, R1\nhalt\n' > a.asm && celeris64 asm a.asm a.bin` →
  `error: … Expected an instruction mnemonic from the Celeris-64 opcode map`.

The distinction matters because "cannot be decoded" invites the reader to assume
the decoder is incomplete, when the gap is in the textual layer.

### 6.3 This is a single-threaded interpreter

The whole simulator is one in-order loop. It is **not** a JIT, **not** parallel,
and **not** fast. No performance claim of any kind is made, and none could be
supported.

---

## 7. Mandate audit

Checked against `AGENTS.md`, with the command that backs each line.

| Mandate rule | Status | Evidence |
|---|---|---|
| §4.1 Zero dynamic allocation inside the execution loop | **Holds** | `sed -n '/fn execute/,/^    fn /p' src/vm.zig \| grep -nE "alloc\|ArrayList\|append\|create"` -> no matches. Memory is allocated once in `Vm.init`. |
| §4.2 No bare hexadecimal error codes | **Holds** | Ran every CLI error path and grepped the output: `grep -nE '^\s*(0x[0-9a-fA-F]+\|error:\s*0x[0-9a-fA-F]+)\s*$'` -> no matches. A unit test also renders every diagnostic constructor and asserts none is a bare hex token. |
| §4.3 Register spill warning past the 12 GPRs | **Holds** | `./zig-out/bin/celeris64 asm spill.asm spill.bin` prints `warning: … holds 13 live values but Celeris-64 has only 12 general-purpose registers (R0 through R11) …` |
| §2.2 Sub-width writes zero-extend | **Holds** | `~/.local/zig/zig test src/registers.zig` -> includes "sub-width write zero-extends the upper bits (mandatory invariant)" |
| §5.2 Diagnostics are plain language | **Holds** | See §4.2 row. Rendered sentences name the instruction, the operand and what was expected. |

Two defects worth recording, both found by running tests rather than trusting
them:

- The spill warning was **dead code** until it was rewritten: it compared a count
  of distinct register *indices* against 12, but only twelve indices exist, so the
  branch was unreachable and §4.3 was effectively unimplemented. It now measures
  distinct destination registers live within a window.
- `zig build` once exited 0 while compiling **nothing**: the CLI root imported
  only `std`, so the VM graph was never built. A passing build that compiles
  nothing is not a passing build. `zig build test` is the honest signal.

---

## 8. What this project is not

In one list, so no reader has to infer it:

- Not a chip. No silicon exists.
- Not an FPGA design. Nothing is synthesised, none is simulated.
- Not a security product. The capability model is not a boundary (§3.1).
- Not parallel. Threads are interleaved on one OS thread (§3.2).
- Not a benchmark. The numbers are instruction counts in a model (§3.4).
- Not fast, and no claim about speed is made or supported.
- Not a finished ISA. Three opcode families are unwired (§6.1).

It is an executable model of an architecture, with its limits written down.
