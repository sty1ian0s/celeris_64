//! Celeris-64 command-line interface.
//!
//! Subcommands:
//!   asm     <in.asm> <out.bin>   assemble source to a flat little-endian image
//!   run     <in.asm>             assemble in memory, then execute
//!   run-bin <in.bin>             load a flat image, then execute
//!   dis     <in.bin>             disassemble a flat image
//!   trace   <in.asm>             execute and print a step-by-step trace
//!
//! Exit codes: 0 success, 1 the input was rejected with a diagnostic, 2 the
//! command line was wrong. No failure is ever a bare hexadecimal code
//! (AGENTS.md §4.2); every failure is a sentence.
//!
//! Fidelity: this drives a *software model*. Instruction counts it prints are
//! simulator counts, not silicon performance (docs/isa-encoding.md §8).

const std = @import("std");
const assembler = @import("assembler.zig");
const disassembler = @import("disassembler.zig");
const diagnostics = @import("diagnostics.zig");
const vm_mod = @import("vm.zig");

const Diagnostic = diagnostics.Diagnostic;

/// Memory image handed to the VM. The VM allocates nothing after init, so this
/// buffer is sized once, here (AGENTS.md §4.1).
const image_bytes: usize = 1 << 16;
const max_instructions: u64 = 1 << 20;

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    return runCli(init.io, args, init.arena.allocator());
}

/// Testable core. Returns the process exit code; user-visible text goes to
/// stdout or stderr.
pub fn runCli(io: std.Io, args: []const [:0]const u8, alloc: std.mem.Allocator) u8 {
    if (args.len < 2) {
        printUsage(io);
        return 2;
    }

    const command = args[1];
    if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "help")) {
        printUsage(io);
        return 0;
    }

    if (std.mem.eql(u8, command, "asm")) {
        if (args.len != 4) return usageError("asm needs exactly two file names: the source to read and the image to write");
        return cmdAssemble(io, alloc, args[2], args[3]);
    }
    if (std.mem.eql(u8, command, "run")) {
        if (args.len != 3) return usageError("run needs exactly one file name: the source program to execute");
        return cmdRunSource(io, alloc, args[2]);
    }
    if (std.mem.eql(u8, command, "run-bin")) {
        if (args.len != 3) return usageError("run-bin needs exactly one file name: the flat image to execute");
        return cmdRunImage(io, alloc, args[2]);
    }
    if (std.mem.eql(u8, command, "dis")) {
        if (args.len != 3) return usageError("dis needs exactly one file name: the flat image to disassemble");
        return cmdDisassemble(io, alloc, args[2]);
    }
    if (std.mem.eql(u8, command, "trace")) {
        if (args.len != 3) return usageError("trace needs exactly one file name: the source program to trace");
        return cmdTrace(io, alloc, args[2]);
    }

    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    w.print("error: \"{s}\" is not a Celeris-64 command. Expected one of: asm, run, run-bin, dis, trace or --help.", .{command}) catch {};
    printErr(w.buffered());
    return 2;
}

fn usageError(sentence: []const u8) u8 {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    w.print("error: {s}. Run \"celeris64 --help\" to see the command list.", .{sentence}) catch {};
    printErr(w.buffered());
    return 2;
}

fn printUsage(io: std.Io) void {
    printOut(io,
        \\celeris64 — Celeris-64 (CLS64) toolchain
        \\
        \\Usage:
        \\  celeris64 asm     <in.asm> <out.bin>   assemble source to a flat little-endian image
        \\  celeris64 run     <in.asm>             assemble a program, then execute it
        \\  celeris64 run-bin <in.bin>             load a flat image, then execute it
        \\  celeris64 dis     <in.bin>             disassemble a flat image
        \\  celeris64 trace   <in.asm>             execute a program and trace every step
        \\
        \\Exit codes: 0 success, 1 the input was rejected, 2 the command line was wrong.
        \\
        \\This is a software model of a processor that does not exist. Instruction
        \\counts printed by these tools are simulator counts, not silicon performance.
        \\
    );
}

// -- asm ----------------------------------------------------------------------

fn cmdAssemble(io: std.Io, alloc: std.mem.Allocator, in_path: []const u8, out_path: []const u8) u8 {
    const source = readFile(io, alloc, in_path) catch |e| return reportIoError("reading the source program", in_path, e);
    defer alloc.free(source);

    var assember = assembler.Assembler.init(alloc);
    defer assember.deinit();
    var d: Diagnostic = .{};
    const program = assember.assembleSource(in_path, source, &d) catch |e| switch (e) {
        error.OutOfMemory => return reportOutOfMemory(),
        error.AssemblyFailed => return reportDiagnostic(d),
    };

    // A flat little-endian image: each 64-bit word goes out least-significant
    // byte first (AGENTS.md §2.2).
    var image = std.ArrayList(u8).empty;
    defer image.deinit(alloc);
    image.ensureTotalCapacity(alloc, program.words.len * 8) catch return reportOutOfMemory();
    for (program.words) |word| {
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, word, .little);
        image.appendSlice(alloc, &b) catch return reportOutOfMemory();
    }

    writeFile(io, out_path, image.items) catch |e| return reportIoError("writing the assembled image", out_path, e);
    printFindings(&assember, in_path);
    printWarnings(program.warnings);

    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    w.print("assembled {d} instruction{s} into \"{s}\" ({d} bytes).\n", .{
        program.words.len,
        if (program.words.len == 1) "" else "s",
        out_path,
        image.items.len,
    }) catch {};
    printOut(io, w.buffered());
    return 0;
}

// -- run ----------------------------------------------------------------------

fn cmdRunSource(io: std.Io, alloc: std.mem.Allocator, path: []const u8) u8 {
    const source = readFile(io, alloc, path) catch |e| return reportIoError("reading the source program", path, e);
    defer alloc.free(source);

    var assember = assembler.Assembler.init(alloc);
    defer assember.deinit();
    var d: Diagnostic = .{};
    const program = assember.assembleSource(path, source, &d) catch |e| switch (e) {
        error.OutOfMemory => return reportOutOfMemory(),
        error.AssemblyFailed => return reportDiagnostic(d),
    };
    printFindings(&assember, path);
    printWarnings(program.warnings);
    return execute(io, alloc, program.words, path);
}

fn cmdRunImage(io: std.Io, alloc: std.mem.Allocator, path: []const u8) u8 {
    const bytes = readFile(io, alloc, path) catch |e| return reportIoError("reading the binary image", path, e);
    defer alloc.free(bytes);

    // A whole number of 64-bit words is required, because instruction width is
    // fixed (§1). A partial trailing word is truncation, not something to round.
    if (bytes.len % 8 != 0) {
        return reportDiagnostic(diagnostics.truncatedImage(path, bytes.len, bytes.len % 8));
    }

    const words = alloc.alloc(u64, bytes.len / 8) catch return reportOutOfMemory();
    defer alloc.free(words);
    for (words, 0..) |*word, i| {
        word.* = std.mem.readInt(u64, bytes[i * 8 ..][0..8], .little);
    }
    return execute(io, alloc, words, path);
}

/// Loads the words into a fresh VM image and runs them.
fn execute(io: std.Io, alloc: std.mem.Allocator, words: []const u64, origin: []const u8) u8 {
    const image = alloc.alloc(u8, image_bytes) catch return reportOutOfMemory();
    defer alloc.free(image);
    @memset(image, 0);

    if (words.len * 8 > image.len) {
        var d = diagnostics.truncatedImage(origin, words.len * 8, image.len);
        d.detail = "The program is larger than the memory image this build allocates.";
        return reportDiagnostic(d);
    }
    for (words, 0..) |word, i| {
        std.mem.writeInt(u64, image[i * 8 ..][0..8], word, .little);
    }

    var machine = vm_mod.Vm.init(image);

    // Stepped by hand rather than via `run`, because `run` returns a Diagnostic
    // for BOTH a clean halt and a fault: it cannot tell the caller which happened
    // except through the `Step` union. Treating every `halted` machine as success
    // made an unwired opcode print "halted" and exit 0, hiding a real fault.
    var steps: u64 = 0;
    while (steps < max_instructions) : (steps += 1) {
        const step = machine.step() catch |err| switch (err) {
            error.OutOfBounds => {
                const fault = machine.boundsText("executing a memory access", machine.regs.pc, 8);
                var buf: [512]u8 = undefined;
                var w = std.Io.Writer.fixed(&buf);
                w.print("error: while {s} the simulator refused an access at address {d}, which is outside the accessible region that starts at {d} and is {d} bytes long.", .{
                    fault.action, fault.address, fault.base, fault.length,
                }) catch {};
                printErr(w.buffered());
                return 1;
            },
            error.VmFault => {
                printErr("error: the simulator reported a fault while executing this program.");
                return 1;
            },
        };

        switch (step) {
            .advanced => {},
            .fault => |d| return reportDiagnostic(d),
            .halted => |d| {
                _ = d;
                var buf: [512]u8 = undefined;
                var w = std.Io.Writer.fixed(&buf);
                w.print("program \"{s}\" halted after {d} simulated instruction{s}. This is a simulator count, not a silicon cycle count.\n", .{
                    origin,
                    machine.retired,
                    if (machine.retired == 1) "" else "s",
                }) catch {};
                printOut(io, w.buffered());
                return 0;
            },
        }
    }

    // The step limit was reached without halting: say so, do not claim success.
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    w.print("error: the program \"{s}\" did not halt within {d} simulated instructions, so the simulator stopped it.\n", .{
        origin, max_instructions,
    }) catch {};
    printErr(w.buffered());
    return 1;
}

// -- dis ----------------------------------------------------------------------

fn cmdDisassemble(io: std.Io, alloc: std.mem.Allocator, path: []const u8) u8 {
    const bytes = readFile(io, alloc, path) catch |e| return reportIoError("reading the binary image", path, e);
    defer alloc.free(bytes);

    if (bytes.len % 8 != 0) {
        return reportDiagnostic(diagnostics.truncatedImage(path, bytes.len, bytes.len % 8));
    }

    var out = std.ArrayList(u8).empty;
    defer out.deinit(alloc);

    var i: usize = 0;
    var had_error = false;
    while (i < bytes.len) : (i += 8) {
        const word = std.mem.readInt(u64, bytes[i..][0..8], .little);

        // A diagnostic sentence is far longer than an instruction line. The
        // buffer used to be 256 bytes, which silently TRUNCATED the sentence
        // mid-clause; 2048 holds the longest rendering with room to spare.
        var buf: [2048]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        w.print("{d:0>6}:  ", .{i}) catch {};

        // An undecodable word must be reported AND must set the exit code. It
        // previously printed a sentence but still exited 0, which any script
        // would read as success.
        if (disassembler.decodeWord(word) == null) had_error = true;

        disassembler.disassemble(word, &w) catch {};
        w.writeAll("\n") catch {};

        const rendered = w.buffered();
        if (rendered.len == 0 or rendered[rendered.len - 1] != '\n') {
            // The writer dropped text: say so rather than print a line that
            // stops in the middle of a sentence.
            out.appendSlice(alloc, "error: a disassembled line did not fit the output buffer, so it was not printed in full.\n") catch return reportOutOfMemory();
            had_error = true;
            continue;
        }
        out.appendSlice(alloc, rendered) catch return reportOutOfMemory();
    }

    printOut(io, out.items);
    return if (had_error) 1 else 0;
}

// -- trace --------------------------------------------------------------------

fn cmdTrace(io: std.Io, alloc: std.mem.Allocator, path: []const u8) u8 {
    const source = readFile(io, alloc, path) catch |e| return reportIoError("reading the source program", path, e);
    defer alloc.free(source);

    var assember = assembler.Assembler.init(alloc);
    defer assember.deinit();
    var d: Diagnostic = .{};
    const program = assember.assembleSource(path, source, &d) catch |e| switch (e) {
        error.OutOfMemory => return reportOutOfMemory(),
        error.AssemblyFailed => return reportDiagnostic(d),
    };
    printFindings(&assember, path);
    printWarnings(program.warnings);

    const image = alloc.alloc(u8, image_bytes) catch return reportOutOfMemory();
    defer alloc.free(image);
    @memset(image, 0);
    for (program.words, 0..) |word, i| {
        if (i * 8 + 8 > image.len) break;
        std.mem.writeInt(u64, image[i * 8 ..][0..8], word, .little);
    }

    var machine = vm_mod.Vm.init(image);
    printOut(io, "Celeris-64 step trace (a software model, not silicon):\n");

    var steps: u64 = 0;
    while (steps < max_instructions) : (steps += 1) {
        const pc = machine.regs.pc;
        if (pc + 8 > image.len) {
            printErr("error: the program counter moved outside the loaded program, so the trace stopped.");
            return 1;
        }
        const word = std.mem.readInt(u64, image[@intCast(pc)..][0..8], .little);
        const before = regWords(machine.regs);
        const decoded = disassembler.decodeWord(word);

        const step = machine.step() catch |err| switch (err) {
            error.OutOfBounds => {
                printErr("error: the trace stopped because the simulator refused a memory access.");
                return 1;
            },
            error.VmFault => return 1,
        };

        switch (step) {
            .advanced => traceOut(io, pc, decoded, before, regWords(machine.regs)),
            .halted => |diag| {
                traceOut(io, pc, decoded, before, regWords(machine.regs));
                var buf: [256]u8 = undefined;
                var w = std.Io.Writer.fixed(&buf);
                w.print("  halted after {d} simulated instruction{s}. {s}\n", .{
                    machine.retired,
                    if (machine.retired == 1) "" else "s",
                    diag.detail orelse "",
                }) catch {};
                printOut(io, w.buffered());
                return 0;
            },
            .fault => |diag| return reportDiagnostic(diag),
        }
    }
    return 0;
}

/// All 16 registers in the §4 index order, for change detection in the trace.
fn regWords(regs: vm_mod.File) [16]u64 {
    var out: [16]u64 = undefined;
    for (&out, 0..) |*slot, i| slot.* = regs.read(@intCast(i));
    return out;
}

fn traceOut(io: std.Io, pc: u64, ins: ?disassembler.Instruction, before: [16]u64, after: [16]u64) void {
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    if (ins) |i| {
        disassembler.traceLine(i, pc, &before, &after, &w) catch {};
    } else {
        w.print("  {d:0>6}  (a word this decoder does not recognise)\n", .{pc}) catch {};
    }
    w.writeAll("\n") catch {};
    printOut(io, w.buffered());
}

// -- reporting ----------------------------------------------------------------

fn reportDiagnostic(d: Diagnostic) u8 {
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    d.render(&w) catch {};
    w.writeAll("\n") catch {};
    printErr(w.buffered());
    return 1;
}

fn printWarnings(warnings: []const Diagnostic) void {
    for (warnings) |d| {
        var buf: [1024]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        d.render(&w) catch {};
        w.writeAll("\n") catch {};
        printErr(w.buffered());
    }
}

/// Static-analysis findings from src/analyzer.zig. All three source-driven
/// subcommands call this, so `asm`, `run` and `trace` say the same thing about the
/// same program. Findings are warnings: they never change the exit code, exactly as
/// the register-spill warning does not (AGENTS.md §4.3).
fn printFindings(assember: *const assembler.Assembler, path: []const u8) void {
    const findings = assember.analyzeSource(path);
    printWarnings(findings.slice());
    if (findings.truncated) {
        printErr("warning: this program produced more findings than this tool reports in one run, so the list above is not complete.");
    }
}

fn reportIoError(action: []const u8, path: []const u8, err: anyerror) u8 {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    w.print("error: could not read or write \"{s}\" while {s}. The operating system reported: {s}.", .{
        path, action, @errorName(err),
    }) catch {};
    printErr(w.buffered());
    return 1;
}

fn reportOutOfMemory() u8 {
    printErr("error: the tool ran out of memory while processing this input. The input is larger than this build can hold.");
    return 1;
}

// -- I/O ----------------------------------------------------------------------
//
// Zig 0.17.1 moved file handles to std.Io and made every operation take an Io
// instance. `io` is threaded through as a parameter rather than reached for
// globally, so the CLI stays testable against std.testing.io.

fn readFile(io: std.Io, alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);
    return try reader.interface.allocRemaining(alloc, .limited(1 << 24));
}

fn writeFile(io: std.Io, path: []const u8, bytes: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var writer = file.writer(io, &buf);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

/// Success output goes to STDOUT, not stderr. `std.debug.print` writes to
/// stderr, which made `celeris64 dis prog.bin > prog.asm` produce an empty file
/// and broke the most common use of a disassembler.
fn printOut(io: std.Io, text: []const u8) void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    w.interface.writeAll(text) catch return;
    w.interface.flush() catch return;
}

fn printErr(text: []const u8) void {
    std.debug.print("{s}\n", .{text});
}

// -- tests --------------------------------------------------------------------

const testing = std.testing;

test "usage is returned for no arguments and for an unknown command" {
    const none = [_][:0]const u8{"celeris64"};
    try testing.expectEqual(@as(u8, 2), runCli(testing.io, &none, testing.allocator));

    const unknown = [_][:0]const u8{ "celeris64", "frobnicate" };
    try testing.expectEqual(@as(u8, 2), runCli(testing.io, &unknown, testing.allocator));
}

test "help exits successfully" {
    const help = [_][:0]const u8{ "celeris64", "--help" };
    try testing.expectEqual(@as(u8, 0), runCli(testing.io, &help, testing.allocator));
}

test "a missing file is reported as a sentence and exits 1" {
    const args = [_][:0]const u8{ "celeris64", "run", "no-such-file-anywhere.asm" };
    try testing.expectEqual(@as(u8, 1), runCli(testing.io, &args, testing.allocator));
}

test "wrong argument count is a usage error, not a crash" {
    const args = [_][:0]const u8{ "celeris64", "asm", "only-one-name.asm" };
    try testing.expectEqual(@as(u8, 2), runCli(testing.io, &args, testing.allocator));
}

test "the CLI reports a missing file as exit 1" {
    const args = [_][:0]const u8{ "celeris64", "run", "definitely-not-here.asm" };
    try testing.expectEqual(@as(u8, 1), runCli(testing.io, &args, testing.allocator));
}

test "dis reports an undecodable word on its exit code, not just in text" {
    // Regression: cmdDisassemble printed the diagnostic sentence and still
    // returned 0, so a script saw success on a binary the tool could not read.
    const path = "celeris64_dis_regression.bin";
    defer std.Io.Dir.cwd().deleteFile(testing.io, path) catch {};

    // 0x60 with a non-zero reserved field decodes to a diagnostic.
    var image: [8]u8 = undefined;
    std.mem.writeInt(u64, &image, (@as(u64, 0x60) << 56) | (@as(u64, 0xFF) << 32), .little);
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = &image });

    const args = [_][:0]const u8{ "celeris64", "dis", path };
    try testing.expectEqual(@as(u8, 1), runCli(testing.io, &args, testing.allocator));
}
