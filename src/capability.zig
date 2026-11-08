//! Celeris-64 capability pointer model (spec §2.3, AGENTS.md §2.5).
//!
//! ════════════════════════════════════════════════════════════════════════════
//! FIDELITY — READ THIS BEFORE TRUSTING ANYTHING BELOW (docs/isa-encoding.md §8)
//!
//! This is a SOFTWARE MODEL of a CHERI-style capability. It is NOT cryptography.
//! It is NOT unforgeable. It does NOT resist a hostile program that constructs a
//! descriptor by hand, and it provides NO protection against a caller who simply
//! writes a `Capability{ .base = ..., .length = ... }` literal. There are no tag
//! bits, no sealing, no provenance and no hardware enforcement, because there is
//! no hardware.
//!
//! What it DOES provide is the architectural contract in executable form: bounds
//! and permission checks at a single choke point, so that a memory access either
//! names its authority or fails with a plain-language diagnostic. That is useful
//! for testing program logic and for making overreach visible.
//!
//! It is NOT useful as a security boundary and must never be described as one.
//! ════════════════════════════════════════════════════════════════════════════
//!
//! Normative reference: docs/isa-encoding.md §6.

const std = @import("std");

/// Permission bits (§6): bit 0 read, bit 1 write, bit 2 execute.
pub const Perms = packed struct(u8) {
    read: bool = false,
    write: bool = false,
    execute: bool = false,
    _reserved: u5 = 0,

    pub fn all() Perms {
        return .{ .read = true, .write = true, .execute = true };
    }
    pub fn readOnly() Perms {
        return .{ .read = true };
    }
};

pub const CapError = error{
    BelowBase,
    AboveTop,
    NoReadPermission,
    NoWritePermission,
    NoExecutePermission,
    LengthOutOfRange,
};

/// Plain-language explanation. AGENTS.md §4.2 forbids bare hexadecimal codes.
pub fn explain(err: CapError, address: u64, base: u64, length: u64) []const u8 {
    _ = address;
    _ = base;
    _ = length;
    return switch (err) {
        error.BelowBase =>
            "The program tried to reach memory below the start of its capability. " ++
                "The pointer began before the region it was allowed to touch, so the access was refused.",
        error.AboveTop =>
            "The program tried to reach memory past the end of its capability. " ++
                "The access would have landed outside the region the pointer was allowed to touch, " ++
                "so it was refused rather than allowed to run into unrelated data.",
        error.NoReadPermission =>
            "The program tried to read through a capability that does not grant read permission.",
        error.NoWritePermission =>
            "The program tried to write through a capability that does not grant write permission. " ++
                "The value was not stored.",
        error.NoExecutePermission =>
            "The program tried to execute code through a capability that does not grant execute permission.",
        error.LengthOutOfRange =>
            "A capability was created with a length that does not describe a real region of memory.",
    };
}

/// 128-bit capability descriptor (§6): base + length + permissions.
///
/// Represented as the architecture specifies: a 64-bit base, a 64-bit length and
/// a permission byte. Not a cryptographic tag — see the fidelity note above.
pub const Capability = struct {
    base: u64,
    length: u64,
    perms: Perms,

    pub fn init(base: u64, length: u64, perms: Perms) CapError!Capability {
        if (length == 0) return error.LengthOutOfRange;
        return .{ .base = base, .length = length, .perms = perms };
    }

    /// One past the last addressable byte. Uses saturating add so a capability
    /// near the top of the address space cannot wrap and appear to cover everything.
    pub fn top(self: Capability) u64 {
        return self.base +| self.length;
    }

    /// Does `[address, address+size)` lie entirely inside this capability?
    /// Checked as a range, never per byte, so a partially-out-of-bounds access
    /// is refused whole rather than half-performed.
    pub fn covers(self: Capability, address: u64, size: u64) bool {
        if (size == 0) return false;
        // Compute the end WITHOUT saturating, or an overflowing request would
        // clamp to maxInt and appear to fit a capability that reaches the top.
        // Overflow-checked add: if it overflows, the request runs off the address
        // space and must be refused.
        const end = std.math.add(u64, address, size) catch return false;
        return address >= self.base and end <= self.top();
    }

    pub fn check(self: Capability, address: u64, size: u64, access: Access) CapError!void {
        if (!self.covers(address, size)) {
            if (address < self.base) return error.BelowBase;
            return error.AboveTop;
        }
        switch (access) {
            .read => if (!self.perms.read) return error.NoReadPermission,
            .write => if (!self.perms.write) return error.NoWritePermission,
            .execute => if (!self.perms.execute) return error.NoExecutePermission,
        }
    }

    /// Derive a narrower capability inside this one. A child can never exceed its
    /// parent's region — that containment property is the whole point of a
    /// capability system, and it is the part worth modelling even without tags.
    pub fn narrow(self: Capability, offset: u64, length: u64, perms: Perms) CapError!Capability {
        if (length == 0) return error.LengthOutOfRange;
        if (offset > self.length) return error.AboveTop;
        if (length > self.length - offset) return error.AboveTop;
        // Permissions may only ever be reduced, never amplified.
        const narrowed = Perms{
            .read = perms.read and self.perms.read,
            .write = perms.write and self.perms.write,
            .execute = perms.execute and self.perms.execute,
        };
        return .{ .base = self.base + offset, .length = length, .perms = narrowed };
    }
};

pub const Access = enum { read, write, execute };

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "a capability covers exactly its own region" {
    const cap = try Capability.init(0x1000, 0x100, Perms.all());
    try testing.expect(cap.covers(0x1000, 1));
    try testing.expect(cap.covers(0x10FF, 1)); // last byte
    try testing.expect(!cap.covers(0x1100, 1)); // one past the end
    try testing.expect(!cap.covers(0x0FFF, 1)); // one below the base
}

test "an access is refused whole, never truncated and never zero" {
    const cap = try Capability.init(0x1000, 0x10, Perms.all());
    // 8 bytes at 0x100C would end at 0x1014, past the top at 0x1010.
    try testing.expect(!cap.covers(0x100C, 8));
    try testing.expectError(error.AboveTop, cap.check(0x100C, 8, .read));
    // The last exactly-fitting access is allowed.
    try cap.check(0x1008, 8, .read);
}

test "permission bits are enforced" {
    const ro = try Capability.init(0, 64, Perms.readOnly());
    try ro.check(0, 8, .read);
    try testing.expectError(error.NoWritePermission, ro.check(0, 8, .write));
    try testing.expectError(error.NoExecutePermission, ro.check(0, 8, .execute));
}

test "a child capability can never exceed its parent" {
    const parent = try Capability.init(0x1000, 0x100, Perms.all());
    const child = try parent.narrow(0x10, 0x20, Perms.all());
    try testing.expectEqual(@as(u64, 0x1010), child.base);
    try testing.expectEqual(@as(u64, 0x20), child.length);

    // Escaping the parent is refused in both directions.
    try testing.expectError(error.AboveTop, parent.narrow(0x10, 0x200, Perms.all()));
    try testing.expectError(error.AboveTop, parent.narrow(0x200, 0x10, Perms.all()));
}

test "a child cannot amplify permissions, only reduce them" {
    const parent = try Capability.init(0, 64, Perms.readOnly());
    // Asking for write on a read-only parent yields a still-read-only child.
    const child = try parent.narrow(0, 32, Perms.all());
    try testing.expect(!child.perms.write);
    try testing.expect(!child.perms.execute);
    try testing.expect(child.perms.read);
    try testing.expectError(error.NoWritePermission, child.check(0, 8, .write));
}

test "a zero-size request is refused rather than treated as always-in-bounds" {
    const cap = try Capability.init(0x1000, 0x100, Perms.all());
    // The classic bug: a zero-length request that vacuously satisfies a naive
    // bounds test. It must be refused explicitly.
    try testing.expect(!cap.covers(0x1000, 0));
}

test "a zero-length capability is refused at construction" {
    try testing.expectError(error.LengthOutOfRange, Capability.init(0, 0, Perms.all()));
}

test "top saturates instead of wrapping around the address space" {
    // A capability ending at the very top must not appear to cover everything.
    const cap = try Capability.init(std.math.maxInt(u64) - 8, 16, Perms.all());
    try testing.expectEqual(std.math.maxInt(u64), cap.top());
    // A request that would wrap is refused, not silently accepted.
    try testing.expect(!cap.covers(std.math.maxInt(u64) - 2, 8));
}

test "MODEL LIMITS: this is not cryptography and does not resist forgery" {
    // This test exists to state the limitation in executable form, so nobody can
    // read the module and mistake it for a security boundary. A forged descriptor
    // is indistinguishable from a legitimate one, BY CONSTRUCTION.
    const forged = Capability{ .base = 0, .length = std.math.maxInt(u64), .perms = Perms.all() };
    // The forged capability grants access to everything, and nothing here stops it.
    try forged.check(0, 8, .write);
    try testing.expect(forged.covers(0, std.math.maxInt(u64)));

    // There is no tag bit, no sealing and no provenance check to catch this.
    // Real CHERI stops this in hardware; this model cannot and does not claim to.
    try testing.expect(@sizeOf(Capability) <= 24);
}
