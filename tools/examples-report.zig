//! Prints the cross-architecture EXAMPLE SUITE report.
//!
//! WHAT THIS PRINTS: retired instructions and encoded bytes for six kernels, four
//! ISAs each, plus whether the declared win/loss expectation survived. Every figure
//! comes from the one measurement loop in `isaharness.zig`.
//!
//! WHAT IT MUST NEVER PRINT: a timing quantity, or a claim derived from one. See
//! `docs/comparison.md` §1 and `src/isaharness.zig` for why: assigning a cost per
//! instruction would mean inventing a microarchitecture for hardware that is not
//! running, which turns a statement about a program into a statement about a model.
//!
//! Equivalence is a PRECONDITION of printing, not a note underneath: `measureAll`
//! refuses an example whose four programs disagree, and this program exits non-zero
//! rather than printing a partial table that reads as a result.

const std = @import("std");
const examples = @import("examples");

pub fn main(init: std.process.Init) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var buf: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writer(init.io, &buf);
    const w = &file_writer.interface;
    defer w.flush() catch {};

    // The report is rendered into one buffer so its text can be produced by a test
    // as well as printed here, which is what stops the printed form and the tested
    // form from being two different things.
    const report_buf = try arena.alloc(u8, 64 * 1024);
    const outcomes = examples.measureAll(arena) catch |e| {
        try w.writeAll(
            "The example suite did not run to completion: at least one example's four programs\n" ++
                "did not compute the same thing, so no comparison table is printed. A table whose\n" ++
                "participants do different work is not a comparison. The failing example is named\n" ++
                "above, and running `zig build test` reproduces it.\n",
        );
        try w.flush();
        return switch (e) {
            error.NotEquivalent => 1,
            else => 2,
        };
    };

    const text = try examples.renderReport(arena, outcomes, report_buf);
    try w.writeAll(text);
    return 0;
}
