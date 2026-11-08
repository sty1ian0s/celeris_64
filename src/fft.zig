//! Celeris-64 FFT / NTT accelerator model (spec §3.4).
//!
//! ════════════════════════════════════════════════════════════════════════════
//! FIDELITY (docs/isa-encoding.md §8): FUNCTIONAL SOFTWARE MODEL. There is no
//! transform hardware. Every butterfly is computed in scalar Zig on one thread.
//! No cycle count, throughput or speedup is claimed or measurable. The model's
//! value is that its RESULTS agree with an independent naive DFT, which is what
//! the tests below actually check.
//! ════════════════════════════════════════════════════════════════════════════

const std = @import("std");

pub const FftError = error{
    NotPowerOfTwo,
    EmptyInput,
    LengthMismatch,
};

pub fn explain(err: FftError) []const u8 {
    return switch (err) {
        error.NotPowerOfTwo =>
            "The transform was given a sample count that is not a power of two. " ++
                "This radix-2 transform halves the work each pass, which is only possible " ++
                "when the length can be halved down to one.",
        error.EmptyInput =>
            "The transform was given no samples at all. There is nothing to transform.",
        error.LengthMismatch =>
            "The input and output buffers do not hold the same number of samples.",
    };
}

pub const Complex = struct {
    re: f64,
    im: f64,

    pub fn add(a: Complex, b: Complex) Complex {
        return .{ .re = a.re + b.re, .im = a.im + b.im };
    }
    pub fn sub(a: Complex, b: Complex) Complex {
        return .{ .re = a.re - b.re, .im = a.im - b.im };
    }
    pub fn mul(a: Complex, b: Complex) Complex {
        return .{ .re = a.re * b.re - a.im * b.im, .im = a.re * b.im + a.im * b.re };
    }
};

fn isPowerOfTwo(n: usize) bool {
    return n != 0 and (n & (n - 1)) == 0;
}

/// In-place iterative radix-2 Cooley-Tukey FFT.
pub fn fft(data: []Complex, inverse: bool) FftError!void {
    const n = data.len;
    if (n == 0) return error.EmptyInput;
    if (!isPowerOfTwo(n)) return error.NotPowerOfTwo;
    if (n == 1) return;

    // Bit-reversal permutation.
    var i: usize = 1;
    var j: usize = 0;
    while (i < n) : (i += 1) {
        var bit = n >> 1;
        while (j & bit != 0) : (bit >>= 1) j ^= bit;
        j |= bit;
        if (i < j) std.mem.swap(Complex, &data[i], &data[j]);
    }

    const sign: f64 = if (inverse) 1 else -1;

    // Butterfly stages, doubling the span each pass.
    var len: usize = 2;
    while (len <= n) : (len <<= 1) {
        const ang = sign * 2.0 * std.math.pi / @as(f64, @floatFromInt(len));
        const wlen = Complex{ .re = @cos(ang), .im = @sin(ang) };
        var start: usize = 0;
        while (start < n) : (start += len) {
            var w = Complex{ .re = 1, .im = 0 };
            var k: usize = 0;
            while (k < len / 2) : (k += 1) {
                const u = data[start + k];
                const v = data[start + k + len / 2].mul(w);
                data[start + k] = u.add(v);
                data[start + k + len / 2] = u.sub(v);
                w = w.mul(wlen);
            }
        }
    }

    if (inverse) {
        const inv_n = 1.0 / @as(f64, @floatFromInt(n));
        for (data) |*c| {
            c.re *= inv_n;
            c.im *= inv_n;
        }
    }
}

/// Naive O(n^2) DFT. Deliberately the slow, obvious definition: this is the
/// INDEPENDENT REFERENCE the fast path is checked against, so it must not share
/// any code or reasoning with `fft`.
pub fn naiveDft(input: []const Complex, out: []Complex) FftError!void {
    const n = input.len;
    if (n == 0) return error.EmptyInput;
    if (out.len != n) return error.LengthMismatch;

    var k: usize = 0;
    while (k < n) : (k += 1) {
        var sum = Complex{ .re = 0, .im = 0 };
        var t: usize = 0;
        while (t < n) : (t += 1) {
            const ang = -2.0 * std.math.pi * @as(f64, @floatFromInt(k * t)) /
                @as(f64, @floatFromInt(n));
            const w = Complex{ .re = @cos(ang), .im = @sin(ang) };
            sum = sum.add(input[t].mul(w));
        }
        out[k] = sum;
    }
}

/// Number Theoretic Transform over a modulus, for exact integer convolution.
/// Uses a 64-bit prime with a known primitive root so results are exact.
pub const ntt_modulus: u64 = 998_244_353; // 119 * 2^23 + 1
pub const ntt_root: u64 = 3;

fn modPow(base: u64, exp: u64, m: u64) u64 {
    var result: u64 = 1;
    var b = base % m;
    var e = exp;
    while (e > 0) {
        if (e & 1 == 1) result = (result * b) % m;
        b = (b * b) % m;
        e >>= 1;
    }
    return result;
}

fn modInverse(a: u64, m: u64) u64 {
    // m is prime, so a^(m-2) is the inverse by Fermat's little theorem.
    return modPow(a, m - 2, m);
}

pub fn ntt(data: []u64, inverse: bool) FftError!void {
    const n = data.len;
    if (n == 0) return error.EmptyInput;
    if (!isPowerOfTwo(n)) return error.NotPowerOfTwo;
    const m = ntt_modulus;

    var i: usize = 1;
    var j: usize = 0;
    while (i < n) : (i += 1) {
        var bit = n >> 1;
        while (j & bit != 0) : (bit >>= 1) j ^= bit;
        j |= bit;
        if (i < j) std.mem.swap(u64, &data[i], &data[j]);
    }

    var len: usize = 2;
    while (len <= n) : (len <<= 1) {
        // For the inverse, use the modular inverse of the root.
        var wlen = modPow(ntt_root, (m - 1) / @as(u64, @intCast(len)), m);
        if (inverse) wlen = modInverse(wlen, m);

        var start: usize = 0;
        while (start < n) : (start += len) {
            var w: u64 = 1;
            var k: usize = 0;
            while (k < len / 2) : (k += 1) {
                const u = data[start + k];
                const v = (data[start + k + len / 2] * w) % m;
                data[start + k] = (u + v) % m;
                data[start + k + len / 2] = (u + m - v) % m;
                w = (w * wlen) % m;
            }
        }
    }

    if (inverse) {
        const n_inv = modInverse(@intCast(n), m);
        for (data) |*v| v.* = (v.* * n_inv) % m;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectClose(expected: f64, actual: f64) !void {
    try testing.expect(@abs(expected - actual) < 1e-9);
}

test "non-power-of-two input is refused" {
    var d = [_]Complex{ .{ .re = 1, .im = 0 }, .{ .re = 2, .im = 0 }, .{ .re = 3, .im = 0 } };
    try testing.expectError(error.NotPowerOfTwo, fft(&d, false));
}

test "empty input is refused" {
    var d: [0]Complex = .{};
    try testing.expectError(error.EmptyInput, fft(&d, false));
}

test "FFT agrees with a naive O(n^2) DFT on the same input" {
    // The strong check: two independent implementations must agree. Comparing the
    // fast path against itself would prove nothing.
    //
    // NOTE: naiveDft needs a SEPARATE output buffer. Aliasing input and output
    // corrupts the reference as it writes, which is a bug in the test, not in
    // the transform.
    const n = 8;
    var fast: [n]Complex = undefined;
    var slow: [n]Complex = undefined;
    var slow_out: [n]Complex = undefined;
    const signal = [n]f64{ 1, 2, 3, 4, 4, 3, 2, 1 };

    for (0..n) |i| {
        fast[i] = .{ .re = signal[i], .im = 0 };
    }
    for (0..n) |i| {
        slow[i] = .{ .re = signal[i], .im = 0 };
    }

    try fft(&fast, false);
    try naiveDft(&slow, &slow_out);

    for (0..n) |i| {
        try expectClose(slow_out[i].re, fast[i].re);
        try expectClose(slow_out[i].im, fast[i].im);
    }
}

test "FFT agrees with the naive DFT for a complex signal too" {
    const n = 4;
    var fast: [n]Complex = undefined;
    var slow: [n]Complex = undefined;
    var slow_out: [n]Complex = undefined;
    const re = [n]f64{ 0.5, -1.25, 3.0, 2.75 };
    const im = [n]f64{ 1.0, 0.25, -0.5, 2.0 };

    for (0..n) |i| {
        fast[i] = .{ .re = re[i], .im = im[i] };
        slow[i] = .{ .re = re[i], .im = im[i] };
    }
    try fft(&fast, false);
    try naiveDft(&slow, &slow_out);

    for (0..n) |i| {
        try expectClose(slow_out[i].re, fast[i].re);
        try expectClose(slow_out[i].im, fast[i].im);
    }
}

test "inverse FFT round-trips back to the original signal" {
    const n = 16;
    var original: [n]Complex = undefined;
    for (0..n) |i| original[i] = .{ .re = @floatFromInt(i), .im = 0 };

    var work = original;
    try fft(&work, false);
    try fft(&work, true);

    for (0..n) |i| {
        try expectClose(original[i].re, work[i].re);
        try expectClose(original[i].im, work[i].im);
    }
}

test "a DC-only signal transforms to a single non-zero bin" {
    const n = 4;
    var d: [n]Complex = @splat(.{ .re = 1, .im = 0 });
    try fft(&d, false);
    // A constant signal has all its energy at bin 0.
    try expectClose(4, d[0].re);
    try expectClose(0, d[0].im);
    for (1..n) |i| {
        try expectClose(0, d[i].re);
        try expectClose(0, d[i].im);
    }
}

test "NTT is exact and round-trips through its inverse" {
    const n = 8;
    var original: [n]u64 = .{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var work = original;

    try ntt(&work, false);
    // The transform must actually change the data.
    try testing.expect(!std.mem.eql(u64, &original, &work));

    try ntt(&work, true);
    try testing.expectEqualSlices(u64, &original, &work);
}

test "NTT length must be a power of two" {
    var d = [_]u64{ 1, 2, 3 };
    try testing.expectError(error.NotPowerOfTwo, ntt(&d, false));
}
