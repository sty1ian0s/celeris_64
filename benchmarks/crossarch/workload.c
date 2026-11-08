// Celeris-64 cross-architecture comparison: C implementation.
//
// Workload, mirroring benchmarks/bench.zig: add 5 to each of 8 u64 elements.
//
//   batch  - one call processes the whole contiguous buffer (the shape CLS64's
//            stream engine expresses in a single instruction).
//   scalar - eight separate calls, one element each, with the loop overhead
//            that CLS64's element-by-element path also pays.
//
// The two shapes are kept apart with `noinline` and a passed-in element count
// the compiler cannot constant-fold, because with both inlined GCC vectorises
// them into IDENTICAL SIMD loops and the distinction vanishes. That collapse was
// observed, not assumed: see docs/comparison.md §"the collapse finding".
//
// HONESTY: the numbers this program prints are REAL wall-clock nanoseconds on
// REAL silicon. That is the opposite of what CLS64 reports, which is a count of
// retired instructions in a simulator. The two are NOT comparable for speed, and
// this program makes no claim that they are.
//
// Build: gcc -O2 -o workload_c workload.c

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

#define ELEMENTS 8
#define ITERATIONS 10000000ull
#define ADDEND 5ull

// Element counts arrive through a volatile so no compiler can fold the loops
// into constants or merge the two shapes into one.
static volatile size_t g_n = ELEMENTS;

// Batch path: one fused pass over the whole contiguous buffer.
__attribute__((noinline)) static void batch_add(uint64_t *restrict buf, size_t n, uint64_t addend) {
    for (size_t i = 0; i < n; i++) {
        buf[i] += addend;
    }
}

// Element-by-element path: ONE element per call, so each element pays its own
// call and loop overhead. This is the asymmetry CLS64 models as 11 instructions
// versus 3.
__attribute__((noinline)) static void scalar_add_one(uint64_t *buf, size_t i, uint64_t addend) {
    uint64_t v = buf[i];
    v = v + addend;
    buf[i] = v;
}

static uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

int main(void) {
    uint64_t *buf = malloc(ELEMENTS * sizeof(uint64_t));
    uint64_t *ref = malloc(ELEMENTS * sizeof(uint64_t));
    if (!buf || !ref) return 1;

    // Batch: one call covers all ELEMENTS.
    for (size_t i = 0; i < ELEMENTS; i++) buf[i] = 0;
    uint64_t t0 = now_ns();
    for (uint64_t it = 0; it < ITERATIONS; it++) {
        batch_add(buf, g_n, ADDEND);
    }
    uint64_t t1 = now_ns();

    // Scalar: ELEMENTS separate calls, one element each.
    for (size_t i = 0; i < ELEMENTS; i++) ref[i] = 0;
    uint64_t t2 = now_ns();
    for (uint64_t it = 0; it < ITERATIONS; it++) {
        for (size_t i = 0; i < ELEMENTS; i++) {
            scalar_add_one(ref, i, ADDEND);
        }
    }
    uint64_t t3 = now_ns();

    // The two paths must produce identical buffers, or the timing compares
    // different amounts of work and means nothing.
    int equal = 1;
    for (size_t i = 0; i < ELEMENTS; i++) {
        if (buf[i] != ref[i]) equal = 0;
    }

    double batch_ns = (double)(t1 - t0) / (double)ITERATIONS;
    double scalar_ns = (double)(t3 - t2) / (double)ITERATIONS;

    printf("crossarch workload: add %llu to each of %d u64 elements\n", (unsigned long long)ADDEND, ELEMENTS);
    printf("language: C (gcc), compiled -O2, REAL wall-clock on REAL silicon\n");
    printf("iterations: %llu\n", (unsigned long long)ITERATIONS);
    printf("  batch  : %.2f ns per %d-element pass (measured, real hardware)\n", batch_ns, ELEMENTS);
    printf("  scalar : %.2f ns per %d-element pass (measured, real hardware)\n", scalar_ns, ELEMENTS);
    printf("  equivalence: batch result %s scalar result (%llu vs %llu)\n",
           equal ? "EQUALS" : "DIFFERS FROM",
           (unsigned long long)buf[ELEMENTS - 1], (unsigned long long)ref[ELEMENTS - 1]);
    if (!equal) {
        printf("  VERDICT: FAIL - the two paths did different work; timings are void.\n");
        free(buf); free(ref);
        return 2;
    }
    printf("NOTE: these are measured nanoseconds. CLS64 reports simulated instruction\n");
    printf("      counts. The two units are different and are not compared for speed.\n");

    free(buf);
    free(ref);
    return 0;
}
