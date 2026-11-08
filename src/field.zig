//! Celeris-64 bitfield slicing engine (spec §3.3, AGENTS.md §3.3).
//!
//! `field.*` exists to remove manual shift-and-mask boilerplate for arbitrary
//! non-power-of-two domain values (U1, U3, U5, ...). A single call replaces the
//! `(v >> off) & ((1 << w) - 1)` dance and, more importantly, makes the range
//! check mandatory instead of optional.
//!
//! Normative reference: docs/isa-encoding.md §3.3 and §3.3.1.

const std = @import("std");

pub const FieldError = error{
    ZeroWidth,
    FieldExceedsRegister,
    InsertValueTooWide,
};

pub fn explain(err: FieldError) []const u8 {
    return switch (err) {
        error.ZeroWidth =>
            "A bitfield extraction asked for a width of zero bits. " ++
                "A field must hold at least one bit, so the request has no meaning.",
        error.FieldExceedsRegister =>
            "A bitfield request ran past the end of the 64-bit register. " ++
                "The starting bit position plus the field width must stay within the register.",
        error.InsertValueTooWide =>
            "The value being packed into a bitfield does not fit the declared field width. " ++
                "Packing it would silently discard the high bits, so the write was refused.",
    };
}

/// Mask of `width` low bits. `width` must be 1..=64.
pub fn mask(width: u8) FieldError!u64 {
    if (width == 0) return error.ZeroWidth;
    if (width > 64) return error.FieldExceedsRegister;
    if (width == 64) return @as(u64, std.math.maxInt(u64));
    return (@as(u64, 1) << @intCast(width)) - 1;
}

/// `field.extract`: pull `width` bits starting at `offset` out of `value`.
///
/// Range-checked rather than silently wrapping, per docs/isa-encoding.md §3.3.1.
pub fn extract(value: u64, offset: u8, width: u8) FieldError!u64 {
    const m = try mask(width);
    if (@as(u16, offset) + @as(u16, width) > 64) return error.FieldExceedsRegister;
    return (value >> @intCast(offset)) & m;
}

/// `field.insert`: place the low `width` bits of `field_value` at `offset`,
/// leaving every other bit of `base` untouched.
pub fn insert(base: u64, field_value: u64, offset: u8, width: u8) FieldError!u64 {
    const m = try mask(width);
    if (@as(u16, offset) + @as(u16, width) > 64) return error.FieldExceedsRegister;
    // Refuse rather than silently truncate: silent loss is the bug field.* exists to kill.
    if (width < 64 and (field_value & ~m) != 0) return error.InsertValueTooWide;
    const shifted = m << @intCast(offset);
    const cleared = base & ~shifted;
    return cleared | ((field_value & m) << @intCast(offset));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "spec's literal example: extract offset=12 width=3 from 0xDEADBEEFCAFEF00D" {
    // Hand-derived: 0xDEADBEEFCAFEF00D >> 12 = 0xDEADBEEFCAFE, low 3 bits = 0b111 = 7.
    try testing.expectEqual(@as(u64, 0x7), try extract(0xDEAD_BEEF_CAFE_F00D, 12, 3));
}

test "non-power-of-two widths round-trip through insert then extract (U1, U3, U5)" {
    var value: u64 = 0;
    value = try insert(value, 1, 0, 1); // U1
    value = try insert(value, 0b101, 1, 3); // U3
    value = try insert(value, 0b10001, 4, 5); // U5
    try testing.expectEqual(@as(u64, 1), try extract(value, 0, 1));
    try testing.expectEqual(@as(u64, 0b101), try extract(value, 1, 3));
    try testing.expectEqual(@as(u64, 0b10001), try extract(value, 4, 5));
}

test "extract at register boundaries" {
    try testing.expectEqual(@as(u64, 0), try extract(0xFFFF_FFFF_FFFF_FFFF, 63, 1) & 0);
    try testing.expectEqual(@as(u64, 1), try extract(0x8000_0000_0000_0000, 63, 1));
    // The HIGH 32 bits of 0xDEAD_BEEF_CAFE_F00D are 0xDEAD_BEEF, not the low half.
    try testing.expectEqual(@as(u64, 0xDEAD_BEEF), try extract(0xDEAD_BEEF_CAFE_F00D, 32, 32));
    try testing.expectEqual(@as(u64, 0xCAFE_F00D), try extract(0xDEAD_BEEF_CAFE_F00D, 0, 32));
    // offset 0, width 64 is the whole register.
    try testing.expectEqual(@as(u64, 0xDEAD_BEEF_CAFE_F00D), try extract(0xDEAD_BEEF_CAFE_F00D, 0, 64));
}

test "a field running past the register is refused, not wrapped" {
    try testing.expectError(error.FieldExceedsRegister, extract(0, 60, 5));
    try testing.expectError(error.FieldExceedsRegister, extract(0, 64, 1));
}

test "a zero-width field is refused" {
    try testing.expectError(error.ZeroWidth, extract(0, 0, 0));
    try testing.expectError(error.ZeroWidth, insert(0, 0, 0, 0));
}

test "insert refuses a value that does not fit the field" {
    try testing.expectError(error.InsertValueTooWide, insert(0, 0b1000, 0, 3));
    // Value fits exactly: allowed.
    _ = try insert(0, 0b111, 0, 3);
}

test "insert leaves every other bit untouched" {
    const base: u64 = 0xFFFF_FFFF_FFFF_FFFF;
    const out = try insert(base, 0b000, 4, 3);
    try testing.expectEqual(@as(u64, 0xFFFF_FFFF_FFFF_FF8F), out);
}
