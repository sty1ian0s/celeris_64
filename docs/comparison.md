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

**Status:** measurement notes, not a performance claim. See
`docs/fidelity.md` for the repository-wide fidelity rules these tables obey, and
`docs/isa-encoding.md` §8 for the model-vs-silicon distinction that governs the
CLS64 column.
