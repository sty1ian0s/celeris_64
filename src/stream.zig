//! Celeris-64 stream engine (spec §3.1, AGENTS.md §3.1).
//!
//! `stream.*` replaces the software loop: no explicit index, no pointer arithmetic,
//! no per-element bounds test. The engine applies one operation across a contiguous
//! chunk and advances the pointer itself.
//!
//! THE ONE RULE THAT MATTERS (docs/isa-encoding.md §3.4 rule 3): bounds are checked
//! for the WHOLE chunk BEFORE any element is touched. If the chunk does not fit
//! entirely, ZERO elements are modified. Partial application is forbidden — it is
//! the failure mode that makes chunked code untrustworthy, because a caller cannot
//! tell how far a failed batch got.
//!
//! Normative reference: docs/isa-encoding.md §3.4.

const std = @import("std");
const memory = @import("memory.zig");

pub const StreamError = error{
    ChunkNotPositive,
    BadElementWidth,
};

pub fn explain(err: StreamError) []const u8 {
    return switch (err) {
        error.ChunkNotPositive =>
            "A stream operation asked to process zero elements. " ++
                "A batch of nothing is a programming mistake, so the operation was refused.",
        error.BadElementWidth =>
            "A stream operation named an element width this architecture does not define. " ++
                "Celeris-64 streams 8-bit, 16-bit, 32-bit or 64-bit elements.",
    };
}

/// Element width selector, matching the §5 width encoding used by the decoder.
pub const ElemWidth = enum(u4) {
    b = 3,
    w = 2,
    l = 1,
    q = 0,

    pub fn bytes(self: ElemWidth) u64 {
        return switch (self) {
            .b => 1,
            .w => 2,
            .l => 4,
            .q => 8,
        };
    }

    pub fn fromEncoded(raw: u4) StreamError!ElemWidth {
        return switch (raw) {
            0 => .q,
            1 => .l,
            2 => .w,
            3 => .b,
            else => error.BadElementWidth,
        };
    }
};

pub const State = struct {
    mem: memory.Memory,
    ptr: u64,

    pub fn init(mem: memory.Memory, ptr: u64) State {
        return .{ .mem = mem, .ptr = ptr };
    }

    /// The pointer after `chunk` elements: the engine's whole reason to exist.
    pub fn advance(self: State, chunk: u64, width: ElemWidth) u64 {
        return self.ptr + chunk * width.bytes();
    }

    /// Check the whole chunk fits BEFORE writing anything.
    fn fits(self: State, chunk: u64, width: ElemWidth) bool {
        return self.mem.inBounds(self.ptr, chunk * width.bytes());
    }

    /// `stream.fill`: write `value` into every element of the chunk, then advance.
    pub fn fill(self: *State, value: u64, chunk: u64, width: ElemWidth) !void {
        if (chunk == 0) return error.ChunkNotPositive;
        if (!self.fits(chunk, width)) return memory.BoundsError.OutOfBounds;

        const step = width.bytes();
        var i: u64 = 0;
        while (i < chunk) : (i += 1) {
            const at = self.ptr + i * step;
            switch (width) {
                .b => try self.mem.write8(at, @truncate(value)),
                .w => try self.mem.write16(at, @truncate(value)),
                .l => try self.mem.write32(at, @truncate(value)),
                .q => try self.mem.write64(at, value),
            }
        }
        self.ptr = self.advance(chunk, width);
    }

    /// `stream.copy`: move `chunk` elements from `src` to the pointer, then advance.
    pub fn copy(self: *State, src: u64, chunk: u64, width: ElemWidth) !void {
        if (chunk == 0) return error.ChunkNotPositive;
        const step = width.bytes();
        // Both regions must fit entirely, or nothing moves.
        if (!self.fits(chunk, width)) return memory.BoundsError.OutOfBounds;
        if (!self.mem.inBounds(src, chunk * step)) return memory.BoundsError.OutOfBounds;

        var i: u64 = 0;
        while (i < chunk) : (i += 1) {
            const from = src + i * step;
            const to = self.ptr + i * step;
            // Read every element first conceptually, but since source and destination
            // may overlap we copy through a scalar per element at matching width.
            switch (width) {
                .b => try self.mem.write8(to, try self.mem.read8(from)),
                .w => try self.mem.write16(to, try self.mem.read16(from)),
                .l => try self.mem.write32(to, try self.mem.read32(from)),
                .q => try self.mem.write64(to, try self.mem.read64(from)),
            }
        }
        self.ptr = self.advance(chunk, width);
    }

    /// `stream.add`: element-wise `dest[i] = dest[i] + offsetReg`, then advance.
    /// This is the fused load/add/store the architecture spec headlines.
    pub fn add(self: *State, offset: u64, chunk: u64, width: ElemWidth) !void {
        if (chunk == 0) return error.ChunkNotPositive;
        if (!self.fits(chunk, width)) return memory.BoundsError.OutOfBounds;

        const step = width.bytes();
        var i: u64 = 0;
        while (i < chunk) : (i += 1) {
            const at = self.ptr + i * step;
            switch (width) {
                .b => try self.mem.write8(at, (try self.mem.read8(at)) +% @as(u8, @truncate(offset))),
                .w => try self.mem.write16(at, (try self.mem.read16(at)) +% @as(u16, @truncate(offset))),
                .l => try self.mem.write32(at, (try self.mem.read32(at)) +% @as(u32, @truncate(offset))),
                .q => try self.mem.write64(at, (try self.mem.read64(at)) +% offset),
            }
        }
        self.ptr = self.advance(chunk, width);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "stream pointer advances by chunk * elementSize" {
    var buf: [64]u8 = @splat(0);
    const mem = memory.Memory.init(&buf);
    var st = State.init(mem, 0);
    try st.fill(1, 4, .q);
    try testing.expectEqual(@as(u64, 32), st.ptr); // 4 * 8
    var st2 = State.init(mem, 0);
    try st2.fill(1, 4, .l);
    try testing.expectEqual(@as(u64, 16), st2.ptr); // 4 * 4
    var st3 = State.init(mem, 0);
    try st3.fill(1, 4, .w);
    try testing.expectEqual(@as(u64, 8), st3.ptr);
    var st4 = State.init(mem, 0);
    try st4.fill(1, 4, .b);
    try testing.expectEqual(@as(u64, 4), st4.ptr);
}

test "ATOMICITY: a chunk overrunning the last element leaves memory byte-identical" {
    // 16 bytes; a 4-element 64-bit chunk at address 8 needs 32 and overruns.
    var buf: [16]u8 = @splat(0xA5);
    const snapshot = buf;
    const mem = memory.Memory.init(&buf);
    var st = State.init(mem, 8);

    try testing.expectError(memory.BoundsError.OutOfBounds, st.fill(0xFF, 4, .q));

    // Byte-for-byte, element-by-element: a partial write of early elements must
    // not be able to hide inside a looser comparison.
    var i: usize = 0;
    while (i < buf.len) : (i += 1) try testing.expectEqual(snapshot[i], buf[i]);
    try testing.expectEqualSlices(u8, &snapshot, &buf);
    // A refused operation must not advance the pointer either.
    try testing.expectEqual(@as(u64, 8), st.ptr);
}

test "ATOMICITY: off-by-one at the exactly-fitting boundary" {
    var buf: [32]u8 = @splat(0x3C);
    const snapshot = buf;
    const mem = memory.Memory.init(&buf);

    // Exactly fits: 4 * 8 == 32 at 0.
    var ok = State.init(mem, 0);
    try ok.fill(7, 4, .q);
    // One byte too far: refused whole.
    var bad = State.init(mem, 1);
    try testing.expectError(memory.BoundsError.OutOfBounds, bad.fill(7, 4, .q));
    try testing.expectEqual(@as(u64, 1), bad.ptr);
    _ = snapshot;
}

test "ATOMICITY: copy refuses whole and leaves both regions untouched" {
    var buf: [16]u8 = @splat(0x11);
    const snapshot = buf;
    const mem = memory.Memory.init(&buf);
    var st = State.init(mem, 8);
    // Destination chunk of 4 qwords at 8 needs 32 bytes: does not fit.
    try testing.expectError(memory.BoundsError.OutOfBounds, st.copy(0, 4, .q));
    try testing.expectEqualSlices(u8, &snapshot, &buf);
}

test "a zero-length chunk is refused" {
    var buf: [16]u8 = @splat(0);
    const mem = memory.Memory.init(&buf);
    var st = State.init(mem, 0);
    try testing.expectError(error.ChunkNotPositive, st.fill(1, 0, .q));
}

test "stream.add is the fused load/add/store the spec headlines" {
    var buf: [32]u8 = @splat(0);
    const mem = memory.Memory.init(&buf);
    var st = State.init(mem, 0);
    try st.fill(10, 4, .q);
    var st2 = State.init(mem, 0);
    try st2.add(5, 4, .q);
    try testing.expectEqual(@as(u64, 15), try mem.read64(0));
    try testing.expectEqual(@as(u64, 15), try mem.read64(24));
    try testing.expectEqual(@as(u64, 32), st2.ptr);
}

test "stream.copy moves elements" {
    var buf: [32]u8 = @splat(0);
    const mem = memory.Memory.init(&buf);
    var st = State.init(mem, 0);
    try st.fill(0xABCD, 2, .w);
    var st2 = State.init(mem, 8);
    try st2.copy(0, 2, .w);
    try testing.expectEqual(@as(u16, 0xABCD), try mem.read16(8));
    try testing.expectEqual(@as(u16, 0xABCD), try mem.read16(10));
}

test "element width encoding matches the §5 width selector" {
    try testing.expectEqual(@as(u64, 8), ElemWidth.q.bytes());
    try testing.expectEqual(@as(u64, 4), ElemWidth.l.bytes());
    try testing.expectEqual(@as(u64, 2), ElemWidth.w.bytes());
    try testing.expectEqual(@as(u64, 1), ElemWidth.b.bytes());
    try testing.expectError(error.BadElementWidth, ElemWidth.fromEncoded(4));
}
