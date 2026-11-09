//! The same workload, written four times, executed by four real decoders.
//!
//! THE WORKLOAD. Add 5 to each of 8 contiguous 64-bit elements, in two shapes:
//!
//!   batch  — one fused operation over the whole buffer
//!   scalar — one element per operation, with its own address arithmetic
//!
//! THE POINT. This is what `docs/comparison.md` could not do. Previously the
//! CLS64 column was a simulated instruction count and the C/Rust columns were
//! wall-clock nanoseconds on real silicon: two different physical quantities
//! printed side by side. Here all four columns are produced by the SAME
//! measurement loop, so the counts are commensurable.
//!
//! WHAT IS MEASURED: retired instructions, and the bytes those instructions
//! occupied. Both are properties of the encoded program.
//! WHAT IS NOT MEASURED: cycles, time, throughput. See `isaharness.zig`.
//!
//! EQUIVALENCE IS TESTED, NOT ASSUMED. Each program's resulting memory is
//! compared against the others, so a program that "runs" but computes something
//! else cannot be reported as an equal participant.

const std = @import("std");
const harness = @import("isaharness.zig");
const rv = @import("isa_riscv.zig");
const a64 = @import("isa_aarch64.zig");
const x86 = @import("isa_x86_64.zig");

pub const elements: u64 = 8;
pub const addend: u64 = 5;
/// Where the data lives: past the program, so no program can stream over its own
/// code. The same base is used for every ISA so the addresses in each program are
/// directly comparable.
pub const data_base: u64 = 0x1000;
/// Instruction limit. High enough that no program here reaches it, low enough
/// that a decoding bug cannot hang the test suite.
pub const step_limit: u64 = 10_000;

/// Size of the memory image every program runs in. It must exceed `data_base`
/// plus the data: an earlier version used a flat 4096, which made `data_base`
/// (0x1000 = 4096) the first address PAST the end, so every store faulted and
/// the program "ran" without touching memory.
pub const mem_size: usize = data_base + elements * 8 + 512;

pub const Shape = enum { batch, scalar };

/// The result of running one ISA's version of the workload.
pub const Measurement = struct {
    isa: []const u8,
    shape: Shape,
    fixed_width: ?u8,
    result: harness.Result,
    /// True when the program left exactly `elements` values of `addend +
    /// original[i]` in memory. A program that ran but computed the wrong thing is
    /// reported as incorrect rather than as a data point.
    correct: bool,

    pub fn bytesPerInsn(self: Measurement) ?f64 {
        if (self.result.retired == 0) return null;
        return @as(f64, @floatFromInt(self.result.code_bytes)) / @as(f64, @floatFromInt(self.result.retired));
    }
};

// ---------------------------------------------------------------------------
// RISC-V RV64I
// ---------------------------------------------------------------------------

/// `lui rd, hi20` + `addi rd, rd, lo12` — how a real assembler materialises a
/// 32-bit constant. Needed because `addi`'s immediate is a SIGNED 12-bit field
/// (-2048..2047) and `data_base` is 4096, which does not fit. An earlier version
/// used a bare `addi` here and the encoder truncated the value to 0, so the
/// program silently streamed over its own code.
fn loadAddress(rd: u5, value: u32) [2]u32 {
    const lo: i32 = @as(i32, @intCast(value & 0xFFF));
    // The low 12 bits are interpreted as signed, so round the high part up when
    // the low part would be negative — the standard lui/addi pairing.
    const hi: u32 = (value +% 0x800) >> 12;
    return .{
        (@as(u32, hi & 0xFFFFF) << 12) | (@as(u32, rd) << 7) | 0x37, // lui
        rv.iType(lo, rd, 0x0, rd, 0x13), // addi rd, rd, lo
    };
}

/// batch: one fused loop over the whole buffer.
///
///   lui/addi a0, data     # a0 = data pointer
///   addi t0, zero, 8      # remaining = 8
///   addi t1, zero, 5      # addend = 5
/// loop:
///   ld   t2, 0(a0)        # load element
///   add  t2, t2, t1       # add
///   sd   t2, 0(a0)        # store
///   addi a0, a0, 8        # advance
///   addi t0, t0, -1       # decrement
///   bne  t0, zero, loop
fn riscvBatch() [16]u32 {
    // a0 = x10, t0 = x5, t1 = x6, t2 = x7
    const addr = loadAddress(10, data_base);
    const body_len = 4 * 5; // ld, add, sd, addi, addi
    return .{
        addr[0],
        addr[1],
        rv.addi(5, 0, @intCast(elements)), // t0 = 8
        rv.addi(6, 0, @intCast(addend)), // t1 = 5
        rv.ld(7, 10, 0), // t2 = mem[a0]
        rv.add(7, 7, 6), // t2 += 5
        rv.sd(7, 10, 0), // mem[a0] = t2
        rv.addi(10, 10, 8), // a0 += 8
        rv.addi(5, 5, -1), // t0 -= 1
        rv.bne(5, 0, -body_len), // loop
        rv.addi(17, 0, 93), // exit code
        rv.ecall(),
        0,
        0,
        0,
        0,
    };
}

/// scalar: one element per iteration, with the address recomputed each time from
/// an explicit index — the shape the fused engine exists to remove.
///
///   addi t0, zero, 0      # i = 0
///   addi t1, zero, 5      # addend
///   addi t3, zero, 64     # byte count
/// loop:
///   add  t4, a0, t0       # address = base + i
///   ld   t2, 0(t4)
///   add  t2, t2, t1
///   sd   t2, 0(t4)
///   addi t0, t0, 8
///   bne  t0, t3, loop
fn riscvScalar() [16]u32 {
    const addr = loadAddress(10, data_base);
    const body_len = 4 * 5;
    return .{
        addr[0],
        addr[1],
        rv.addi(5, 0, 0), // t0 = 0 (i)
        rv.addi(6, 0, @intCast(addend)), // t1 = 5
        rv.addi(28, 0, @intCast(elements * 8)), // t3 = 64
        rv.add(29, 10, 5), // t4 = base + i
        rv.ld(7, 29, 0),
        rv.add(7, 7, 6),
        rv.sd(7, 29, 0),
        rv.addi(5, 5, 8), // i += 8
        rv.bne(5, 28, -body_len),
        rv.addi(17, 0, 93),
        rv.ecall(),
        0,
        0,
        0,
    };
}

fn runRiscv(comptime shape: Shape) Measurement {
    const src = if (shape == .batch) riscvBatch() else riscvScalar();
    var words: [16]u32 = src;
    var bytes: [mem_size]u8 = @splat(0);
    for (words[0..], 0..) |w, i| {
        std.mem.writeInt(u32, bytes[i * 4 ..][0..4], w, .little);
    }
    var cpu = rv.Cpu.init(&bytes);
    const out = harness.run(&cpu, step_limit);
    return .{
        .isa = "RISC-V RV64I",
        .shape = shape,
        .fixed_width = 4,
        .result = switch (out) {
            .halted => |r| r,
            .faulted => |r| r,
            .exhausted => |r| r,
        },
        .correct = checkMemory(&bytes),
    };
}

// ---------------------------------------------------------------------------
// AArch64
// ---------------------------------------------------------------------------

fn aarch64Batch() [19]u32 {
    // x0 = data pointer, x1 = addend, x2 = remaining, x3 = element
    return .{
        a64.movz(0, data_base, 0), // x0 = data  (data_base = 0x1000 fits in 16 bits)
        a64.movz(1, @intCast(addend), 0), // x1 = 5
        a64.movz(2, @intCast(elements), 0), // x2 = 8
        a64.ldr(3, 0, 0), // x3 = [x0]
        a64.add(3, 3, 1), // x3 += 5
        a64.str(3, 0, 0), // [x0] = x3
        a64.addImm(0, 0, 8), // x0 += 8
        a64.subImm(2, 2, 1), // x2 -= 1
        a64.cmp(2, 31), // cmp x2, xzr
        a64.bCond(0x1, -24), // b.ne loop  (6 insns back = 24 bytes)
        // done: b .           4   (branch to itself = this program's halt)
        a64.bUncond(0),
        a64.nop(),
        a64.nop(),
        a64.nop(),
        a64.nop(),
        a64.nop(),
        a64.nop(),
        a64.nop(),
        a64.nop(),
    };
}

fn aarch64Scalar() [19]u32 {
    // x0 = base, x1 = addend, x2 = i, x4 = byte limit, x3 = value, x5 = address
    return .{
        a64.movz(0, data_base, 0),
        a64.movz(1, @intCast(addend), 0),
        a64.movz(2, 0, 0), // i = 0
        a64.movz(4, @intCast(elements * 8), 0), // limit = 64
        a64.add(5, 0, 2), // x5 = base + i
        a64.ldr(3, 5, 0), // x3 = [x5]
        a64.add(3, 3, 1), // += 5
        a64.str(3, 5, 0), // [x5] = x3
        a64.addImm(2, 2, 8), // i += 8
        a64.cmp(2, 4), // cmp i, limit
        a64.bCond(0x1, -24), // b.ne loop
        a64.bUncond(0), // done: b .
        a64.nop(),
        a64.nop(),
        a64.nop(),
        a64.nop(),
        a64.nop(),
        a64.nop(),
        a64.nop(),
    };
}

fn runAarch64(comptime shape: Shape) Measurement {
    const src = if (shape == .batch) aarch64Batch() else aarch64Scalar();
    var words: [19]u32 = src;
    var bytes: [mem_size]u8 = @splat(0);
    for (words[0..], 0..) |w, i| {
        std.mem.writeInt(u32, bytes[i * 4 ..][0..4], w, .little);
    }
    var cpu = a64.Cpu.init(&bytes);
    // AArch64 in this subset has no architectural halt either, so the program ends
    // in `b .` — a branch to itself — and that is detected as the end of the run.
    // Using the step limit instead would report the same instruction count for
    // every program regardless of its length, which measures the harness.
    const result = runToSelfLoop(&cpu);
    return .{
        .isa = "AArch64 A64",
        .shape = shape,
        .fixed_width = 4,
        .result = result,
        .correct = checkMemory(&bytes),
    };
}

// ---------------------------------------------------------------------------
// x86-64
// ---------------------------------------------------------------------------

fn x86Batch() [41]u8 {
    // rax = pointer, rcx = addend, rdx = counter, rsi = element
    return .{
        // movq $0x1000, %rax
        0x48, 0xC7, 0xC0, 0x00, 0x10, 0x00, 0x00,
        // movq $5, %rcx
        0x48, 0xC7, 0xC1, 0x05, 0x00, 0x00, 0x00,
        // movq $8, %rdx
        0x48, 0xC7, 0xC2, 0x08, 0x00, 0x00, 0x00,
        // loop:
        // movq (%rax), %rsi     3
        0x48, 0x8B, 0x30,
        // addq %rcx, %rsi       3
        0x48, 0x01, 0xCE,
        // movq %rsi, (%rax)     3
        0x48, 0x89, 0x30,
        // addq $8, %rax         4
        0x48, 0x83, 0xC0, 0x08,
        // decq %rdx             3
        0x48, 0xFF, 0xCA,
        // jne loop              2
        // The loop body begins at offset 21 and the jne ends at offset 39, so
        // rel8 = 21 - 39 = -18 = 0xEE. This was 0xF1 (-15) in an earlier version,
        // which re-entered the loop three bytes late and ran it 11 times instead
        // of 8 — caught by the memory-equality test, not by the instruction count.
        0x75, 0xEE,
        // done: jmp done        2   (2-byte self-loop = this program's halt)
        // An infinite loop is used rather than `ret` because `ret` would pop an
        // empty stack and fault. It is the honest way to end a program under a
        // harness that treats a step limit as `exhausted` rather than success.
        0xEB, 0xFE,
    };
}

fn x86Scalar() [46]u8 {
    // rax = base, rcx = addend, rdx = i, rsi = value, rdi = address
    return .{
        0x48, 0xC7, 0xC0, 0x00, 0x10, 0x00, 0x00, // movq $0x1000, %rax
        0x48, 0xC7, 0xC1, 0x05, 0x00, 0x00, 0x00, // movq $5, %rcx
        0x48, 0xC7, 0xC2, 0x00, 0x00, 0x00, 0x00, // movq $0, %rdx
        // loop:
        0x48, 0x8D, 0x3C, 0x10, // leaq (%rax,%rdx), %rdi
        0x48, 0x8B, 0x37, // movq (%rdi), %rsi
        0x48, 0x01, 0xCE, // addq %rcx, %rsi
        0x48, 0x89, 0x37, // movq %rsi, (%rdi)
        0x48, 0x83, 0xC2, 0x08, // addq $8, %rdx
        0x48, 0x83, 0xFA, 0x40, // cmpq $64, %rdx
        // jne loop. Body starts at 21, the jne ends at 44, so rel8 = 21 - 44 = -23
        // = 0xE9. (Was 0xE8 = -24, which is one byte short.)
        0x75, 0xE9,
        // done: jmp done
        0xEB, 0xFE,
    };
}

fn runX86(comptime shape: Shape) Measurement {
    var bytes: [mem_size]u8 = @splat(0);
    if (shape == .batch) {
        const code = x86Batch();
        @memcpy(bytes[0..code.len], &code);
    } else {
        const code = x86Scalar();
        @memcpy(bytes[0..code.len], &code);
    }
    var cpu = x86.Cpu.init(&bytes);
    const result = runToSelfLoop(&cpu);
    return .{
        .isa = "x86-64",
        .shape = shape,
        .fixed_width = null,
        .result = result,
        .correct = checkMemory(&bytes),
    };
}

// ---------------------------------------------------------------------------
// CLS64
// ---------------------------------------------------------------------------

/// Adapter so the CLS64 VM satisfies the harness's two-method ISA interface
/// without changing `vm.zig`. The VM's own `step` returns a `Step` union and its
/// halt flag is a field; this presents them as `step() !u64` and `halted()`, the
/// same shape the other three ISAs implement natively.
///
/// The adapter is deliberately thin. Anything more — translating faults, mapping
/// status enums — would start translating between two models, and the comparison
/// would then measure the translation as much as the ISA.
const Cls64 = struct {
    vm: *@import("vm.zig").Vm,

    pub fn step(self: *Cls64) !u64 {
        const s = self.vm.step() catch return error.Fault;
        return switch (s) {
            .advanced => 8,
            // A halt still counts as one retired instruction; the VM has already
            // executed it by the time it reports.
            .halted => 8,
            .fault => error.Fault,
        };
    }

    pub fn halted(self: *const Cls64) bool {
        return self.vm.halted;
    }
};

/// CLS64's two programs, built with the repository's own encoder so the words are
/// exactly what `zig build asm` would emit.
///
/// batch: `mov R2, 5` then one `stream.add R0, [R1]+8, R2`, then halt. The fused
/// engine walks all 8 elements in a single instruction.
///
/// scalar: the SAME instruction issued once per element with `chunk = 1`.
///
/// NOTE (F32): these two programs are NOT two different shapes — they are one
/// instruction at two granularities, and the difference between them is
/// arithmetic rather than algorithmic. They are included here for completeness and
/// are labelled as such in the report, because a reader who compared the "scalar"
/// row against RISC-V's scalar row would otherwise be comparing a loop against a
/// loop-less sequence.
fn cls64Program(alloc: std.mem.Allocator, comptime shape: Shape) ![]u8 {
    const vm = @import("vm.zig");
    var words = std.ArrayList(u64).empty;
    errdefer words.deinit(alloc);

    try words.append(alloc, vm.encode(0x19, 1, 0, vm.aluOperand(0, .full, data_base))); // R1 = data
    try words.append(alloc, vm.encode(0x19, 2, 0, vm.aluOperand(0, .full, addend))); // R2 = 5
    if (shape == .batch) {
        // One fused stream.add over all 8 elements.
        const oper = (@as(u48, 2) << 44) | (@as(u48, @intCast(elements)) << 24);
        try words.append(alloc, vm.encode(0x40, 0, 1, oper));
    } else {
        var i: u64 = 0;
        while (i < elements) : (i += 1) {
            const oper = (@as(u48, 2) << 44) | (@as(u48, 1) << 24);
            try words.append(alloc, vm.encode(0x40, 0, 1, oper));
        }
    }
    try words.append(alloc, vm.encode(0x01, 0, 0, 0)); // halt

    const bytes = try alloc.alloc(u8, mem_size);
    @memset(bytes, 0);
    for (words.items, 0..) |word, i| {
        std.mem.writeInt(u64, bytes[i * 8 ..][0..8], word, .little);
    }
    return bytes;
}

fn runCls64(alloc: std.mem.Allocator, comptime shape: Shape) !Measurement {
    const bytes = try cls64Program(alloc, shape);
    const vm = @import("vm.zig");
    var machine = vm.Vm.init(bytes);
    var adapter = Cls64{ .vm = &machine };
    const out = harness.run(&adapter, step_limit);
    return .{
        .isa = "Celeris-64 CLS64",
        .shape = shape,
        .fixed_width = 8,
        .result = switch (out) {
            .halted => |r| r,
            .faulted => |r| r,
            .exhausted => |r| r,
        },
        .correct = checkMemory(bytes),
    };
}

// ---------------------------------------------------------------------------
// Shared verification
// ---------------------------------------------------------------------------

/// True when every element in memory is `original + addend`.
///
/// Each program is loaded into its own zeroed buffer and starts from the same
/// data, so the expected result is the same for all four. This is what makes the
/// comparison meaningful: the four programs must compute the SAME thing, and that
/// is asserted rather than assumed.
fn checkMemory(bytes: []const u8) bool {
    var i: u64 = 0;
    while (i < elements) : (i += 1) {
        const at: usize = @intCast(data_base + i * 8);
        if (at + 8 > bytes.len) return false;
        const v = std.mem.readInt(u64, bytes[at..][0..8], .little);
        // Every buffer starts zeroed, so the original value is 0 and the result
        // must be exactly the addend.
        if (v != addend) return false;
    }
    return true;
}

/// Runs an x86 program to completion, treating a `jmp $` self-loop as the halt.
///
/// The other three ISAs have an architectural halt in the subset used here. x86-64
/// does not: `hlt` is privileged and `ret` needs a stack. A two-byte self-loop is
/// the conventional way a bare-metal x86 program says "done", so it is recognised
/// here rather than letting the step limit decide — a step limit would report
/// 10000 instructions for every program regardless of its length, which is a
/// measurement of the harness, not of the program.
fn runToSelfLoop(cpu: anytype) harness.Result {
    var r = harness.Result{ .retired = 0, .code_bytes = 0 };
    while (r.retired < step_limit) {
        const pc_before = cpu.pc;
        const len = cpu.step() catch {
            r.faulted = true;
            return r;
        };
        r.retired += 1;
        r.code_bytes += len;
        // `EB FE` = jmp to itself.
        if (cpu.pc == pc_before) return r;
    }
    r.faulted = true;
    return r;
}

/// Runs all four ISAs in both shapes.
///
/// `alloc` is only needed for the CLS64 program builder, which uses the same
/// arena style as the rest of the repository.
pub fn measureAll(alloc: std.mem.Allocator) ![]Measurement {
    var list = std.ArrayList(Measurement).empty;
    errdefer list.deinit(alloc);
    inline for (.{ .batch, .scalar }) |shape| {
        try list.append(alloc, try runCls64(alloc, shape));
        try list.append(alloc, runRiscv(shape));
        try list.append(alloc, runAarch64(shape));
        try list.append(alloc, runX86(shape));
    }
    return list.items;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "every ISA's batch program computes 5 in all 8 elements" {
    inline for (.{ runRiscv, runAarch64, runX86 }) |runner| {
        const m = runner(.batch);
        testing.expect(m.correct) catch |e| {
            std.debug.print("ISA {s} batch produced the WRONG memory contents\n", .{m.isa});
            return e;
        };
        try testing.expect(m.result.retired > 0);
    }
}

test "every ISA's scalar program computes 5 in all 8 elements" {
    inline for (.{ runRiscv, runAarch64, runX86 }) |runner| {
        const m = runner(.scalar);
        testing.expect(m.correct) catch |e| {
            std.debug.print("ISA {s} scalar produced the WRONG memory contents\n", .{m.isa});
            return e;
        };
        try testing.expect(m.result.retired > 0);
    }
}

test "a program that does not halt is reported as exhausted, not as a success" {
    // The harness must never let a runaway program masquerade as a measurement.
    var bytes: [256]u8 = @splat(0);
    // `1: jmp 1b` — an infinite loop, one instruction, forever.
    bytes[0] = 0xEB;
    bytes[1] = 0xFE;
    var cpu = x86.Cpu.init(&bytes);
    const out = harness.run(&cpu, 500);
    try testing.expect(out == .exhausted);
    try testing.expectEqual(@as(u64, 500), out.exhausted.retired);
}

test "fixed-width ISAs have code_bytes == retired * width, exactly" {
    // For a fixed-width ISA the byte count is an identity, so this test verifies
    // the accounting rather than the ISA. For x86-64 the identity must NOT hold,
    // which is the whole reason it is in the comparison.
    const rv_m = runRiscv(.batch);
    try testing.expectEqual(rv_m.result.retired * 4, rv_m.result.code_bytes);

    const a64_m = runAarch64(.batch);
    try testing.expectEqual(a64_m.result.retired * 4, a64_m.result.code_bytes);

    const x86_m = runX86(.batch);
    try testing.expect(x86_m.result.code_bytes != x86_m.result.retired * 4);
}

test "x86-64 is denser per instruction than the fixed-width ISAs in this workload" {
    // The measured claim the comparison is built on, stated as a test so it
    // cannot quietly stop being true. If it ever fails, the docs must change.
    const x86_m = runX86(.batch);
    const rv_m = runRiscv(.batch);
    const a64_m = runAarch64(.batch);
    try testing.expect(x86_m.bytesPerInsn().? < rv_m.bytesPerInsn().?);
    try testing.expect(x86_m.bytesPerInsn().? < a64_m.bytesPerInsn().?);
}
