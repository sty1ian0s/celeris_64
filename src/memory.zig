//! CLS64 flat memory model (AGENTS.md §2.3).
//!
//! Fidelity: executable model of flat byte-addressable memory. Bounds checks are a
//! software model of the CHERI capability checks (docs/isa-encoding.md §6, §8): base
//! and length are tracked and enforced, but there are no tag bits and no provenance.
//!
//! Storage is one flat []u8 handed in at VM init. Nothing here allocates, and every
//! access is an explicit little-endian load/store.

const std = @import("std");

/// The bounds error. Zig carries the control flow; the user-visible text is always a
/// plain sentence rendered from `detail` (AGENTS.md §4.2, docs/isa-encoding.md §7).
pub const BoundsError = error{OutOfBounds};

/// Plain-language bounds diagnostic (AGENTS.md §4.2: no bare hex codes).
pub const BoundsFault = struct {
    /// What was attempted, e.g. "read 8 bytes little-endian".
    action: []const u8,
    /// The address the access started at.
    address: u64,
    /// Accessible region base (0 for physical memory; a capability base otherwise).
    base: u64,
    /// Accessible region length in bytes.
    length: u64,
    /// Bytes the access wanted.
    width: u64,

    /// Renders as a sentence naming the address, the base and the length.
    pub fn render(self: BoundsFault, out: []u8) []const u8 {
        return std.fmt.bufPrint(out,
            "memory access out of bounds: {s} at address {d} needs {d} byte(s), " ++
                "but the accessible region starts at base {d} and is {d} byte(s) long " ++
                "({d} byte(s) past its end). The access was refused; nothing was read or written.",
            .{
                self.action,
                self.address,
                self.width,
                self.base,
                self.length,
                self.address +| self.width -| (self.base + self.length),
            },
        ) catch out[0..0];
    }
};

/// Classifies a failing access in the common case where base is 0.
pub fn classify(address: u64, width: u64, mem_len: u64) BoundsFault {
    return .{
        .action = "access",
        .address = address,
        .base = 0,
        .length = mem_len,
        .width = width,
    };
}

pub const Memory = struct {
    /// The flat array. The VM lends its init-time buffer here; nothing else allocates.
    bytes: []u8,

    pub fn init(bytes: []u8) Memory {
        return .{ .bytes = bytes };
    }

    /// Convenience for callers that genuinely own their storage (the CLI, a test).
    /// The execution loop never calls this: it holds the VM's pre-allocated image.
    pub fn initAlloc(allocator: std.mem.Allocator, size: usize) !Memory {
        return .{ .bytes = try allocator.alloc(u8, size) };
    }

    pub fn len(self: *const Memory) u64 {
        return self.bytes.len;
    }

    /// True when `width` bytes starting at `address` lie inside the allocation.
    /// Checked before any access, so a failing access never partially applies.
    pub fn inBounds(self: *const Memory, address: u64, width: u64) bool {
        const end = address +| width;
        return @as(u64, self.bytes.len) >= end and address <= self.bytes.len;
    }

    fn fault(self: *const Memory, action: []const u8, address: u64, width: u64) BoundsFault {
        return .{
            .action = action,
            .address = address,
            .base = 0,
            .length = self.bytes.len,
            .width = width,
        };
    }

    fn sliceAt(self: *const Memory, address: u64, width: u64) BoundsError![]const u8 {
        if (!self.inBounds(address, width)) return BoundsError.OutOfBounds;
        return self.bytes[@intCast(address)..][0..@intCast(width)];
    }

    fn sliceAtMut(self: *Memory, address: u64, width: u64) BoundsError![]u8 {
        if (!self.inBounds(address, width)) return BoundsError.OutOfBounds;
        return self.bytes[@intCast(address)..][0..@intCast(width)];
    }

    pub fn read8(self: *const Memory, address: u64) BoundsError!u8 {
        return (try self.sliceAt(address, 1))[0];
    }

    pub fn read16(self: *const Memory, address: u64) BoundsError!u16 {
        const b = try self.sliceAt(address, 2);
        return std.mem.readInt(u16, b[0..2], .little);
    }

    pub fn read32(self: *const Memory, address: u64) BoundsError!u32 {
        const b = try self.sliceAt(address, 4);
        return std.mem.readInt(u32, b[0..4], .little);
    }

    pub fn read64(self: *const Memory, address: u64) BoundsError!u64 {
        const b = try self.sliceAt(address, 8);
        return std.mem.readInt(u64, b[0..8], .little);
    }

    pub fn write8(self: *Memory, address: u64, value: u8) BoundsError!void {
        (try self.sliceAtMut(address, 1))[0] = value;
    }

    pub fn write16(self: *Memory, address: u64, value: u16) BoundsError!void {
        const b = try self.sliceAtMut(address, 2);
        std.mem.writeInt(u16, b[0..2], value, .little);
    }

    pub fn write32(self: *Memory, address: u64, value: u32) BoundsError!void {
        const b = try self.sliceAtMut(address, 4);
        std.mem.writeInt(u32, b[0..4], value, .little);
    }

    pub fn write64(self: *Memory, address: u64, value: u64) BoundsError!void {
        const b = try self.sliceAtMut(address, 8);
        std.mem.writeInt(u64, b[0..8], value, .little);
    }

    /// Copy out of memory; refuses whole rather than truncating (contract P1.2).
    pub fn copyOut(self: *const Memory, address: u64, dest: []u8) BoundsError!void {
        const src = try self.sliceAt(address, dest.len);
        @memcpy(dest, src);
    }

    /// Copy into memory; refuses whole rather than truncating.
    pub fn copyIn(self: *Memory, address: u64, src: []const u8) BoundsError!void {
        const dst = try self.sliceAtMut(address, src.len);
        @memcpy(dst, src);
    }

    /// Writes a bounded region to zero, all or nothing.
    pub fn zero(self: *Memory, address: u64, count: u64) BoundsError!void {
        const dst = try self.sliceAtMut(address, count);
        @memset(dst, 0);
    }
};

const testing = std.testing;

test "little-endian layout: exact bytes, not just a round-trip" {
    var buf: [64]u8 = @splat(0xAA);
    var mem = Memory.init(&buf);

    try mem.write64(0, 0x0123456789ABCDEF);
    // Most significant byte first in the literal, lowest byte at the lowest address.
    try testing.expectEqualSlices(u8, &.{ 0xEF, 0xCD, 0xAB, 0x89, 0x67, 0x45, 0x23, 0x01 }, buf[0..8]);

    try mem.write32(16, 0xDEADBEEF);
    try testing.expectEqualSlices(u8, &.{ 0xEF, 0xBE, 0xAD, 0xDE }, buf[16..20]);

    try mem.write16(24, 0x1234);
    try testing.expectEqualSlices(u8, &.{ 0x34, 0x12 }, buf[24..26]);

    try mem.write8(30, 0x7F);
    try testing.expectEqual(@as(u8, 0x7F), buf[30]);

    // Reads agree with the on-disk byte order.
    try testing.expectEqual(@as(u64, 0x0123456789ABCDEF), try mem.read64(0));
    try testing.expectEqual(@as(u32, 0xDEADBEEF), try mem.read32(16));
    try testing.expectEqual(@as(u16, 0x1234), try mem.read16(24));
    try testing.expectEqual(@as(u8, 0x7F), try mem.read8(30));

    // Byte at 1 is the second-lowest byte of the 64-bit store, not the sign byte.
    try testing.expectEqual(@as(u8, 0xCD), buf[1]);
}

test "out-of-bounds access names address, base and length and changes nothing" {
    var buf: [16]u8 = @splat(0x5A);
    var mem = Memory.init(&buf);

    try testing.expectError(BoundsError.OutOfBounds, mem.read64(9)); // 9 + 8 > 16
    try testing.expectError(BoundsError.OutOfBounds, mem.write64(16, 1)); // exactly one past the end
    try testing.expectError(BoundsError.OutOfBounds, mem.read8(16));
    try testing.expectError(BoundsError.OutOfBounds, mem.read32(13));
    try testing.expectError(BoundsError.OutOfBounds, mem.write16(15, 7));

    // The failed writes must not have touched memory at all.
    for (buf) |b| try testing.expectEqual(@as(u8, 0x5A), b);

    const f = mem.fault("read 64 bits little-endian", 9, 8);
    var text: [512]u8 = undefined;
    const s = f.render(&text);
    try testing.expect(std.mem.indexOf(u8, s, "address 9") != null);
    try testing.expect(std.mem.indexOf(u8, s, "base 0") != null);
    try testing.expect(std.mem.indexOf(u8, s, "16 byte(s) long") != null);
    // Plain language, not a bare hexadecimal error code.
    try testing.expect(std.mem.indexOf(u8, s, "0x") == null);
    try testing.expect(std.mem.indexOf(u8, s, "out of bounds") != null);
}

test "inBounds accepts the last valid byte and rejects one past it" {
    var buf: [8]u8 = undefined;
    const mem = Memory.init(&buf);
    try testing.expect(mem.inBounds(0, 8));
    try testing.expect(mem.inBounds(7, 1));
    try testing.expect(!mem.inBounds(8, 1));
    try testing.expect(!mem.inBounds(0, 9));
    // Address + width wraps past 2^64 rather than being accepted.
    try testing.expect(!mem.inBounds(std.math.maxInt(u64), 2));
}

test "copy helpers are all-or-nothing" {
    var buf: [8]u8 = @splat(0x11);
    var mem = Memory.init(&buf);

    var out: [8]u8 = @splat(0x00);
    try mem.copyOut(0, out[0..8]);
    try testing.expectEqualSlices(u8, &buf, &out);

    try mem.copyIn(4, &.{ 0xAA, 0xBB });
    try testing.expectEqual(@as(u8, 0xAA), buf[4]);
    try testing.expectEqual(@as(u8, 0xBB), buf[5]);

    // A copy that does not fully fit writes zero bytes.
    const before = buf;
    try testing.expectError(BoundsError.OutOfBounds, mem.copyIn(6, &.{ 0x01, 0x02, 0x03 }));
    try testing.expectEqualSlices(u8, &before, &buf);
}
