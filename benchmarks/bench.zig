//! Celeris-64 benchmark harness: SIMULATOR INSTRUCTION COUNTS ONLY.
//!
//! ────────────────────────────────────────────────────────────────────────────
//! FIDELITY (docs/isa-encoding.md §8): these numbers are instruction counts
//! observed in a software model. They are NOT measurements of silicon. No chip
//! exists, nothing here was fabricated, and nothing here was timed. A count of
//! retired instructions says nothing about cycles, IPC, clock rate, cache
//! behaviour or real-world throughput.
//!
//! Every line this module prints contains the word "simulated". That is not
//! decoration: it is the guard against a reader mistaking a model's tally for a
//! performance claim. There is deliberately no "speedup", no "x faster", and no
//! percentage anywhere in the output.
//! ────────────────────────────────────────────────────────────────────────────
//!
//! What is being compared: a batch processed by the stream engine against the
//! same batch processed one element at a time by explicit software. Both are
//! real Celeris-64 programs executed by `src/vm.zig`. The comparison is of
//! *instruction counts in the model*, which is the only quantity a simulator can
//! honestly report.

const std = @import("std");
const vm = @import("vm");

pub const Report = struct {
    name: []const u8,
    /// Instructions retired by the model. Advisory simulator count.
    instructions: u64,
    /// Elements touched by the program, for context.
    elements: u64,

    /// Instructions per element, in the model. Printed as a count, never as a
    /// rate of anything physical.
    pub fn perElement(self: Report) f64 {
        if (self.elements == 0) return 0;
        return @as(f64, @floatFromInt(self.instructions)) / @as(f64, @floatFromInt(self.elements));
    }
};

/// Scratch image for one benchmark program. Allocated once, reused; the VM
/// allocates nothing after init (AGENTS.md §4.1).
const image_size: usize = 1 << 16;
const max_instructions: u64 = 1 << 20;

/// Where the streamed data lives: comfortably past any program these
/// benchmarks build (the longest is 11 words = 88 bytes).
///
/// This is not cosmetic. Both programs previously set the stream pointer to
/// address 0 — their own first instruction — so `stream.add` wrote the addend
/// into the program's own code while it ran. In the batch case that included
/// the `halt` word, which then failed to decode and ended the run early: the
/// benchmark reported 3 retired instructions where the program held 4, and the
/// self-modification was invisible because the count still looked plausible.
const data_base: u64 = 1 << 12;

/// Runs a program of words in a freshly zeroed image and returns the retired
/// count. `arena` owns the image for the duration of the call.
fn runProgram(arena: std.mem.Allocator, words: []const u64) !u64 {
    const image = try arena.alloc(u8, image_size);
    defer arena.free(image);
    @memset(image, 0);
    try vm.loadWords(image, 0, words);

    var machine = vm.Vm.init(image);
    _ = machine.run(max_instructions) catch |err| switch (err) {
        // A refused memory access is a benchmark bug, not a data point.
        error.OutOfBounds, error.VmFault => return error.BenchmarkFault,
    };
    return machine.retired;
}

/// Batch path: a single `stream.add` covers `chunk` elements.
///
/// The stream engine advances the pointer itself, so the software performs no
/// index arithmetic and no per-element branch. This is the pattern the
/// architecture exists to express.
///
/// Split from the run so a test can inspect the exact program (see the
/// self-modification test): asserting on a hand-copied program would let this
/// function regress while the test stayed green.
fn batchWords(arena: std.mem.Allocator, chunk: u4) ![]u64 {
    var words = std.ArrayList(u64).empty;
    errdefer words.deinit(arena);

    // R1 = data pointer (past the program, never over it), R2 = addend (5).
    try words.append(arena, vm.encode(0x19, 1, 0, vm.aluOperand(0, .full, data_base)));
    try words.append(arena, vm.encode(0x19, 2, 0, vm.aluOperand(0, .full, 5)));
    // One fused load/add/store over the whole chunk, auto-stepping R1.
    try words.append(arena, vm.encode(0x40, 0, 1, streamOperand(2, chunk, .full)));
    try words.append(arena, vm.encode(0x01, 0, 0, 0));
    return words.items;
}

fn batchAdd(arena: std.mem.Allocator, chunk: u4, elements: u64) !u64 {
    _ = elements;
    return runProgram(arena, try batchWords(arena, chunk));
}

/// Element-by-element path: an explicit software loop, one element per iteration.
///
/// This is the pattern the architecture's §1.2 forbids for inner loops, written
/// out honestly so the instruction-count difference can be observed rather than
/// asserted.
fn scalarWords(arena: std.mem.Allocator, chunk: u4) ![]u64 {
    var words = std.ArrayList(u64).empty;
    errdefer words.deinit(arena);

    try words.append(arena, vm.encode(0x19, 1, 0, vm.aluOperand(0, .full, data_base))); // R1 = data pointer
    try words.append(arena, vm.encode(0x19, 2, 0, vm.aluOperand(0, .full, 5))); // R2 = 5
    // `chunk` separate load/add/store triples: no fused engine, one element each.
    var i: u4 = 0;
    while (i < chunk) : (i += 1) {
        try words.append(arena, vm.encode(0x40, 0, 1, streamOperand(2, 1, .full)));
    }
    try words.append(arena, vm.encode(0x01, 0, 0, 0));
    return words.items;
}

fn scalarLoop(arena: std.mem.Allocator, chunk: u4, elements: u64) !u64 {
    _ = elements;
    return runProgram(arena, try scalarWords(arena, chunk));
}

/// §3.4 stream operand: rs2[47:44], chunk[43:24], element width[23:20].
fn streamOperand(rs2: u4, chunk: u20, width: vm.Width) u48 {
    return (@as(u48, rs2) << 44) | (@as(u48, chunk) << 24) | (@as(u48, @intFromEnum(width)) << 20);
}

/// Writes one report line. EVERY line produced here contains "simulated".
pub fn writeReportLine(report: Report, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.print(
        "  {s}: {d} simulated instructions retired to process {d} elements ({d:.2} simulated instructions per element).\n",
        .{ report.name, report.instructions, report.elements, report.perElement() },
    );
}

/// Runs the whole comparison and prints it. Returns the two reports so a test
/// can assert on the numbers rather than on formatted text.
pub fn runAll(arena: std.mem.Allocator, w: *std.Io.Writer) !struct { batch: Report, scalar: Report } {
    const chunk: u4 = 8;

    const batch_count = try batchAdd(arena, chunk, chunk);
    const scalar_count = try scalarLoop(arena, chunk, chunk);

    const batch = Report{ .name = "stream batch", .instructions = batch_count, .elements = chunk };
    const scalar = Report{ .name = "element-by-element loop", .instructions = scalar_count, .elements = chunk };

    // One statement per line, each carrying the word "simulated", so no line of
    // this report can be quoted without its fidelity label attached.
    try w.writeAll(
        \\Celeris-64 benchmark: simulated instruction counts only.
        \\
    );
    try w.writeAll(
        \\This simulated report comes from a software model, not from silicon.
        \\No simulated figure was measured on hardware; no hardware exists.
        \\A simulated count is not a claim about any physical device.
        \\
    );
    try writeReportLine(batch, w);
    try writeReportLine(scalar, w);
    try w.writeAll(
        \\The simulated difference above is a property of the simulated stream.
        \\It is a simulated count of instructions, not a claim about speed.
        \\
    );
    return .{ .batch = batch, .scalar = scalar };
}

/// Renders the whole benchmark into a caller-provided buffer.
pub fn renderToBuffer(arena: std.mem.Allocator, buf: []u8) ![]const u8 {
    var w = std.Io.Writer.fixed(buf);
    _ = try runAll(arena, &w);
    return w.buffered();
}

pub fn main(init: std.process.Init) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();

    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &buf);
    _ = try runAll(arena_state.allocator(), &w.interface);
    try w.interface.flush();
    return 0;
}

// -- tests --------------------------------------------------------------------

const testing = std.testing;

test "every non-blank benchmark output line contains the word simulated" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var buf: [4096]u8 = undefined;
    const text = try renderToBuffer(arena_state.allocator(), &buf);

    var lines = std.mem.splitScalar(u8, text, '\n');
    var checked: usize = 0;
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
        checked += 1;
        try testing.expect(std.mem.indexOf(u8, line, "simulated") != null);
    }
    // The report must actually be a report: a header, two data lines, a footer.
    try testing.expect(checked >= 5);
}

test "benchmark output makes no speedup or percentage claim" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var buf: [4096]u8 = undefined;
    const text = try renderToBuffer(arena_state.allocator(), &buf);
    const lowered = try std.ascii.allocLowerString(testing.allocator, text);
    defer testing.allocator.free(lowered);

    // The exact vocabulary a real-world performance claim would use.
    try testing.expect(std.mem.indexOf(u8, lowered, "speedup") == null);
    try testing.expect(std.mem.indexOf(u8, lowered, "faster") == null);
    try testing.expect(std.mem.indexOf(u8, lowered, "%") == null);
    try testing.expect(std.mem.indexOf(u8, lowered, "cycle") == null);
    try testing.expect(std.mem.indexOf(u8, lowered, "ghz") == null);
    try testing.expect(std.mem.indexOf(u8, lowered, "throughput") == null);
}

test "the batch path retires fewer simulated instructions than the scalar path" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const results = try runAll(arena_state.allocator(), &w);

    // Both programs do real work and both halt.
    try testing.expect(results.batch.instructions > 0);
    try testing.expect(results.scalar.instructions > 0);
    // One fused instruction covering the chunk costs less than one instruction
    // per element. This is a property of the instruction stream in the model.
    try testing.expect(results.batch.instructions < results.scalar.instructions);
    // The scalar path needs at least one stream instruction per element.
    try testing.expect(results.scalar.instructions >= 8);
}

test "the batch path retires exactly its four instruction words" {
    // The defect this pins (docs/STATUS.md F17): the batch program used to point
    // its stream at address 0, which is its own first instruction. `stream.add`
    // then added the addend to the program's own code, including its `halt`
    // word, which stopped decoding and ended the run one instruction early. The
    // count came out 3 instead of 4 and NOTHING noticed, because every existing
    // assertion was relative (`<` the scalar path, `> 0`). A count is only
    // checked by comparing it to a number.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const results = try runAll(arena_state.allocator(), &w);

    // The batch program is exactly: R1 = data, R2 = addend, stream.add, halt.
    try testing.expectEqual(@as(u64, 4), results.batch.instructions);
}

test "neither benchmark program modifies its own instructions" {
    // The direct check for the F17 defect, independent of any instruction count:
    // run each program and compare its own code bytes before and after. A program
    // that rewrites itself while running is a benchmark bug, and it must be
    // caught as self-modification rather than inferred from a suspicious count.
    //
    // These run the REAL builders, not hand-copied programs. A copy would be a
    // test of the copy: `batchWords` could regress to streaming over address 0
    // while this test stayed green, which is the same trap as the relational
    // assertions that let F17 ship.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const image = try arena.alloc(u8, image_size);

    for ([_]struct { name: []const u8, words: []const u64 }{
        .{ .name = "batch", .words = try batchWords(arena, 8) },
        .{ .name = "scalar", .words = try scalarWords(arena, 8) },
    }) |prog| {
        @memset(image, 0);
        try vm.loadWords(image, 0, prog.words);
        const code_bytes = prog.words.len * vm.instruction_bytes;
        const before = try arena.dupe(u8, image[0..code_bytes]);

        var machine = vm.Vm.init(image);
        _ = machine.run(max_instructions) catch |err| switch (err) {
            error.OutOfBounds, error.VmFault => return error.BenchmarkFault,
        };

        // Both must halt normally, and neither may have rewritten its own code.
        try testing.expect(machine.halted);
        try testing.expectEqualSlices(u8, before, image[0..code_bytes]);
    }
}

test "reports carry counts, never a rate of anything physical" {
    const r = Report{ .name = "x", .instructions = 10, .elements = 4 };
    try testing.expectApproxEqAbs(@as(f64, 2.5), r.perElement(), 0.0001);
    const empty = Report{ .name = "y", .instructions = 0, .elements = 0 };
    try testing.expectEqual(@as(f64, 0), empty.perElement());
}
