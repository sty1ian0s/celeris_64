//! Prints the cross-architecture comparison table.
//!
//! WHAT THIS PRINTS: retired instructions and encoded bytes for the same workload
//! on four ISAs, measured by one shared loop.
//!
//! WHAT IT MUST NEVER PRINT: cycles, time, frequency, throughput, or any "faster"
//! comparison. Those would require inventing a microarchitecture for CPUs that are
//! not present, and the invention would be this file's author's design rather than
//! a fact about the chips. `docs/comparison.md` §1 states the same rule for the
//! older tables; this program obeys it for the new ones.

const std = @import("std");
const crossarch = @import("crossarch");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    var buf: [8192]u8 = undefined;
    var file_writer = std.Io.File.stdout().writer(io, &buf);
    const w = &file_writer.interface;
    defer w.flush() catch {};

    try w.writeAll(
        \\Celeris-64 cross-architecture workload comparison.
        \\
        \\All figures below are produced by ONE measurement loop executing REAL machine
        \\code on four instruction set architectures. The workload is the same in every
        \\row: add 5 to each of 8 contiguous 64-bit elements.
        \\
        \\  retired     instructions that executed
        \\  code bytes  bytes those instructions occupied, as encoded
        \\  bytes/insn  the density figure (lower is denser)
        \\
        \\What this does NOT measure: cycles, time, clock frequency, throughput or
        \\speed. Assigning a cycle cost would mean inventing a microarchitecture for
        \\hardware that is not present, which would make the comparison a statement
        \\about the model rather than about the chips. No speedup is claimed or
        \\derivable from this table.
        \\
        \\
    );

    const measurements = try crossarch.measureAll(arena);

    try w.print("  {s:<16} {s:<8} {s:>9} {s:>11} {s:>11}\n", .{ "ISA", "shape", "retired", "code bytes", "bytes/insn" });
    try w.print("  {s:-<16} {s:-<8} {s:->9} {s:->11} {s:->11}\n", .{ "", "", "", "", "" });

    for (measurements) |m| {
        const density = m.bytesPerInsn();
        if (density) |d| {
            try w.print("  {s:<16} {s:<8} {d:>9} {d:>11} {d:>11.2}\n", .{
                m.isa, @tagName(m.shape), m.result.retired, m.result.code_bytes, d,
            });
        } else {
            try w.print("  {s:<16} {s:<8} {d:>9} {d:>11} {s:>11}\n", .{
                m.isa, @tagName(m.shape), m.result.retired, m.result.code_bytes, "n/a",
            });
        }

        if (!m.correct) {
            try w.print("  !! {s} did not compute the expected result — its row is not comparable\n", .{m.isa});
        }
        if (m.result.faulted) {
            try w.print("  !! {s} faulted; its row counts only the instructions that retired\n", .{m.isa});
        }
    }

    try w.writeAll(
        \\
        \\Read this before quoting any number above:
        \\
        \\  * A retired-instruction count is a property of the PROGRAM, not of a core.
        \\    A real x86-64 core cracks most of these instructions into several micro-ops;
        \\    this table counts one per instruction, so it is not a micro-op count.
        \\  * "bytes/insn" is an encoding-density figure. It says how compact the
        \\    instruction stream is, which is a real architectural property, and it
        \\    says nothing at all about execution speed.
        \\  * The programs were written by hand for this repository, not produced by an
        \\    optimising compiler. A different hand-written program would produce
        \\    different counts for the same ISA.
        \\
    );
}
