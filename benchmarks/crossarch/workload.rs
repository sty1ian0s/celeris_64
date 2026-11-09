// Celeris-64 cross-architecture comparison: Rust implementation.
//
// Workload, mirroring benchmarks/bench.zig: add 5 to each of 8 u64 elements.
//
//   batch  - one call processes the whole contiguous buffer (the shape CLS64's
//            stream engine expresses in a single instruction).
//   scalar - eight separate calls, one element each, each paying its own call
//            and loop overhead.
//
// NOTE (F32): this comment previously ended "...with the loop overhead that
// CLS64's element-by-element path also pays". That equivalence was false. The C
// scalar path really does pay call and loop overhead; the CLS64 "element-by-
// element" path does not, because it is the SAME `stream.add` issued once per
// element with no loop around it. The two columns are not the same shape and the
// figures must not be paired. See docs/comparison.md §7.
//
// The two shapes are kept apart with #[inline(never)] and a runtime element
// count the compiler cannot constant-fold, because with both inlined the
// optimiser vectorises them into IDENTICAL SIMD loops and the distinction
// vanishes. That collapse was observed in the C build, not assumed: see
// docs/comparison.md §"the collapse finding".
//
// HONESTY: the numbers this program prints are REAL wall-clock nanoseconds on
// REAL silicon. CLS64 reports a count of retired instructions in a simulator.
// The two are NOT comparable for speed, and this program does not claim they are.
//
// Build: rustc -O -o workload_rust workload.rs

use std::time::Instant;

const ELEMENTS: usize = 8;
const ITERATIONS: u64 = 10_000_000;
const ADDEND: u64 = 5;

// Element counts arrive through a black_box so no compiler can fold the loops
// into constants or merge the two shapes into one.
#[inline(never)]
fn batch_add(buf: &mut [u64], addend: u64) {
    let n = std::hint::black_box(buf.len());
    for i in 0..n {
        buf[i] = buf[i].wrapping_add(addend);
    }
}

// Element-by-element path: ONE element per call, so each element pays its own
// call and loop overhead. This is the asymmetry CLS64 models as 11 versus 3.
#[inline(never)]
fn scalar_add_one(buf: &mut [u64], i: usize, addend: u64) {
    let idx = std::hint::black_box(i);
    let v = buf[idx];
    let v = v.wrapping_add(addend);
    buf[idx] = v;
}

fn main() {
    let mut buf = vec![0u64; ELEMENTS];
    let mut reference = vec![0u64; ELEMENTS];

    // Batch: one call covers all ELEMENTS.
    let t0 = Instant::now();
    for _ in 0..ITERATIONS {
        batch_add(&mut buf, ADDEND);
    }
    let batch_ns = t0.elapsed().as_nanos() as f64 / ITERATIONS as f64;

    // Scalar: ELEMENTS separate calls, one element each.
    let t2 = Instant::now();
    for _ in 0..ITERATIONS {
        for i in 0..ELEMENTS {
            scalar_add_one(&mut reference, i, ADDEND);
        }
    }
    let scalar_ns = t2.elapsed().as_nanos() as f64 / ITERATIONS as f64;

    // The two paths must produce identical buffers, or the timing compares
    // different amounts of work and means nothing.
    let equal = buf == reference;

    println!("crossarch workload: add {} to each of {} u64 elements", ADDEND, ELEMENTS);
    println!("language: Rust (rustc), compiled -O, REAL wall-clock on REAL silicon");
    println!("iterations: {}", ITERATIONS);
    println!("  batch  : {:.2} ns per {}-element pass (measured, real hardware)", batch_ns, ELEMENTS);
    println!("  scalar : {:.2} ns per {}-element pass (measured, real hardware)", scalar_ns, ELEMENTS);
    println!(
        "  equivalence: batch result {} scalar result ({} vs {})",
        if equal { "EQUALS" } else { "DIFFERS FROM" },
        buf[ELEMENTS - 1],
        reference[ELEMENTS - 1]
    );
    if !equal {
        println!("  VERDICT: FAIL - the two paths did different work; timings are void.");
        std::process::exit(2);
    }
    println!("NOTE: these are measured nanoseconds. CLS64 reports simulated instruction");
    println!("      counts. The two units are different and are not compared for speed.");
}
