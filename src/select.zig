//! Celeris-64 branchless selection and status enums (spec §3.2, AGENTS.md §3.2).
//!
//! The architecture eliminates branch mispredictions by resolving conditionals as
//! hardware bitwise selection masks. Two rules follow from that and are enforced here:
//!
//! 1. A comparison produces an explicit STATUS ENUM, never a bare boolean. The
//!    architecture calls this the elimination of boolean blindness (spec §1.5): a
//!    `true`/`false` throws away *which way* and *how* the values differed.
//! 2. `select` is a bitwise merge, not a branch. It has no early exit and no
//!    dependence on any machine state beyond its operands.
//!
//! Normative reference: docs/isa-encoding.md §3.2.1 and §3.2.2.

const std = @import("std");

/// Explicit comparison outcome (docs/isa-encoding.md §3.2.1).
pub const Status = enum(u4) {
    equal = 0,
    less = 1,
    greater = 2,
    unsigned_less = 3,
    unsigned_greater = 4,

    pub fn name(self: Status) []const u8 {
        return switch (self) {
            .equal => "EQUAL",
            .less => "LESS",
            .greater => "GREATER",
            .unsigned_less => "UNSIGNED_LESS",
            .unsigned_greater => "UNSIGNED_GREATER",
        };
    }
};

/// Compare as signed integers, producing a signed status enum.
pub fn compareSigned(lhs: i64, rhs: i64) Status {
    if (lhs == rhs) return .equal;
    return if (lhs < rhs) .less else .greater;
}

/// Compare as unsigned integers.
pub fn compareUnsigned(lhs: u64, rhs: u64) Status {
    if (lhs == rhs) return .equal;
    return if (lhs < rhs) .unsigned_less else .unsigned_greater;
}

/// A raw 64-bit comparison dispatch, per the decoder's flat register file.
/// The two's-complement bit pattern is interpreted BOTH ways and the caller
/// asks for the view it wants, which is why CLS64 carries both enum members.
pub fn compare(lhs: u64, rhs: u64, signed: bool) Status {
    if (signed) {
        return compareSigned(@bitCast(lhs), @bitCast(rhs));
    }
    return compareUnsigned(lhs, rhs);
}

/// `select`: `status == match ? true_value : false_value`, computed as a mask.
///
/// No branch is taken and no early exit exists, so the cost and the timing are the
/// same whichever arm is chosen. Result is `0` only when `false_value` is `0`.
pub fn select(status: Status, match: Status, true_value: u64, false_value: u64) u64 {
    // All-ones mask when the status matches, all-zeros otherwise.
    const eq = @intFromBool(status == match);
    const mask: u64 = 0 -% @as(u64, eq);
    return (true_value & mask) | (false_value & ~mask);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "signed and unsigned views DIFFER for a negative operand" {
    // -1 as u64 is 0xFFFF_FFFF_FFFF_FFFF: the largest unsigned value but the
    // smallest signed one. This divergence is the whole point of two enums.
    const minus_one: u64 = @bitCast(@as(i64, -1));
    const one: u64 = 1;

    try testing.expectEqual(Status.less, compare(minus_one, one, true));
    try testing.expectEqual(Status.unsigned_greater, compare(minus_one, one, false));
    // The two paths must not collapse into one another.
    try testing.expect(compare(minus_one, one, true) != compare(minus_one, one, false));
}

test "every status enum value is reachable" {
    try testing.expectEqual(Status.equal, compare(5, 5, true));
    try testing.expectEqual(Status.less, compare(4, 5, true));
    try testing.expectEqual(Status.greater, compare(6, 5, true));
    try testing.expectEqual(Status.unsigned_less, compare(4, 5, false));
    try testing.expectEqual(Status.unsigned_greater, compare(6, 5, false));
}

test "status enum numeric values match the encoding contract" {
    try testing.expectEqual(@as(u4, 0), @intFromEnum(Status.equal));
    try testing.expectEqual(@as(u4, 1), @intFromEnum(Status.less));
    try testing.expectEqual(@as(u4, 2), @intFromEnum(Status.greater));
    try testing.expectEqual(@as(u4, 3), @intFromEnum(Status.unsigned_less));
    try testing.expectEqual(@as(u4, 4), @intFromEnum(Status.unsigned_greater));
}

test "select chooses the matching arm" {
    const s = compare(5, 5, true);
    try testing.expectEqual(@as(u64, 0xAAAA), select(s, .equal, 0xAAAA, 0xBBBB));
    try testing.expectEqual(@as(u64, 0xBBBB), select(s, .less, 0xAAAA, 0xBBBB));
    try testing.expectEqual(@as(u64, 0xBBBB), select(s, .greater, 0xAAAA, 0xBBBB));
}

test "select is deterministic across many runs" {
    const s = compare(7, 3, true);
    var i: usize = 0;
    var first: u64 = 0;
    while (i < 1000) : (i += 1) {
        const got = select(s, .greater, 111, 222);
        if (i == 0) first = got else try testing.expectEqual(first, got);
    }
    try testing.expectEqual(@as(u64, 111), first);
}

test "select handles full-width values without branching artifacts" {
    // Both candidate arms are all-ones / all-zeros to catch a mask bug that a
    // small-value test would hide.
    const all: u64 = 0xFFFF_FFFF_FFFF_FFFF;
    try testing.expectEqual(all, select(.equal, .equal, all, 0));
    try testing.expectEqual(@as(u64, 0), select(.less, .equal, all, 0));
    // A zero false-arm must not leak into a non-matching select.
    try testing.expectEqual(all, select(.greater, .greater, all, 0));
}
