//! Celeris-64 native standard library — UI layout primitives.
//!
//! ────────────────────────────────────────────────────────────────────────────
//! FIDELITY (docs/isa-encoding.md §8): this module is a SOFTWARE MODEL.
//!
//! There is no GPU, no framebuffer, no window system and no display driver
//! behind it, and none is claimed. It computes layout rectangles in ordinary
//! host memory. Nothing here is a hardware path, and nothing here has been
//! measured against a real device.
//! ────────────────────────────────────────────────────────────────────────────
//!
//! What it actually does: deterministic integer rectangle layout — a row/column
//! splitter and a padding/alignment step — which is the arithmetic part of a UI
//! toolkit and the part that is testable without a screen.

const std = @import("std");

/// An axis-aligned rectangle in integer device coordinates.
pub const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,

    pub fn right(self: Rect) i32 {
        return self.x + self.w;
    }

    pub fn bottom(self: Rect) i32 {
        return self.y + self.h;
    }

    pub fn contains(self: Rect, px: i32, py: i32) bool {
        return px >= self.x and px < self.right() and py >= self.y and py < self.bottom();
    }
};

/// Insets applied inside a rectangle.
pub const Padding = struct {
    left: i32 = 0,
    top: i32 = 0,
    right: i32 = 0,
    bottom: i32 = 0,

    pub fn uniform(amount: i32) Padding {
        return .{ .left = amount, .top = amount, .right = amount, .bottom = amount };
    }
};

pub const LayoutError = error{
    /// A padding amount was negative, which would grow the rectangle.
    NegativePadding,
};

/// Shrinks `outer` by `padding`.
///
/// A rectangle that would invert is returned with zero width or height rather
/// than a negative one, so a consumer cannot accidentally allocate a negative
/// area. The caller can detect it by comparing against `outer`.
pub fn inset(outer: Rect, padding: Padding) LayoutError!Rect {
    if (padding.left < 0 or padding.top < 0 or padding.right < 0 or padding.bottom < 0) {
        return error.NegativePadding;
    }
    const w = outer.w - padding.left - padding.right;
    const h = outer.h - padding.top - padding.bottom;
    return .{
        .x = outer.x + padding.left,
        .y = outer.y + padding.top,
        .w = if (w < 0) 0 else w,
        .h = if (h < 0) 0 else h,
    };
}

/// Splits `outer` into `count` equal columns, handing any leftover pixels to the
/// leftmost columns so the pieces exactly tile `outer` with no gap and no
/// overlap.
pub fn columns(outer: Rect, count: usize, out: []Rect) error{TooManyColumns}!void {
    if (count == 0) return;
    if (out.len < count) return error.TooManyColumns;

    const total = outer.w;
    const base = @divTrunc(total, @as(i32, @intCast(count)));
    const remainder = @rem(total, @as(i32, @intCast(count)));

    var x = outer.x;
    for (0..count) |i| {
        // Leftmost `remainder` columns are one pixel wider: the tiles sum to
        // exactly `total`, so a border drawn around each leaves no seam.
        const extra: i32 = if (@as(i32, @intCast(i)) < remainder) 1 else 0;
        const w = base + extra;
        out[i] = .{ .x = x, .y = outer.y, .w = w, .h = outer.h };
        x += w;
    }
}

/// Aligns a `size`-sized box inside `outer` along one axis.
pub const Align = enum { start, center, end };

pub fn alignAxis(outer_start: i32, outer_size: i32, box_size: i32, how: Align) i32 {
    const slack = outer_size - box_size;
    if (slack <= 0) return outer_start;
    return switch (how) {
        .start => outer_start,
        .center => outer_start + @divTrunc(slack, 2),
        .end => outer_start + slack,
    };
}

// -- tests --------------------------------------------------------------------

const testing = std.testing;

test "inset shrinks all four edges" {
    const outer = Rect{ .x = 0, .y = 0, .w = 100, .h = 50 };
    const inner = try inset(outer, .uniform(5));
    try testing.expectEqual(@as(i32, 5), inner.x);
    try testing.expectEqual(@as(i32, 5), inner.y);
    try testing.expectEqual(@as(i32, 90), inner.w);
    try testing.expectEqual(@as(i32, 40), inner.h);
}

test "over-padded rectangles collapse to zero rather than inverting" {
    const outer = Rect{ .x = 0, .y = 0, .w = 4, .h = 4 };
    const inner = try inset(outer, .uniform(10));
    try testing.expectEqual(@as(i32, 0), inner.w);
    try testing.expectEqual(@as(i32, 0), inner.h);
}

test "negative padding is refused, not silently applied" {
    const outer = Rect{ .x = 0, .y = 0, .w = 10, .h = 10 };
    try testing.expectError(error.NegativePadding, inset(outer, .{ .left = -1 }));
}

test "columns tile the parent exactly with no gap and no overlap" {
    var out: [3]Rect = undefined;
    const outer = Rect{ .x = 10, .y = 0, .w = 100, .h = 20 };
    try columns(outer, 3, &out);

    try testing.expectEqual(@as(i32, 10), out[0].x);
    // Contiguous and gapless.
    try testing.expectEqual(out[0].right(), out[1].x);
    try testing.expectEqual(out[1].right(), out[2].x);
    // And the last one ends exactly at the parent's right edge.
    try testing.expectEqual(outer.right(), out[2].right());
}

test "columns distribute a remainder without losing a pixel" {
    var out: [3]Rect = undefined;
    const outer = Rect{ .x = 0, .y = 0, .w = 100, .h = 10 };
    try columns(outer, 3, &out); // 100 / 3 = 33 rem 1
    const total = out[0].w + out[1].w + out[2].w;
    try testing.expectEqual(@as(i32, 100), total);
}

test "alignment places the box deterministically" {
    try testing.expectEqual(@as(i32, 0), alignAxis(0, 100, 20, .start));
    try testing.expectEqual(@as(i32, 40), alignAxis(0, 100, 20, .center));
    try testing.expectEqual(@as(i32, 80), alignAxis(0, 100, 20, .end));
    // A box larger than its parent does not move: there is no slack.
    try testing.expectEqual(@as(i32, 7), alignAxis(7, 10, 20, .center));
}

test "contains is half-open on both axes" {
    const r = Rect{ .x = 0, .y = 0, .w = 10, .h = 10 };
    try testing.expect(r.contains(0, 0));
    try testing.expect(r.contains(9, 9));
    try testing.expect(!r.contains(10, 0));
    try testing.expect(!r.contains(0, 10));
}
