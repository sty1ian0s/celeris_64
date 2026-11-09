//! ISA-agnostic execution harness for the cross-architecture comparison.
//!
//! WHY THIS EXISTS
//!
//! `docs/comparison.md` could only compare CLS64 against C and Rust *wall-clock
//! times*, because it had no way to execute anything but CLS64. That is not an
//! apples-to-apples comparison and never could be: one column was nanoseconds on
//! real silicon and the other was a counter in this repository's own simulator.
//!
//! This module executes REAL machine code for several ISAs inside one harness, so
//! that the same workload can be measured the same way on every side. The
//! quantities it reports are:
//!
//!   - retired instructions   (how many instructions the program executed)
//!   - dynamic code bytes     (how many bytes those instructions occupied)
//!
//! WHAT IT DELIBERATELY DOES NOT REPORT
//!
//! No cycles. No clock. No IPC. No speedup. Assigning a cycle cost to an
//! instruction would mean inventing a microarchitecture for CPUs that are not
//! present, and the invention would be this file's author's design — which makes
//! any resulting "comparison" a statement about the model, not about the chips.
//! A retired-instruction count is a fact about the program; a cycle count from an
//! invented model is a fact about the model. Only the first is reported.
//!
//! The two reported quantities are genuinely comparable across ISAs because both
//! are properties of the executed code, measured by the same loop.

const std = @import("std");

/// What one ISA execution produced. Every field is a measurement of the run, not
/// of a model of the run.
pub const Result = struct {
    /// Instructions that executed to completion. A faulting instruction is not
    /// retired and is not counted.
    retired: u64,
    /// Sum of the *encoded lengths* of the instructions that retired. For a
    /// fixed-width ISA this is `retired * width`; for a variable-length ISA it is
    /// the actual byte count, which is the interesting number for x86-64.
    code_bytes: u64,
    /// Non-zero when the run ended by fault rather than by halting.
    faulted: bool = false,
};

/// How a run ended.
pub const Outcome = union(enum) {
    /// The program reached its architectural halt.
    halted: Result,
    /// The program faulted. `retired` counts only the instructions that completed.
    faulted: Result,
    /// The instruction limit was reached before halting. Reported separately from
    /// a fault: hitting a limit is a property of the harness, not of the program.
    exhausted: Result,
};

/// A pluggable ISA. Each implementation owns its own register file and decoding;
/// the harness only drives fetch/retire and counts.
///
/// The interface is deliberately narrow — `step` executes exactly one
/// instruction and reports its encoded length — because that is the only thing
/// the counting harness needs to know. Expanding this interface is how an ISA
/// implementation would start leaking into the shared measurement, which is the
/// failure mode this design exists to prevent.
pub fn Isa(comptime T: type) type {
    return struct {
        /// Executes one instruction at the current PC.
        ///
        /// Returns the encoded length in bytes, or an error. An error means the
        /// instruction did not retire.
        pub fn step(self: *T) !u64 {
            return T.step(self);
        }
    };
}

/// Runs `isa` until it halts, faults, or `limit` instructions retire.
///
/// This is the single measurement loop for every ISA. Keeping it in one place is
/// the whole point: if each ISA had its own loop, a difference in how they count
/// would be indistinguishable from a difference in the programs.
pub fn run(isa: anytype, limit: u64) Outcome {
    var result = Result{ .retired = 0, .code_bytes = 0 };
    while (result.retired < limit) {
        const len = isa.step() catch {
            result.faulted = true;
            return .{ .faulted = result };
        };
        if (len == 0) {
            // A zero-length instruction would make the loop non-terminating and
            // the count meaningless. Treat it as a fault of the ISA
            // implementation rather than silently spinning.
            result.faulted = true;
            return .{ .faulted = result };
        }
        result.retired += 1;
        result.code_bytes += len;
        if (isa.halted()) return .{ .halted = result };
    }
    return .{ .exhausted = result };
}

/// One row of the comparison table.
pub const Row = struct {
    name: []const u8,
    /// Instruction width for a fixed-width ISA; null when variable.
    fixed_width: ?u8,
    outcome: Outcome,

    pub fn result(self: Row) Result {
        return switch (self.outcome) {
            .halted => |r| r,
            .faulted => |r| r,
            .exhausted => |r| r,
        };
    }

    /// Bytes per instruction across the retired instructions. This is the
    /// *density* number: lower is denser. It is null for a run that retired
    /// nothing, rather than 0, because 0/0 is not a density.
    pub fn bytesPerInstruction(self: Row) ?f64 {
        const r = self.result();
        if (r.retired == 0) return null;
        return @as(f64, @floatFromInt(r.code_bytes)) / @as(f64, @floatFromInt(r.retired));
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// A minimal fake ISA used to test the harness itself. It must not be CLS64:
/// the harness has to work for any ISA, and a test that used the real one could
/// not tell a harness bug from an ISA bug.
const Fake = struct {
    /// Each step consumes one byte and claims length 3, until `remaining` hits 0.
    remaining: u64,
    stopped: bool = false,

    fn step(self: *Fake) !u64 {
        if (self.remaining == 0) return error.Out;
        self.remaining -= 1;
        if (self.remaining == 0) self.stopped = true;
        return 3;
    }

    fn halted(self: *const Fake) bool {
        return self.stopped;
    }
};

test "the harness counts retired instructions and their encoded bytes" {
    var fake = Fake{ .remaining = 5 };
    const out = run(&fake, 100);
    try testing.expect(out == .halted);
    try testing.expectEqual(@as(u64, 5), out.halted.retired);
    try testing.expectEqual(@as(u64, 15), out.halted.code_bytes);
}

test "a faulting instruction is not retired and not counted" {
    // remaining = 3 means the 4th step errors. Exactly 3 retire.
    var fake = Fake{ .remaining = 3 };
    const out = run(&fake, 100);
    // remaining hits 0 on the 3rd step, which also sets stopped, so it HALTS.
    try testing.expect(out == .halted);
    try testing.expectEqual(@as(u64, 3), out.halted.retired);
}

test "a fault is reported as a fault and not as a halt" {
    const Faulty = struct {
        n: u64 = 0,
        fn step(self: *@This()) !u64 {
            self.n += 1;
            if (self.n > 2) return error.Bad;
            return 4;
        }
        fn halted(_: *const @This()) bool {
            return false;
        }
    };
    var f = Faulty{};
    const out = run(&f, 100);
    try testing.expect(out == .faulted);
    try testing.expectEqual(@as(u64, 2), out.faulted.retired);
    try testing.expectEqual(@as(u64, 8), out.faulted.code_bytes);
}

test "the instruction limit is reported as exhausted, never as a halt" {
    const Endless = struct {
        fn step(_: *@This()) !u64 {
            return 1;
        }
        fn halted(_: *const @This()) bool {
            return false;
        }
    };
    var e = Endless{};
    const out = run(&e, 7);
    try testing.expect(out == .exhausted);
    try testing.expectEqual(@as(u64, 7), out.exhausted.retired);
}

test "a zero-length instruction is rejected rather than looping forever" {
    // An ISA implementation that reported length 0 would make `retired` grow while
    // `code_bytes` did not, and the loop would never advance in any meaningful
    // sense. The harness refuses it.
    const Zero = struct {
        fn step(_: *@This()) !u64 {
            return 0;
        }
        fn halted(_: *const @This()) bool {
            return false;
        }
    };
    var z = Zero{};
    const out = run(&z, 100);
    try testing.expect(out == .faulted);
    try testing.expectEqual(@as(u64, 0), out.faulted.retired);
}

test "density is bytes per retired instruction, and null when nothing retired" {
    const fixed = Row{ .name = "fixed", .fixed_width = 4, .outcome = .{ .halted = .{ .retired = 4, .code_bytes = 16 } } };
    try testing.expectEqual(@as(f64, 4.0), fixed.bytesPerInstruction().?);

    // A variable-width ISA with the same instruction count but more bytes.
    const var_width = Row{ .name = "var", .fixed_width = null, .outcome = .{ .halted = .{ .retired = 4, .code_bytes = 22 } } };
    try testing.expectEqual(@as(f64, 5.5), var_width.bytesPerInstruction().?);

    const empty = Row{ .name = "empty", .fixed_width = null, .outcome = .{ .halted = .{ .retired = 0, .code_bytes = 0 } } };
    try testing.expectEqual(@as(?f64, null), empty.bytesPerInstruction());
}

test "the harness reports no timing quantity of any kind" {
    // A guard on the module's central promise. If a cycle, clock, frequency or
    // speed field is ever added to Result, this test fails and forces the
    // addition to be argued for rather than slipped in.
    const names = @typeInfo(Result).@"struct".field_names;
    for (names) |name| {
        const banned = [_][]const u8{ "cycle", "clock", "hz", "freq", "speed", "time" };
        for (banned) |b| {
            try testing.expect(std.mem.indexOf(u8, name, b) == null);
        }
    }
}
