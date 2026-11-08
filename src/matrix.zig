//! Celeris-64 matrix accelerator model (spec §3.4, AGENTS.md §3.4).
//!
//! ════════════════════════════════════════════════════════════════════════════
//! FIDELITY (docs/isa-encoding.md §8): this is a FUNCTIONAL SOFTWARE MODEL.
//! There is no hardware matrix unit. Every result is computed in ordinary
//! scalar Zig. Nothing here is accelerated, and no cycle count, throughput or
//! speedup is claimed or measurable. The value of the model is correctness of
//! the RESULTS and of the Structure-of-Arrays access pattern the architecture
//! is built around - not performance.
//! ════════════════════════════════════════════════════════════════════════════
//!
//! Matrices are stored row-major and contiguous, which is the SoA-friendly layout
//! the architecture mandates: a transform walks memory linearly rather than
//! chasing pointers.

const std = @import("std");

pub const MatError = error{
    NotSquare,
    Singular,
    DimensionMismatch,
    BufferTooSmall,
};

pub fn explain(err: MatError) []const u8 {
    return switch (err) {
        error.NotSquare =>
            "A matrix operation that requires a square matrix was given one with " ++
                "different numbers of rows and columns. Inversion and determinants are only " ++
                "defined for square matrices.",
        error.Singular =>
            "The matrix has no inverse. Its determinant is zero, which means it collapses " ++
                "at least one direction of space, so no operation can undo it.",
        error.DimensionMismatch =>
            "Two matrices were combined whose shapes do not fit: the number of columns on the " ++
                "left must equal the number of rows on the right.",
        error.BufferTooSmall =>
            "The output buffer was too small to hold the result of the operation.",
    };
}

/// A row-major MxN matrix view over caller-owned memory (zero allocation).
pub const Mat = struct {
    rows: usize,
    cols: usize,
    data: []f64,

    pub fn init(rows: usize, cols: usize, data: []f64) MatError!Mat {
        if (data.len < rows * cols) return error.BufferTooSmall;
        return .{ .rows = rows, .cols = cols, .data = data[0 .. rows * cols] };
    }

    pub fn at(self: Mat, r: usize, c: usize) f64 {
        return self.data[r * self.cols + c];
    }

    pub fn set(self: Mat, r: usize, c: usize, v: f64) void {
        self.data[r * self.cols + c] = v;
    }
};

pub fn identity(n: usize, out: []f64) MatError!Mat {
    if (out.len < n * n) return error.BufferTooSmall;
    @memset(out[0 .. n * n], 0);
    var i: usize = 0;
    while (i < n) : (i += 1) out[i * n + i] = 1;
    return Mat{ .rows = n, .cols = n, .data = out[0 .. n * n] };
}

/// Multiply a*b into `out`. `out` must not alias either input.
pub fn multiply(a: Mat, b: Mat, out: []f64) MatError!Mat {
    if (a.cols != b.rows) return error.DimensionMismatch;
    if (out.len < a.rows * b.cols) return error.BufferTooSmall;
    const res = Mat{ .rows = a.rows, .cols = b.cols, .data = out[0 .. a.rows * b.cols] };

    var r: usize = 0;
    while (r < a.rows) : (r += 1) {
        var c: usize = 0;
        while (c < b.cols) : (c += 1) {
            var sum: f64 = 0;
            var k: usize = 0;
            while (k < a.cols) : (k += 1) sum += a.at(r, k) * b.at(k, c);
            res.set(r, c, sum);
        }
    }
    return res;
}

/// Determinant by Gaussian elimination with partial pivoting.
pub fn determinant(m: Mat) MatError!f64 {
    if (m.rows != m.cols) return error.NotSquare;
    const n = m.rows;
    if (n == 0) return 1;

    // Scratch on the stack bounded to a sane size; larger needs a caller buffer.
    var buf: [256]f64 = undefined;
    if (n * n > buf.len) return error.BufferTooSmall;
    @memcpy(buf[0 .. n * n], m.data[0 .. n * n]);

    var det: f64 = 1;
    var col: usize = 0;
    while (col < n) : (col += 1) {
        // Partial pivoting: pick the largest magnitude in this column.
        var pivot = col;
        var r = col + 1;
        while (r < n) : (r += 1) {
            if (@abs(buf[r * n + col]) > @abs(buf[pivot * n + col])) pivot = r;
        }
        if (buf[pivot * n + col] == 0) return 0; // singular
        if (pivot != col) {
            var c: usize = 0;
            while (c < n) : (c += 1) std.mem.swap(f64, &buf[col * n + c], &buf[pivot * n + c]);
            det = -det; // a row swap flips the sign
        }
        det *= buf[col * n + col];
        var rr = col + 1;
        while (rr < n) : (rr += 1) {
            const factor = buf[rr * n + col] / buf[col * n + col];
            var cc = col;
            while (cc < n) : (cc += 1) buf[rr * n + cc] -= factor * buf[col * n + cc];
        }
    }
    return det;
}

/// Inverse by Gauss-Jordan elimination with partial pivoting.
pub fn invert(m: Mat, out: []f64) MatError!Mat {
    if (m.rows != m.cols) return error.NotSquare;
    const n = m.rows;
    if (out.len < n * n) return error.BufferTooSmall;

    var buf: [256]f64 = undefined;
    if (n * n > buf.len) return error.BufferTooSmall;
    @memcpy(buf[0 .. n * n], m.data[0 .. n * n]);

    const inv = try identity(n, out);

    var col: usize = 0;
    while (col < n) : (col += 1) {
        var pivot = col;
        var r = col + 1;
        while (r < n) : (r += 1) {
            if (@abs(buf[r * n + col]) > @abs(buf[pivot * n + col])) pivot = r;
        }
        if (buf[pivot * n + col] == 0) return error.Singular;
        if (pivot != col) {
            var c: usize = 0;
            while (c < n) : (c += 1) {
                std.mem.swap(f64, &buf[col * n + c], &buf[pivot * n + c]);
                std.mem.swap(f64, &inv.data[col * n + c], &inv.data[pivot * n + c]);
            }
        }
        const diag = buf[col * n + col];
        var c: usize = 0;
        while (c < n) : (c += 1) {
            buf[col * n + c] /= diag;
            inv.data[col * n + c] /= diag;
        }
        var rr: usize = 0;
        while (rr < n) : (rr += 1) {
            if (rr == col) continue;
            const factor = buf[rr * n + col];
            c = 0;
            while (c < n) : (c += 1) {
                buf[rr * n + c] -= factor * buf[col * n + c];
                inv.data[rr * n + c] -= factor * inv.data[col * n + c];
            }
        }
    }
    return inv;
}

/// Apply a 4x4 rigid-body transform to an SoA point stream in place.
/// `points` is [x0,x1,...][y0,y1,...][z0,z1,...] - one contiguous array per axis,
/// which is the layout the architecture mandates (no per-point struct chasing).
pub fn transformSoA(xs: []f64, ys: []f64, zs: []f64, m: Mat) void {
    std.debug.assert(m.rows == 4 and m.cols == 4);
    var i: usize = 0;
    while (i < xs.len) : (i += 1) {
        const x = xs[i];
        const y = ys[i];
        const z = zs[i];
        xs[i] = m.at(0, 0) * x + m.at(0, 1) * y + m.at(0, 2) * z + m.at(0, 3);
        ys[i] = m.at(1, 0) * x + m.at(1, 1) * y + m.at(1, 2) * z + m.at(1, 3);
        zs[i] = m.at(2, 0) * x + m.at(2, 1) * y + m.at(2, 2) * z + m.at(2, 3);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectClose(expected: f64, actual: f64) !void {
    try testing.expect(@abs(expected - actual) < 1e-9);
}

test "determinant of a known 2x2 and 3x3" {
    var d2 = [_]f64{ 1, 2, 3, 4 };
    // det [[1,2],[3,4]] = 1*4 - 2*3 = -2
    try expectClose(-2, try determinant(try Mat.init(2, 2, &d2)));

    var d3 = [_]f64{ 6, 1, 1, 4, -2, 5, 2, 8, 7 };
    // det = 6(-2*7 - 5*8) - 1(4*7 - 5*2) + 1(4*8 - (-2)*2) = -324 - 18 + 36 = -306
    try expectClose(-306, try determinant(try Mat.init(3, 3, &d3)));
}

test "a singular matrix is reported as having no inverse" {
    var s = [_]f64{ 1, 2, 2, 4 }; // row 2 is a multiple of row 1
    const m = try Mat.init(2, 2, &s);
    try expectClose(0, try determinant(m));
    var out: [4]f64 = undefined;
    try testing.expectError(error.Singular, invert(m, &out));
}

test "invert is verified by multiplying back to identity, not by a table" {
    // The strong check: A * A^-1 must equal I. A hardcoded expected inverse would
    // only prove the code agrees with itself.
    var a = [_]f64{ 4, 7, 2, 6 };
    const m = try Mat.init(2, 2, &a);

    var inv_buf: [4]f64 = undefined;
    const inv = try invert(m, &inv_buf);

    var prod_buf: [4]f64 = undefined;
    const prod = try multiply(m, inv, &prod_buf);

    var i: usize = 0;
    while (i < 2) : (i += 1) {
        var j: usize = 0;
        while (j < 2) : (j += 1) {
            try expectClose(if (i == j) 1 else 0, prod.at(i, j));
        }
    }
}

test "invert a 3x3 and verify against identity" {
    var a = [_]f64{ 2, -1, 0, -1, 2, -1, 0, -1, 2 };
    const m = try Mat.init(3, 3, &a);
    var inv_buf: [9]f64 = undefined;
    const inv = try invert(m, &inv_buf);
    var prod_buf: [9]f64 = undefined;
    const prod = try multiply(m, inv, &prod_buf);

    var i: usize = 0;
    while (i < 3) : (i += 1) {
        var j: usize = 0;
        while (j < 3) : (j += 1) {
            try expectClose(if (i == j) 1 else 0, prod.at(i, j));
        }
    }
}

test "dimension mismatch is reported, not silently truncated" {
    var a = [_]f64{ 1, 2, 3, 4, 5, 6 }; // 2x3
    var b = [_]f64{ 1, 2, 3, 4 }; // 2x2
    var out: [16]f64 = undefined;
    try testing.expectError(
        error.DimensionMismatch,
        multiply(try Mat.init(2, 3, &a), try Mat.init(2, 2, &b), &out),
    );
}

test "rigid-body transform moves an SoA point stream" {
    // Translate by (10, 20, 30).
    var m_arr = [_]f64{ 1, 0, 0, 10, 0, 1, 0, 20, 0, 0, 1, 30, 0, 0, 0, 1 };
    const m = try Mat.init(4, 4, &m_arr);

    var xs = [_]f64{ 1, 2, 3 };
    var ys = [_]f64{ 4, 5, 6 };
    var zs = [_]f64{ 7, 8, 9 };
    transformSoA(&xs, &ys, &zs, m);

    try expectClose(11, xs[0]); // 1 + 10
    try expectClose(24, ys[0]); // 4 + 20
    try expectClose(37, zs[0]); // 7 + 30
    try expectClose(13, xs[2]); // 3 + 10
    try expectClose(39, zs[2]); // 9 + 30
}

test "non-square input is refused rather than guessed at" {
    var a = [_]f64{ 1, 2, 3, 4, 5, 6 };
    const m = try Mat.init(2, 3, &a);
    try testing.expectError(error.NotSquare, determinant(m));
}
