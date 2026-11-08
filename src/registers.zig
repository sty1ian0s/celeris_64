//! Celeris-64 register file: R0-R11, ZERO, PC, SP, LR, FLAGS.
//!
//! Normative reference: docs/isa-encoding.md §4 (index encoding) and §5 (width suffixes).
//! Architectural mandate: AGENTS.md §2.1 — a sub-width write ZERO-EXTENDS the upper bits.
//! That zero-extension is observable behaviour, not an implementation detail: it is what
//! removes partial-register stall dependencies in the architecture's own model.

const std = @import("std");

/// Number of orthogonal 64-bit general-purpose registers (spec §2.2).
pub const gpr_count = 12;

/// Width suffix per docs/isa-encoding.md §5.
pub const Width = enum(u4) {
    full = 0,
    l = 1,
    w = 2,
    b = 3,

    /// Reject reserved encodings instead of silently guessing a width.
    pub fn fromEncoded(raw: u4) !Width {
        return switch (raw) {
            0 => .full,
            1 => .l,
            2 => .w,
            3 => .b,
            else => error.ReservedWidthEncoding,
        };
    }

    pub fn mask(self: Width) u64 {
        return switch (self) {
            .full => std.math.maxInt(u64),
            .l => 0xFFFF_FFFF,
            .w => 0xFFFF,
            .b => 0xFF,
        };
    }

    pub fn bits(self: Width) u8 {
        return switch (self) {
            .full => 64,
            .l => 32,
            .w => 16,
            .b => 8,
        };
    }

    pub fn suffix(self: Width) []const u8 {
        return switch (self) {
            .full => "",
            .l => ".l",
            .w => ".w",
            .b => ".b",
        };
    }
};

/// Plain-language failure text. AGENTS.md §4.2 forbids bare hexadecimal error codes.
pub const RegisterError = error{
    ReservedWidthEncoding,
    NoSuchRegister,
    ZeroRegisterWrite,
};

pub fn explain(err: RegisterError, index: u8) []const u8 {
    _ = index;
    return switch (err) {
        error.ReservedWidthEncoding =>
            "The instruction asked for a register width that this architecture does not define. " ++
                "Celeris-64 accepts only the full 64-bit width or the .l, .w and .b suffixes.",
        error.NoSuchRegister =>
            "The instruction named a register that does not exist on this machine. " ++
                "Celeris-64 provides R0 through R11, and the system registers SP, LR, PC and FLAGS.",
        error.ZeroRegisterWrite =>
            "The program tried to write to ZERO. ZERO is hardwired to zero and ignores all writes; " ++
                "the value was discarded and the register still reads zero.",
    };
}

/// System registers, addressed per docs/isa-encoding.md §4.
pub const SysReg = enum(u4) {
    sp = 12,
    lr = 13,
    pc = 14,
    flags = 15,
};

pub const File = struct {
    /// R0-R11. Index 0 is a real, writable register — ZERO is not one of these.
    gpr: [gpr_count]u64 = @splat(0),

    /// FLAGS: carry, overflow and status bits (spec §2.1).
    flags: u64 = 0,

    sp: u64 = 0,
    lr: u64 = 0,
    pc: u64 = 0,

    /// ZERO is a constant, never stored, so no write path can ever corrupt it.
    pub fn zero(self: *const File) u64 {
        _ = self;
        return 0;
    }

    /// Read a register by the §4 index encoding.
    pub fn read(self: *const File, index: u4) u64 {
        return switch (index) {
            0...11 => self.gpr[index],
            12 => self.sp,
            13 => self.lr,
            14 => self.pc,
            15 => self.flags,
        };
    }

    /// Full-width write.
    pub fn write(self: *File, index: u4, value: u64) void {
        switch (index) {
            0...11 => self.gpr[index] = value,
            12 => self.sp = value,
            13 => self.lr = value,
            14 => self.pc = value,
            15 => self.flags = value,
        }
    }

    /// Sub-width write with mandatory zero-extension of the upper bits (AGENTS.md §2.1).
    ///
    /// The upper bits are cleared, never preserved. A test must observe this directly.
    pub fn writeWidth(self: *File, index: u4, width: Width, value: u64) void {
        const narrowed = value & width.mask();
        self.write(index, narrowed);
    }

    /// Sub-width write where the width arrives as a raw encoded field, so a reserved
    /// encoding is reported rather than silently treated as a full-width write.
    pub fn writeEncoded(self: *File, index: u4, encoded: u4, value: u64) RegisterError!void {
        const width = Width.fromEncoded(encoded) catch return error.ReservedWidthEncoding;
        self.writeWidth(index, width, value);
    }

    /// Read a sub-width view. Zero-extends for the same reason writes do.
    pub fn readWidth(self: *const File, index: u4, width: Width) u64 {
        return self.read(index) & width.mask();
    }
};

/// Name a register the way the assembler spells it, for diagnostics.
pub fn name(alloc: std.mem.Allocator, index: u4) ![]u8 {
    return switch (index) {
        0...11 => std.fmt.allocPrint(alloc, "R{d}", .{index}),
        12 => alloc.dupe(u8, "SP"),
        13 => alloc.dupe(u8, "LR"),
        14 => alloc.dupe(u8, "PC"),
        15 => alloc.dupe(u8, "FLAGS"),
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "ZERO always reads zero regardless of the rest of the file" {
    var f = File{};
    f.gpr[0] = 0xDEAD_BEEF_CAFE_F00D;
    try std.testing.expectEqual(@as(u64, 0), f.zero());
}

test "sub-width write zero-extends the upper bits (mandatory invariant)" {
    var f = File{};

    // Fill all 64 bits, then write a sub-width value. Upper bits must be cleared.
    f.write(3, 0xFFFF_FFFF_FFFF_FFFF);
    f.writeWidth(3, .b, 0xAB);
    try std.testing.expectEqual(@as(u64, 0x0000_0000_0000_00AB), f.read(3));

    f.write(3, 0xFFFF_FFFF_FFFF_FFFF);
    f.writeWidth(3, .w, 0xBEEF);
    try std.testing.expectEqual(@as(u64, 0x0000_0000_0000_BEEF), f.read(3));

    f.write(3, 0xFFFF_FFFF_FFFF_FFFF);
    f.writeWidth(3, .l, 0xDEAD_BEEF);
    try std.testing.expectEqual(@as(u64, 0x0000_0000_DEAD_BEEF), f.read(3));

    // A full-width write keeps every bit.
    f.write(3, 0xFFFF_FFFF_FFFF_FFFF);
    f.writeWidth(3, .full, 0xDEAD_BEEF_CAFE_F00D);
    try std.testing.expectEqual(@as(u64, 0xDEAD_BEEF_CAFE_F00D), f.read(3));
}

test "sub-width write truncates the value to the width" {
    var f = File{};
    f.writeWidth(5, .b, 0x1FF);
    try std.testing.expectEqual(@as(u64, 0xFF), f.read(5));
}

test "a reserved width encoding is reported, not silently accepted" {
    var f = File{};
    try std.testing.expectError(error.ReservedWidthEncoding, f.writeEncoded(1, 4, 0xFFFF));
    try std.testing.expectError(error.ReservedWidthEncoding, f.writeEncoded(1, 15, 0xFFFF));
    // The failed write must not have modified the register.
    try std.testing.expectEqual(@as(u64, 0), f.read(1));
}

test "register index encoding reaches the system registers" {
    var f = File{};
    f.write(12, 0x1000);
    f.write(13, 0x2000);
    f.write(14, 0x3000);
    f.write(15, 0x1);
    try std.testing.expectEqual(@as(u64, 0x1000), f.sp);
    try std.testing.expectEqual(@as(u64, 0x2000), f.lr);
    try std.testing.expectEqual(@as(u64, 0x3000), f.pc);
    try std.testing.expectEqual(@as(u64, 0x1), f.flags);
    try std.testing.expectEqual(@as(u64, 0x1000), f.read(12));
    try std.testing.expectEqual(@as(u64, 0x3000), f.read(14));
}

test "sub-width read masks to the width" {
    var f = File{};
    f.write(2, 0xFFFF_FFFF_FFFF_FFFF);
    try std.testing.expectEqual(@as(u64, 0xFFFF_FFFF), f.readWidth(2, .l));
    try std.testing.expectEqual(@as(u64, 0xFFFF), f.readWidth(2, .w));
    try std.testing.expectEqual(@as(u64, 0xFF), f.readWidth(2, .b));
    try std.testing.expectEqual(@as(u64, 0xFFFF_FFFF_FFFF_FFFF), f.readWidth(2, .full));
}

test "register names render for diagnostics" {
    const alloc = std.testing.allocator;
    const n = try name(alloc, 7);
    defer alloc.free(n);
    try std.testing.expectEqualStrings("R7", n);
    const s = try name(alloc, 12);
    defer alloc.free(s);
    try std.testing.expectEqualStrings("SP", s);
}

test "every width suffix maps to its documented bit count" {
    try std.testing.expectEqual(@as(u8, 64), Width.full.bits());
    try std.testing.expectEqual(@as(u8, 32), Width.l.bits());
    try std.testing.expectEqual(@as(u8, 16), Width.w.bits());
    try std.testing.expectEqual(@as(u8, 8), Width.b.bits());
}
