# Cross-Architecture Comparison

This document reports what `benchmarks/crossarch/workload.c` and
`benchmarks/crossarch/workload.rs` measure, side by side with what CLS64's own
benchmark reports. Both source files cite this document by name, and this
document exists so that citation resolves.

**Read this before reading any number below.** The CLS64 column and the C/Rust
columns are **different physical quantities**. They are printed next to each
other because they describe the *same workload*, not because they are
comparable. There is no speedup figure anywhere in this repository, and none can
be derived from these tables.

---

## 1. The three axes

| Axis | What is measured | Unit | Physical? |
|---|---|---|---|
| **C (gcc -O2)** | wall-clock elapsed per pass | nanoseconds | **Yes** — real hardware |
| **Rust (rustc -O)** | wall-clock elapsed per pass | nanoseconds | **Yes** — real hardware |
| **CLS64** | instructions retired by `src/vm.zig` | instruction count | **No** — software model |

Axis 3 is not a slower version of axes 1 and 2; it is a different kind of
quantity. A retired-instruction count says nothing about cycles, IPC, clock
rate, cache behaviour, or real-world throughput. No CLS64 silicon exists.

### Environment for the measured axes

Recorded so the numbers are traceable to a machine, not to an impression.

| Fact | Value |
|---|---|
| CPU | AMD Ryzen 7 7800X3D 8-Core Processor, 16 threads |
| C compiler | gcc (Ubuntu 15.2.0-16ubuntu1) 15.2.0 |
| Rust compiler | rustc 1.99.1 (58cf8f9c3 2026-10-13) |
| Timer | `CLOCK_MONOTONIC` (C), `std::time::Instant` (Rust) |
| Iterations | 10,000,000 per path |
| Elements | 8 × `u64` |

---

## 2. The workload

Both languages and the CLS64 model express the **same** computation: add 5 to
each of 8 contiguous `u64` elements.

Two shapes are timed, and the shape is the entire point of the comparison:

- **batch** — one call processes the whole contiguous buffer. This is the shape
  CLS64's stream engine expresses in a single instruction.
- **scalar** — eight separate calls, one element each, each paying its own call
  and loop overhead. This is the shape CLS64's element-by-element path also pays.

---

## 3. Measured results

### 3.1 Real silicon — C and Rust

Measured on the machine above. Several runs, all of them reported, because a single
run presented as "the" number would overstate the precision this measurement has:

| Run | C batch | C scalar | Rust batch | Rust scalar |
|---|---|---|---|---|
| 1 | 2.00 ns | 9.03 ns | 1.77 ns | 8.15 ns |
| 2 | 2.22 ns | 8.88 ns | 1.93 ns | 7.81 ns |
| 3 | 2.49 ns | 9.00 ns | 2.03 ns | 7.66 ns |

`equivalence: batch result EQUALS scalar result (50000000 vs 50000000)` in **all**
runs, both languages.

The batch path moved 25% across three consecutive runs on an idle machine; the
scalar path moved about 15%. These are not stable measurements, and the table is
here so that nobody quotes row 1 as though it were a benchmark result.

No confidence interval was computed and no run was discarded. **Treat every figure
here as an order-of-magnitude observation, not a benchmark result.** The programs
print two decimal places because that is what they print, not because the
measurement supports two decimal places of stability.

### 3.2 Software model — CLS64

From `zig build bench` (output abridged; every emitted line contains the word
"simulated"):

```
  stream batch: 4 simulated instructions retired to process 8 elements
                (0.50 simulated instructions per element)
  element-by-element loop: 11 simulated instructions retired to process 8 elements
                (1.38 simulated instructions per element)
```

**These numbers were 3 and 11 until this document was written**, and the correction
is worth recording here rather than buried in a commit. Both benchmark programs
pointed their stream at address 0 — their own first instruction — so `stream.add`
added the addend into the program's own code as it ran. The batch program's `halt`
word was corrupted, stopped decoding, and ended the run one instruction early:
it reported **3** where the program contained 4. The scalar program corrupts its
own code too but stops short of its `halt`, so its 11 was right by accident.

The defect is recorded as **F17** in `docs/STATUS.md`; the fix moves the stream
pointer past the program. Anyone quoting an instruction count from this repository
should confirm it postdates that fix.

### 3.3 The two tables must not be divided

The batch/scalar *ratio* in §3.1 is a timing ratio on real silicon. The
batch/scalar *ratio* in §3.2 is a count ratio in a simulator. Dividing one by
the other, or presenting either as evidence for the other, produces a number
that means nothing. No such derivation appears here, and none should be added.

---

## 4. The collapse finding

Both `workload.c` and `workload.rs` cite this section. It records a defect found
in the first version of this comparison **and re-verified while writing this
document**, not an assumption.

### What went wrong

The first version of the C workload wrote both paths as ordinary static
functions and let the compiler inline them. GCC inlined both into `main`,
recognised both as the same 8-element add, and **vectorised both into identical
SIMD loops**. The two "shapes" became the same machine code, and the comparison
measured nothing at all — while still printing two different-looking numbers,
because the second loop carried more interpreted overhead around identical work.

Worse, in that version the **batch path measured slower than the scalar path** —
the signature of a comparison that has been optimised into meaninglessness. A
plausible-looking result, from a program doing no comparison.

### How it was reproduced

Rebuilt from source at the time of writing, inspecting generated assembly:

| Build | `paddq` count in generated assembly |
|---|---|
| both paths inlined, no guards | **2** |
| both paths kept separate (`noinline` + `black_box`) | **0** |

Two `paddq` in the inlined build is the collapse: both paths became the same
packed-`add`-quadword SIMD loop. Zero in the guarded build means the shapes are
genuinely distinct code.

### The fix, and why it is load-bearing

Every loader-shaped detail in these two files is defensive, and removing any of
it silently restores the defect:

- `__attribute__((noinline))` / `#[inline(never)]` — keeps the two call shapes
  distinct instead of merging them.
- `volatile` element count (C) / `std::hint::black_box` (Rust) — stops the
  compiler constant-folding the loops or collapsing them into one.
- Separate source buffers per path, compared element-wise at the end — the
  `equivalence: ... EQUALS` line is a **falsification check, not decoration**.
  If either path is ever optimised into doing different work, it prints
  `DIFFERS FROM`, exits 2, and the timings are declared void.

Symbol survival was confirmed, not assumed: `nm` shows `batch_add` and
`scalar_add_one` present as distinct symbols in **both** the C and Rust
binaries.

### What this finding generalises to

A timing comparison between two code shapes is only meaningful if you have
demonstrated the two shapes still differ *in the generated code*. The original
version of this benchmark was wrong in the specific way benchmarks are usually
wrong: it reported numbers, the numbers looked reasonable, and nothing checked
that the work differed. The `EQUALS`/`DIFFERS` check exists because
"the numbers looked fine" is not evidence.

---

## 5. What this document does not claim

- Not that CLS64 is fast, slow, or comparable to anything. No silicon exists.
- Not that 4-vs-11 instructions implies any timing ratio on any implementation.
- Not that the C or Rust figures are reproducible to better than about 25% per pass
  on identical hardware; the three runs above are the evidence for that limit.
- Not that the scalar/batch gap is a property of CLS64's design. It is a
  property of *call granularity*, which both the model and the compilers
  reproduce independently.
- Not a speedup. There is no speedup figure in this repository.

---

## 6. Reproducing

```sh
# Measured axes — real hardware
gcc -O2 -Wall -Wextra -o workload_c benchmarks/crossarch/workload.c && ./workload_c
rustc -O -o workload_rust benchmarks/crossarch/workload.rs && ./workload_rust

# Simulated axis — software model
zig build bench

# Collapse finding: 2 with guards removed, 0 with them present
gcc -O2 -S -o - benchmarks/crossarch/workload.c | grep -c paddq
```

---

## 7. Limitation found while preparing an encoding-density comparison (F32)

An attempt to add a fourth axis — **encoding density**, the honest static comparison
against RISC-V, x86-64 and ARM64 that needs no silicon — was abandoned partway, and
the reason is a finding about this document rather than about those architectures.

### 7.1 The measurement was not possible here

No ARM or RISC-V toolchain is installed on this host (`aarch64-linux-gnu-gcc` and
`riscv64-linux-gnu-gcc` are both absent; only `x86_64-unknown-linux-gnu` Rust std is
present). Instruction counts for those ISAs therefore could not be **measured**, and
stating them from memory would have been exactly the fabricated figure this repository
forbids. The axis is not wrong — it is unmeasured, and it is recorded as unmeasured.

### 7.2 The scalar shape in §2 is not the shape §2 describes

More seriously: checking this document's own claim about the CLS64 axis found that
**the two rows are not two shapes of the same work.**

§2 says:

> **scalar** — eight separate calls, one element each, each paying its own call and
> loop overhead. This is the shape CLS64's element-by-element path also pays.

and `benchmarks/bench.zig` says:

> Element-by-element path: an explicit software loop, one element per iteration.
> ... `chunk` separate load/add/store triples: no fused engine, one element each.

**Neither sentence is true of the code.** `scalarWords` emits `vm.encode(0x40, 0, 1,
streamOperand(2, 1, .full))` — opcode `0x40` is `stream.add`, *the fused engine*, with
`chunk = 1`. The batch path emits the same `0x40` with `chunk = 8`. There is no
software loop in either program and no unfused load/add/store triple in either; the
words are identical except for the chunk field.

So the 4-vs-11 difference measures **how many times the same instruction is issued**,
and it is pure arithmetic. Both programs are `mov`, `mov`, then N copies of
`stream.add`, then `halt`:

| Path | N | Retired | Formula |
|---|---|---|---|
| batch | 1 (`chunk = 8`) | 4 | `3 + 1` |
| scalar | 8 (`chunk = 1` each) | 11 | `3 + chunk` |

At `chunk = 1` the two paths retire the **same** 4 instructions, which is the clearest
statement of the problem: the "scalar" path is the batch path with a smaller chunk. The
difference is a property of the *call granularity in the benchmark source*, not of the
stream engine, because the engine is used identically in both programs.

### 7.3 Why the "collapse finding" in §4 does not cover this

§4 records that C and Rust collapse two shapes into identical SIMD loops unless
`noinline` and a volatile element count keep them apart, and that finding is real and
was re-verified. It does not apply here: the C and Rust programs have two genuinely
different bodies, while the two CLS64 programs have **one** body issued a different
number of times. §4's guards make the C/Rust distinction real. Nothing makes the CLS64
distinction real, because there is no second shape in the program.

### 7.4 Why a true scalar shape cannot currently be written

The honest fix would be to write the element-at-a-time path using load and store
instructions, as the C and Rust scalar paths do. **CLS64 has no general-purpose load or
store instruction.** Every memory access in the §3 opcode map is one of:

| Opcode | Mnemonic | Memory role |
|---|---|---|
| `0x40` | `stream.add` | fused load/add/store over a chunk |
| `0x41` | `stream.copy` | fused load/store over a chunk |
| `0x42` | `stream.fill` | fused store of a scalar over a chunk |
| `0x50` | `cap.load` | loads a **capability**, decode-only (§3.5, v1.12) |
| `0x51` | `cap.store` | stores a **capability**, decode-only |

There is no `load`, no `store`, and no memory operand form: `mov R5, [R4]` is rejected
by the assembler. So a single-element fetch-and-replace, expressed without the stream
engine, **is not expressible in this ISA at all.**

That is a contract-level gap, not a benchmark bug, and it is the stronger finding: the
architecture's central claim is that `stream.*` removes loop overhead, but the
comparison offered as evidence cannot exhibit a non-`stream.*` baseline because the ISA
provides no way to write one.

### 7.5 What may and may not be said

- **May be said:** the simulator retires 4 instructions for a `chunk = 8` `stream.add`
  and 11 for eight `chunk = 1` issues of the same instruction.
- **May not be said:** that this is a speedup, that it is the stream engine's advantage,
  or that it evidences §1.2's claim about loop overhead. The engine is on both sides.
- **Not measured:** encoding density against RISC-V, x86-64 or ARM64; no toolchain.

**Status: open.** Closing this needs either a load/store instruction in the ISA (a
contract change) or a restatement of §2 that names the two rows for what they are —
the same instruction at two granularities.

---

## 8. Four ISAs, one measurement loop (F33)

Sections 1–7 compare CLS64 against C and Rust *wall-clock times*, which is not a
like-for-like comparison and never could be: one column is nanoseconds on real
silicon, the other is a counter in this repository's own simulator. §7 records that
the density axis could not be added because no ARM or RISC-V toolchain is
installed.

**The rows below are different.** All four are produced by the *same* execution
loop running *real machine code*, so the counts are commensurable in a way §3's
were not.

```sh
zig build crossarch
```

| ISA | shape | retired | code bytes | bytes/insn |
|---|---|---|---|---|
| Celeris-64 CLS64 | batch | **4** | 32 | 8.00 |
| RISC-V RV64I | batch | 54 | 216 | 4.00 |
| AArch64 A64 | batch | 60 | 240 | 4.00 |
| x86-64 | batch | 52 | 167 | **3.21** |
| Celeris-64 CLS64 | scalar | 11 | 88 | 8.00 |
| RISC-V RV64I | scalar | 55 | 220 | 4.00 |
| AArch64 A64 | scalar | 61 | 244 | 4.00 |
| x86-64 | scalar | 60 | 207 | **3.45** |

Same workload as §2: add 5 to each of 8 contiguous `u64` elements. Every program's
resulting memory is compared against the others, so a program that ran but computed
something else cannot appear as an equal participant.

### 8.1 What is measured, and what still is not

**Measured:** retired instructions, and the bytes those instructions occupied as
encoded. Both are properties of the program.

**Not measured — and this is deliberate:** cycles, time, clock frequency,
throughput, speed. Assigning a cycle cost per instruction would mean inventing a
microarchitecture for CPUs that are not present in this repository. The invention
would be the author's design choice, and CLS64's own number would come from the same
invention — so the result would look like a fair fight while being a statement about
the model. `src/isaharness.zig` therefore has no field of any kind for a timing
quantity, and a test fails if one is added.

**§3's rule still applies to §3's table.** The batch/scalar *ratios* in §3.1 are
timing ratios and the ones here are count ratios; they are still not divisible.

### 8.2 What the numbers may and may not be taken to mean

- **May be said:** for this workload, CLS64 retires 4 instructions where RISC-V
  retires 54, AArch64 60 and x86-64 52.
- **May not be said:** that CLS64 is 13× faster. Nothing here is a speed
  measurement. An instruction in one ISA is not an instruction in another: one
  `stream.add` moves 8 elements where one `ld` moves 1.
- **May be said:** x86-64 has the densest encoding here (3.21 bytes/instruction),
  because it is the only variable-length ISA in the set and its short forms are
  genuinely short.
- **May not be said:** that x86-64 is therefore better. Density is one axis, and
  this table measures no other.
- **A real caveat:** the four programs were written *by hand* for this repository,
  not emitted by an optimising compiler. A different hand-written program would
  produce different counts for the same ISA. The C and Rust columns in §3 exist
  precisely because hand-written assembly is not what anyone ships.

### 8.3 The F32 caveat applies to CLS64's rows

§7 records that CLS64's "batch" and "scalar" programs are the **same instruction at
two granularities**, not two shapes. That remains true here: the CLS64 scalar row is
`stream.add` with `chunk = 1` issued eight times, not an unfused load/add/store
loop. RISC-V, AArch64 and x86-64's scalar rows *are* genuine loops. **The CLS64
scalar row is therefore not comparable to the other scalar rows**, and the honest
fix is still the one §7 names: a load/store instruction in the ISA, or a restatement
of §2.

### 8.4 How the executors are verified

Three new decoders were written for this section, which is a large amount of new
code and therefore a large amount of new risk. They are checked **against an
independent implementation**, not against themselves:

```sh
# The encodings in the tests came from this, and are pasted verbatim:
echo "addq %rcx, %rax" | llvm-mc -triple=x86_64  -show-encoding
echo "add x0, x1, x2"  | llvm-mc -triple=aarch64 -show-encoding
echo "add a0, a1, a2"  | llvm-mc -triple=riscv64 -show-encoding
```

A decoder and an encoder that share a wrong idea of an encoding agree with each
other perfectly and with no real tool. Three real bugs were found this way that all
self-consistency tests had passed:

1. **RISC-V immediates** were sign-extended by shifting up but never back, so a
   `-8` branch offset decoded as `4194304` and sent the PC far outside the image.
   The same bug was present in the AArch64 decoder.
2. **x86-64 `0xC7`** was grouped with the group-1 ALU opcodes, so `movq $5, %rax`
   executed as an `ADD`.
3. **x86-64 SIB addressing** read a `disp32` for every `mod == 0` SIB operand,
   swallowing the following instruction's bytes.

Each is recorded in `docs/STATUS.md` as F33 with the mutation that catches it.

**Status:** measured, and still not a performance claim. See
`docs/fidelity.md` for the repository-wide fidelity rules these tables obey, and
`docs/isa-encoding.md` §8 for the model-vs-silicon distinction that governs the
CLS64 column.
