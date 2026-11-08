//! Celeris-64 native standard library — graphics primitives.
//!
//! ────────────────────────────────────────────────────────────────────────────
//! FIDELITY (docs/isa-encoding.md §8): this module is a SOFTWARE MODEL.
//!
//! There is no rasteriser, no GPU and no display path behind it, and none is
//! claimed. It writes pixels into an ordinary host byte buffer — the same flat
//! memory model the rest of the simulator uses. Nothing here is accelerated and
//! nothing here has been benchmarked against hardware.
//! ────────────────────────────────────────────────────────────────────────────
//!
//! Deterministic integer rasterisation: 8-bit-per-channel RGBA colour, a
//! clipping test, and line/rectangle filling. Integer-only so the output is
//! exactly reproducible across machines — which is what makes it testable at all.

const std = @import("std");

/// RGBA, 8 bits per channel, stored in memory order R, G, B, A.
pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    pub const black = Color{ .r = 0, .g = 0, .b = 0 };
    pub const white = Color{ .r = 255, .g = 255, .b = 255 };
    pub const red = Color{ .r = 255, .g = 0, .b = 0 };

    pub fn toBytes(self: Color) [4]u8 {
        return .{ self.r, self.g, self.b, self.a };
    }
};

/// A flat pixel buffer. Allocated once by the caller; nothing here allocates.
pub const Canvas = struct {
    pixels: []u8,
    width: u32,
    height: u32,

    pub fn init(pixels: []u8, width: u32, height: u32) !Canvas {
        const needed = @as(usize, width) * @as(usize, height) * 4;
        if (pixels.len < needed) return error.BufferTooSmall;
        return .{ .pixels = pixels[0..needed], .width = width, .height = height };
    }

    pub fn inBounds(self: Canvas, x: i32, y: i32) bool {
        return x >= 0 and y >= 0 and
            @as(u32, @intCast(x)) < self.width and @as(u32, @intCast(y)) < self.height;
    }

    pub fn set(self: *Canvas, x: i32, y: i32, color: Color) void {
        // Clipping, not wrapping: an out-of-range pixel is dropped rather than
        // written to a neighbouring row, which is the classic off-by-a-row bug.
        if (!self.inBounds(x, y)) return;
        const at = (@as(usize, @intCast(y)) * self.width + @as(usize, @intCast(x))) * 4;
        const bytes = color.toBytes();
        @memcpy(self.pixels[at..][0..4], &bytes);
    }

    pub fn get(self: *const Canvas, x: i32, y: i32) ?Color {
        if (!self.inBounds(x, y)) return null;
        const at = (@as(usize, @intCast(y)) * self.width + @as(usize, @intCast(x))) * 4;
        return .{
            .r = self.pixels[at],
            .g = self.pixels[at + 1],
            .b = self.pixels[at + 2],
            .a = self.pixels[at + 3],
        };
    }

    /// Fills an axis-aligned rectangle, clipped to the canvas.
    pub fn fillRect(self: *Canvas, x: i32, y: i32, w: i32, h: i32, color: Color) void {
        if (w <= 0 or h <= 0) return;
        var yy = y;
        while (yy < y + h) : (yy += 1) {
            var xx = x;
            while (xx < x + w) : (xx += 1) self.set(xx, yy, color);
        }
    }

    /// Bresenham's integer line. No floating point, so the pixel set is exactly
    /// reproducible.
    pub fn drawLine(self: *Canvas, x0: i32, y0: i32, x1: i32, y1: i32, color: Color) void {
        var x = x0;
        var y = y0;
        const dx = if (x1 > x0) x1 - x0 else x0 - x1;
        const dy = if (y1 > y0) y1 - y0 else y0 - y1;
        const sx: i32 = if (x0 < x1) 1 else -1;
        const sy: i32 = if (y0 < y1) 1 else -1;
        var err = dx - dy;

        while (true) {
            self.set(x, y, color);
            if (x == x1 and y == y1) break;
            const e2 = err * 2;
            if (e2 > -dy) {
                err -= dy;
                x += sx;
            }
            if (e2 < dx) {
                err += dx;
                y += sy;
            }
        }
    }
};

// -- tests --------------------------------------------------------------------

const testing = std.testing;

/// 4x4 canvas helper. The buffer is caller-owned; nothing here allocates.
fn testCanvas(pixels: *[64]u8) !Canvas {
    @memset(pixels, 0);
    return Canvas.init(pixels, 4, 4);
}

test "the pixel buffer is exactly width * height * 4 bytes" {
    var buf: [64]u8 = undefined;
    var c = try testCanvas(&buf);
    c.set(0, 0, Color.red);
    try testing.expectEqual(@as(u8, 255), c.pixels[0]);
    try testing.expectEqual(@as(u8, 0), c.pixels[1]);
    try testing.expectEqual(@as(u8, 0), c.pixels[2]);
    try testing.expectEqual(@as(u8, 255), c.pixels[3]);
}

test "a buffer that is too small is refused rather than overrun" {
    var small: [8]u8 = undefined;
    try testing.expectError(error.BufferTooSmall, Canvas.init(&small, 4, 4));
}

test "out-of-range pixels are clipped, never wrapped onto another row" {
    var buf: [64]u8 = undefined;
    var c = try testCanvas(&buf);
    // Writing off the right edge must not touch the start of the next row.
    c.set(4, 0, Color.white);
    c.set(-1, 0, Color.white);
    c.set(0, 4, Color.white);

    for (buf) |byte| try testing.expectEqual(@as(u8, 0), byte);
    try testing.expectEqual(@as(?Color, null), c.get(4, 0));
}

test "get returns the pixel that was set" {
    var buf: [64]u8 = undefined;
    var c = try testCanvas(&buf);
    c.set(2, 3, Color.white);
    const got = c.get(2, 3).?;
    try testing.expectEqual(@as(u8, 255), got.r);
    try testing.expectEqual(@as(u8, 255), got.a);
}

test "fillRect clips to the canvas without writing outside it" {
    var buf: [64]u8 = undefined;
    var c = try testCanvas(&buf);

    // Extends 2 pixels past the right and bottom edges.
    c.fillRect(2, 2, 10, 10, Color.white);

    // Everything the rectangle actually covers is set...
    try testing.expectEqual(@as(u8, 255), c.get(2, 2).?.r);
    try testing.expectEqual(@as(u8, 255), c.get(3, 3).?.r);
    // ...the pixels just outside it are untouched...
    try testing.expectEqual(@as(u8, 0), c.get(0, 0).?.r);
    try testing.expectEqual(@as(u8, 0), c.get(2, 1).?.r);
    try testing.expectEqual(@as(u8, 0), c.get(1, 2).?.r);
    // ...and the buffer is still exactly its declared length. A write past the
    // end would have tripped Zig's bounds check before reaching this line.
    try testing.expectEqual(@as(usize, 64), c.pixels.len);
}

test "a line is drawn including both endpoints" {
    var buf: [64]u8 = undefined;
    var c = try testCanvas(&buf);
    c.drawLine(0, 0, 3, 3, Color.white);
    try testing.expectEqual(@as(u8, 255), c.get(0, 0).?.r);
    try testing.expectEqual(@as(u8, 255), c.get(3, 3).?.r);
    try testing.expectEqual(@as(u8, 255), c.get(1, 1).?.r);
}

test "a horizontal line touches exactly one row" {
    var buf: [64]u8 = undefined;
    var c = try testCanvas(&buf);
    c.drawLine(0, 1, 3, 1, Color.white);
    for (0..4) |x| try testing.expectEqual(@as(u8, 255), c.get(@intCast(x), 1).?.r);
    for (0..4) |x| try testing.expectEqual(@as(u8, 0), c.get(@intCast(x), 0).?.r);
}

test "rasterisation is deterministic across repeated runs" {
    // Same drawing twice must give byte-identical buffers: no hidden state.
    var a: [64]u8 = undefined;
    var b: [64]u8 = undefined;
    var ca = try testCanvas(&a);
    var cb = try testCanvas(&b);

    ca.drawLine(0, 0, 3, 2, Color.red);
    ca.fillRect(1, 1, 2, 2, Color.white);
    cb.drawLine(0, 0, 3, 2, Color.red);
    cb.fillRect(1, 1, 2, 2, Color.white);

    try testing.expectEqualSlices(u8, &a, &b);
}
