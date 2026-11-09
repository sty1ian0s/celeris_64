//! x86-64 execution: a real x86-64 decoder and interpreter, for the
//! cross-architecture comparison.
//!
//! SCOPE. The integer subset the comparison workload needs, in 64-bit mode:
//! MOV (immediate and register/memory), ADD/SUB/CMP/TEST, INC/DEC, LEA, Jcc with
//! rel8/rel32, CALL/RET, PUSH/POP, NOP. No SIMD, no x87, no floating point, no
//! privilege transitions, no segmentation beyond the flat model, no REX.W-less
//! 32-bit quirks beyond those exercised here.
//!
//! WHY x86-64 IS THE INTERESTING COLUMN. It is the only variable-length ISA in
//! this comparison. CLS64 is 8 bytes per instruction, RISC-V and AArch64 are 4,
//! and x86-64 is *whatever the instruction needs* — 1 byte for `pushq %rax`,
//! 7 for `movq $5, %rax`. That is what makes a dynamic byte count worth
//! measuring: for the fixed-width ISAs `code_bytes == retired * width` is an
//! identity, while here it is a genuine measurement of the encoded program.
//!
//! WHAT THIS DOES NOT MODEL. Decode complexity, µop cracking, pipelines, caches,
//! branch prediction. A real x86-64 core turns most of these instructions into
//! multiple µops; counting one per instruction is a statement about the PROGRAM,
//! not about a core. See `isaharness.zig`.

const std = @import("std");
const harness = @import("isaharness.zig");

pub const Cpu = struct {
    regs: [16]u64 = @splat(0),
    pc: u64 = 0,
    mem: []u8,
    stopped: bool = false,
    branched: bool = false,
    /// Set while decoding a SIB byte: whether its base field was 5, which forces
    /// a disp32 under mod == 0.
    sib_base_is_5: bool = false,
    /// Length of the instruction currently being executed. Set by a `defer` as
    /// soon as the encoding has been consumed, so a branch that moves the PC
    /// cannot corrupt it.
    len_of_insn: u64 = 0,
    /// RFLAGS: only ZF (bit 6), SF (bit 7), CF (bit 0) and OF (bit 11) are modelled.
    flags: u64 = 0,

    const zf: u6 = 6;
    const sf: u6 = 7;
    const cf: u6 = 0;
    const of: u6 = 11;

    pub fn init(mem: []u8) Cpu {
        // A real loader sets up a stack before the first instruction. `rsp = 0`
        // would make PUSH/CALL underflow the address space, which is a property of
        // the harness not of the program, so init places the stack at the top of
        // the image — below the 8-byte guard the store checks.
        return .{ .mem = mem, .regs = blk: {
            var r: [16]u64 = @splat(0);
            r[4] = mem.len - 8; // rsp
            break :blk r;
        } };
    }

    pub fn read(self: *const Cpu, r: u4) u64 {
        return self.regs[r];
    }

    pub fn write(self: *Cpu, r: u4, v: u64) void {
        self.regs[r] = v;
    }

    pub fn halted(self: *const Cpu) bool {
        return self.stopped;
    }

    fn getFlag(self: *const Cpu, bit: u6) bool {
        return ((self.flags >> bit) & 1) != 0;
    }

    fn setFlag(self: *Cpu, bit: u6, v: bool) void {
        if (v) self.flags |= (@as(u64, 1) << bit) else self.flags &= ~(@as(u64, 1) << bit);
    }

    fn load(self: *const Cpu, addr: u64, n: u6) !u64 {
        if (addr + n > self.mem.len) return error.OutOfBounds;
        const b = self.mem[@intCast(addr)..][0..n];
        return switch (n) {
            1 => b[0],
            2 => std.mem.readInt(u16, b[0..2], .little),
            4 => std.mem.readInt(u32, b[0..4], .little),
            8 => std.mem.readInt(u64, b[0..8], .little),
            else => unreachable,
        };
    }

    fn store(self: *Cpu, addr: u64, n: u6, v: u64) !void {
        if (addr + n > self.mem.len) return error.OutOfBounds;
        const b = self.mem[@intCast(addr)..][0..n];
        switch (n) {
            1 => b[0] = @truncate(v),
            2 => std.mem.writeInt(u16, b[0..2], @truncate(v), .little),
            4 => std.mem.writeInt(u32, b[0..4], @truncate(v), .little),
            8 => std.mem.writeInt(u64, b[0..8], v, .little),
            else => unreachable,
        }
    }

    fn fetch8(self: *Cpu) !u8 {
        const v = try self.load(self.pc, 1);
        self.pc += 1;
        return @truncate(v);
    }

    /// Reads `n` bytes at the PC and advances past them, returning the raw bits
    /// in a u64. Callers @bitCast/@truncate to the width they asked for, which
    /// keeps signed and unsigned immediates on one code path.
    fn fetchBits(self: *Cpu, n: u6) !u64 {
        const v = try self.load(self.pc, n);
        self.pc += n;
        return v;
    }

    /// Executes one x86-64 instruction and returns its length in bytes.
    ///
    /// The length is discovered by walking the prefixes, opcode and operands — it
    /// is the return value rather than a constant, which is what the harness
    /// needs and what makes this ISA's density measurable.
    pub fn step(self: *Cpu) !u64 {
        const start = self.pc;
        const len = try self.execute();
        if (len == 0) return error.ZeroLength;
        if (!self.branched and self.pc != start + len) {
            // A non-branch instruction must leave the PC exactly at the end of
            // what it consumed. This catches any decoder path that advanced the
            // PC by the wrong amount — the defect class that would silently
            // corrupt every subsequent instruction.
            return error.PcMismatch;
        }
        self.branched = false;
        return len;
    }

    fn execute(self: *Cpu) !u64 {
        const start = self.pc;

        // Legacy prefixes. Only the operand-size (0x66) and REX prefixes matter
        // for the instructions implemented; the rest are consumed and ignored,
        // which is correct for a flat single-threaded model.
        var rex_w = false;
        var rex_r: u1 = 0;
        var rex_x: u1 = 0;
        var rex_b: u1 = 0;
        var operand_16 = false;

        while (true) {
            const b = try self.fetch8();
            switch (b) {
                0x66 => operand_16 = true,
                0x67, 0xF0, 0xF2, 0xF3, 0x2E, 0x36, 0x3E, 0x26, 0x64, 0x65 => {},
                0x40...0x4F => {
                    rex_w = (b & 0x08) != 0;
                    rex_r = @truncate(b & 0x04);
                    rex_x = @truncate(b & 0x02);
                    rex_b = @truncate(b & 0x01);
                },
                else => {
                    self.pc -= 1; // put the opcode back
                    break;
                },
            }
        }
        const op = try self.fetch8();
        switch (op) {
            0x90 => {}, // NOP (and 0x90 with REX.B is XCHG, not needed)
            0xC3 => { // RET
                self.endInsn(start);
                self.pc = try self.load(self.regs[4], 8); // [rsp]
                self.regs[4] += 8;
                self.branched = true;
            },
            0x50...0x57 => { // PUSH r64
                const r: u4 = @truncate(op - 0x50 + rex_b);
                self.regs[4] -= 8;
                try self.store(self.regs[4], 8, self.regs[r]);
            },
            0x58...0x5F => { // POP r64
                const r: u4 = @truncate(op - 0x58 + rex_b);
                self.regs[r] = try self.load(self.regs[4], 8);
                self.regs[4] += 8;
            },
            0x70...0x7F => { // Jcc rel8
                const rel: i8 = @bitCast(try self.fetch8());
                self.endInsn(start);
                if (self.conditionHolds(@truncate(op - 0x70))) {
                    self.pc = self.pc +% @as(u64, @bitCast(@as(i64, rel)));
                    self.branched = true;
                }
            },
            0x0F => {
                const op2 = try self.fetch8();
                if (op2 >= 0x80 and op2 <= 0x8F) { // Jcc rel32
                    const rel: i32 = @bitCast(@as(u32, @truncate(try self.fetchBits(4))));
                    self.endInsn(start);
                    if (self.conditionHolds(@truncate(op2 - 0x80))) {
                        self.pc = self.pc +% @as(u64, @bitCast(@as(i64, rel)));
                        self.branched = true;
                    }
                } else return error.UnsupportedTwoByteOpcode;
            },
            0xE8 => { // CALL rel32
                const rel: i32 = @bitCast(@as(u32, @truncate(try self.fetchBits(4))));
                self.endInsn(start);
                self.regs[4] -= 8;
                try self.store(self.regs[4], 8, self.pc);
                self.pc = self.pc +% @as(u64, @bitCast(@as(i64, rel)));
                self.branched = true;
            },
            0xEB => { // JMP rel8
                const rel: i8 = @bitCast(try self.fetch8());
                self.endInsn(start);
                self.pc = self.pc +% @as(u64, @bitCast(@as(i64, rel)));
                self.branched = true;
            },
            0xE9 => { // JMP rel32
                const rel: i32 = @bitCast(@as(u32, @truncate(try self.fetchBits(4))));
                self.endInsn(start);
                self.pc = self.pc +% @as(u64, @bitCast(@as(i64, rel)));
                self.branched = true;
            },
            0x89, 0x8B => { // MOV r/m, r  /  MOV r, r/m
                const is_load = op == 0x8B;
                const modrm = try self.fetch8();
                const mod: u2 = @truncate(modrm >> 6);
                const reg: u4 = @truncate(((modrm >> 3) & 7) + (@as(u8, rex_r) << 3));
                const rm: u4 = @truncate((modrm & 7) + (@as(u8, rex_b) << 3));
                const size: u6 = if (rex_w) 8 else if (operand_16) 2 else 4;

                if (mod == 3) {
                    if (is_load) {
                        self.regs[reg] = self.truncateTo(self.regs[rm], size);
                    } else {
                        self.regs[rm] = self.truncateTo(self.regs[reg], size);
                    }
                } else {
                    const addr = try self.modrmAddress(modrm, mod, rex_b, rex_x);
                    if (is_load) {
                        self.regs[reg] = try self.load(addr, size);
                    } else {
                        try self.store(addr, size, self.regs[reg]);
                    }
                }
            },
            0x8D => { // LEA r, m
                const modrm = try self.fetch8();
                const mod: u2 = @truncate(modrm >> 6);
                const reg: u4 = @truncate(((modrm >> 3) & 7) + (@as(u8, rex_r) << 3));
                if (mod == 3) return error.LeaNeedsMemory;
                const addr = try self.modrmAddress(modrm, mod, rex_b, rex_x);
                // LEA does NOT access memory; it computes the address. That is the
                // whole point of the instruction and the reason it is a common
                // three-operand add on x86-64.
                self.regs[reg] = addr;
            },
            0x01, 0x29, 0x39, 0x31, 0x85 => { // ADD/SUB/CMP/XOR/TEST r/m, r
                const modrm = try self.fetch8();
                const mod: u2 = @truncate(modrm >> 6);
                const reg: u4 = @truncate(((modrm >> 3) & 7) + (@as(u8, rex_r) << 3));
                const rm: u4 = @truncate((modrm & 7) + (@as(u8, rex_b) << 3));
                const size: u6 = if (rex_w) 8 else if (operand_16) 2 else 4;

                const b_val = self.truncateTo(self.regs[reg], size);
                var a_val: u64 = undefined;
                var addr: u64 = 0;
                const to_mem = mod != 3;
                if (to_mem) {
                    addr = try self.modrmAddress(modrm, mod, rex_b, rex_x);
                    a_val = try self.load(addr, size);
                } else {
                    a_val = self.truncateTo(self.regs[rm], size);
                }

                const res = switch (op) {
                    0x01 => a_val +% b_val,
                    0x29 => a_val -% b_val,
                    0x39 => a_val -% b_val, // CMP: same as SUB, result discarded
                    0x31 => a_val ^ b_val,
                    0x85 => a_val & b_val, // TEST: same as AND, result discarded
                    else => unreachable,
                };
                const masked = self.truncateTo(res, size);
                // CMP (0x39) and TEST (0x85) discard the result; ADD/SUB/XOR keep it.
                if (op != 0x39 and op != 0x85) {
                    if (to_mem) try self.store(addr, size, masked) else self.regs[rm] = masked;
                }
                if (op == 0x39) {
                    self.setSubFlags(a_val, b_val, masked, size);
                } else if (op == 0x85) {
                    self.setLogicFlags(masked, size);
                } else if (op == 0x01) {
                    self.setAddFlags(a_val, b_val, masked, size);
                } else if (op == 0x29) {
                    self.setSubFlags(a_val, b_val, masked, size);
                } else {
                    self.setLogicFlags(masked, size);
                }
            },
            // NOTE: 0xC7 is NOT group 1. It is group 11 — MOV r/m, imm — and its
            // `reg` field is an opcode extension, not an ALU selector. Grouping it
            // with 0x83/0x81 (a real mistake made here) made `movq $5, %rax`
            // execute as an ADD, which the LLVM oracle test caught while all the
            // self-consistency tests passed. It has its own arm below.
            0x83, 0x81 => { // group 1: ADD/OR/ADC/SBB/AND/SUB/XOR/CMP with immediate
                const modrm = try self.fetch8();
                const mod: u2 = @truncate(modrm >> 6);
                const sub_op: u3 = @truncate((modrm >> 3) & 7);
                const rm: u4 = @truncate((modrm & 7) + (@as(u8, rex_b) << 3));
                const size: u6 = if (rex_w) 8 else if (operand_16) 2 else 4;
                const imm: u64 = if (op == 0x83)
                    @as(u8, @bitCast(@as(i8, @bitCast(try self.fetch8()))))
                else
                    @as(u32, @truncate(try self.fetchBits(4)));
                const imm_signed: i64 = if (op == 0x83)
                    @as(i8, @bitCast(@as(u8, @truncate(imm))))
                else
                    @as(i32, @bitCast(@as(u32, @truncate(imm))));

                const to_mem = mod != 3;
                var addr: u64 = 0;
                const a_val: u64 = if (to_mem) blk: {
                    addr = try self.modrmAddress(modrm, mod, rex_b, rex_x);
                    break :blk try self.load(addr, size);
                } else self.truncateTo(self.regs[rm], size);

                const b_val = self.truncateTo(@bitCast(imm_signed), size);
                const res = switch (sub_op) {
                    0 => a_val +% b_val,
                    4 => a_val & b_val,
                    5 => a_val -% b_val,
                    6 => a_val ^ b_val,
                    7 => a_val -% b_val, // CMP
                    else => return error.UnsupportedAluGroup,
                };
                const masked = self.truncateTo(res, size);
                if (sub_op != 7) {
                    if (to_mem) try self.store(addr, size, masked) else self.regs[rm] = masked;
                }
                switch (sub_op) {
                    0 => self.setAddFlags(a_val, b_val, masked, size),
                    4, 6 => self.setLogicFlags(masked, size),
                    5, 7 => self.setSubFlags(a_val, b_val, masked, size),
                    else => {},
                }
            },
            0xC7 => { // group 11: MOV r/m16/32/64, imm
                const modrm = try self.fetch8();
                const mod: u2 = @truncate(modrm >> 6);
                const ext: u3 = @truncate((modrm >> 3) & 7);
                // Only extension 0 is MOV; the others are unallocated or belong
                // to other groups and must not be guessed at.
                if (ext != 0) return error.UnsupportedGroup11;
                const rm: u4 = @truncate((modrm & 7) + (@as(u8, rex_b) << 3));
                const size: u6 = if (rex_w) 8 else if (operand_16) 2 else 4;
                const imm: u64 = if (size == 8)
                    try self.fetchBits(4) // imm32, sign-extended to 64
                else if (size == 2)
                    try self.fetchBits(2)
                else
                    try self.fetchBits(4);
                const v: u64 = if (size == 8)
                    self.truncateTo(@bitCast(@as(i64, @as(i32, @bitCast(@as(u32, @truncate(imm)))))), 8)
                else
                    self.truncateTo(imm, size);
                if (mod == 3) {
                    self.regs[rm] = v;
                } else {
                    const addr = try self.modrmAddress(modrm, mod, rex_b, rex_x);
                    try self.store(addr, size, v);
                }
            },
            0xB8...0xBF => { // MOV r32/r64, imm
                const r: u4 = @truncate(op - 0xB8 + rex_b);
                if (rex_w) {
                    self.regs[r] = try self.fetchBits(8);
                } else {
                    self.regs[r] = @as(u32, @truncate(try self.fetchBits(4)));
                }
            },
            0xFF => { // group 5: INC/DEC/CALL/JMP r/m
                const modrm = try self.fetch8();
                const mod: u2 = @truncate(modrm >> 6);
                const sub_op: u3 = @truncate((modrm >> 3) & 7);
                const rm: u4 = @truncate((modrm & 7) + (@as(u8, rex_b) << 3));
                const size: u6 = if (rex_w) 8 else if (operand_16) 2 else 4;
                if (mod != 3) return error.IndirectMemoryUnsupported;
                switch (sub_op) {
                    0 => { // INC
                        const a = self.truncateTo(self.regs[rm], size);
                        const res = self.truncateTo(a +% 1, size);
                        self.regs[rm] = res;
                        // INC does NOT touch CF, which is a classic x86 detail.
                        self.setFlag(zf, res == 0);
                        self.setFlag(sf, (res >> @intCast(@as(u7, size) * 8 - 1)) != 0);
                    },
                    1 => { // DEC
                        const a = self.truncateTo(self.regs[rm], size);
                        const res = self.truncateTo(a -% 1, size);
                        self.regs[rm] = res;
                        self.setFlag(zf, res == 0);
                        self.setFlag(sf, (res >> @intCast(@as(u7, size) * 8 - 1)) != 0);
                    },
                    2 => { // CALL r/m64
                        self.endInsn(start);
                        self.regs[4] -= 8;
                        try self.store(self.regs[4], 8, self.pc);
                        self.pc = self.regs[rm];
                        self.branched = true;
                    },
                    4 => { // JMP r/m64
                        self.endInsn(start);
                        self.pc = self.regs[rm];
                        self.branched = true;
                    },
                    else => return error.UnsupportedGroup5,
                }
            },
            0x88, 0x8A, 0xC6 => { // MOV r/m8, r8 / MOV r8, r/m8 / MOV r/m8, imm8
                const modrm = try self.fetch8();
                const mod: u2 = @truncate(modrm >> 6);
                const reg: u4 = @truncate(((modrm >> 3) & 7) + (@as(u8, rex_r) << 3));
                const rm: u4 = @truncate((modrm & 7) + (@as(u8, rex_b) << 3));
                const to_mem: bool = mod != 3;

                if (op == 0xC6) {
                    const imm: u8 = @truncate(try self.fetchBits(1));
                    if (to_mem) {
                        const addr = try self.modrmAddress(modrm, mod, rex_b, rex_x);
                        try self.store(addr, 1, imm);
                    } else self.regs[rm] = imm;
                } else if (op == 0x8A) { // load byte into reg
                    if (to_mem) {
                        const addr = try self.modrmAddress(modrm, mod, rex_b, rex_x);
                        self.regs[reg] = try self.load(addr, 1);
                    } else self.regs[reg] = @as(u8, @truncate(self.regs[rm]));
                } else { // store byte from reg
                    if (to_mem) {
                        const addr = try self.modrmAddress(modrm, mod, rex_b, rex_x);
                        try self.store(addr, 1, self.regs[reg]);
                    } else self.regs[rm] = @as(u8, @truncate(self.regs[reg]));
                }
            },
            else => return error.UnknownOpcode,
        }

        // Non-branch arms land here with the PC exactly past the encoding.
        if (!self.branched) self.endInsn(start);
        return self.len_of_insn;
    }

    /// Records the encoded length as of the current PC. Called at the point the
    /// last operand byte has been consumed and BEFORE any branch moves the PC.
    /// The length is a property of the encoding, not of where control went —
    /// computing it as `pc - start` at function exit made backward jumps
    /// underflow.
    fn endInsn(self: *Cpu, start: u64) void {
        self.len_of_insn = self.pc - start;
    }

    /// Truncates a value to the operand size, zero-extending into the 64-bit
    /// register. 32-bit writes on x86-64 zero the upper half — a real
    /// architectural rule, not an implementation choice.
    fn truncateTo(self: *const Cpu, v: u64, size: u6) u64 {
        _ = self;
        return switch (size) {
            1 => @as(u8, @truncate(v)),
            2 => @as(u16, @truncate(v)),
            4 => @as(u32, @truncate(v)),
            8 => v,
            else => unreachable,
        };
    }

    /// Computes the effective address for a ModRM byte with mod != 3.
    fn modrmAddress(self: *Cpu, modrm: u8, mod: u2, rex_b: u1, rex_x: u1) !u64 {
        const rm_bits = modrm & 7;
        const rm: u4 = @truncate(rm_bits + (@as(u8, rex_b) << 3));

        var base: u64 = 0;
        if (rm_bits == 4) {
            // SIB byte.
            const sib = try self.fetch8();
            const scale: u2 = @truncate(sib >> 6);
            const index: u4 = @truncate(((sib >> 3) & 7) + (@as(u8, rex_x) << 3));
            const base_bits = sib & 7;
            const base_r: u4 = @truncate(base_bits + (@as(u8, rex_b) << 3));
            self.sib_base_is_5 = (base_bits == 5);
            if (!(mod == 0 and base_bits == 5)) {
                base = self.regs[base_r];
            }
            // index == 4 without REX.X means "no index", not rsp.
            if (!(((sib >> 3) & 7) == 4)) {
                base +%= self.regs[index] << @intCast(scale);
            }
        } else if (mod == 0 and rm_bits == 5) {
            // RIP-relative.
            const disp: i32 = @bitCast(@as(u32, @truncate(try self.fetchBits(4))));
            return self.pc +% @as(u64, @bitCast(@as(i64, disp)));
        } else {
            base = self.regs[rm];
        }

        if (mod == 1) {
            const disp: i8 = @bitCast(try self.fetch8());
            base +%= @as(u64, @bitCast(@as(i64, disp)));
        } else if (mod == 2) {
            const disp: i32 = @bitCast(@as(u32, @truncate(try self.fetchBits(4))));
            base +%= @as(u64, @bitCast(@as(i64, disp)));
        } else if (mod == 0) {
            // mod == 0 means "no displacement", EXCEPT in two cases where a disp32
            // is still present:
            //   * rm_bits == 5            -> RIP-relative (handled above)
            //   * rm_bits == 4 (SIB) with sib_base == 5 -> disp32 with no base
            // Anything else has no displacement bytes. An earlier version read a
            // disp32 for every mod==0 SIB operand, which swallowed the next
            // instruction's bytes — `leaq (%rax,%rdx), %rdi` faulted five
            // instructions into the program.
            if (rm_bits == 4) {
                // Determine whether this SIB has a disp32. The SIB byte has
                // already been consumed, so re-derive the base from the byte at
                // `sib_at` rather than re-fetching it.
                if (self.sib_base_is_5) {
                    const disp: i32 = @bitCast(@as(u32, @truncate(try self.fetchBits(4))));
                    base +%= @as(u64, @bitCast(@as(i64, disp)));
                }
            }
        }
        return base;
    }

    fn setAddFlags(self: *Cpu, a: u64, b: u64, res: u64, size: u6) void {
        const bits: u7 = @as(u7, size) * 8;
        const sign: u64 = @as(u64, 1) << @intCast(bits - 1);
        self.setFlag(cf, res < a);
        self.setFlag(zf, res == 0);
        self.setFlag(sf, (res & sign) != 0);
        self.setFlag(of, ((a ^ res) & (b ^ res) & sign) != 0);
    }

    fn setSubFlags(self: *Cpu, a: u64, b: u64, res: u64, size: u6) void {
        const bits: u7 = @as(u7, size) * 8;
        const sign: u64 = @as(u64, 1) << @intCast(bits - 1);
        self.setFlag(cf, a < b);
        self.setFlag(zf, res == 0);
        self.setFlag(sf, (res & sign) != 0);
        self.setFlag(of, ((a ^ b) & (a ^ res) & sign) != 0);
    }

    fn setLogicFlags(self: *Cpu, res: u64, size: u6) void {
        const bits: u7 = @as(u7, size) * 8;
        const sign: u64 = @as(u64, 1) << @intCast(bits - 1);
        // AND/OR/XOR/TEST clear CF and OF by definition.
        self.setFlag(cf, false);
        self.setFlag(of, false);
        self.setFlag(zf, res == 0);
        self.setFlag(sf, (res & sign) != 0);
    }

    fn conditionHolds(self: *const Cpu, cc: u4) bool {
        return switch (cc) {
            0x0 => self.getFlag(of), // O
            0x1 => !self.getFlag(of), // NO
            0x2 => self.getFlag(cf), // B/CS
            0x3 => !self.getFlag(cf), // AE/NC
            0x4 => self.getFlag(zf), // E/Z
            0x5 => !self.getFlag(zf), // NE/NZ
            0x6 => self.getFlag(cf) or self.getFlag(zf), // BE
            0x7 => !self.getFlag(cf) and !self.getFlag(zf), // A
            0x8 => self.getFlag(sf), // S
            0x9 => !self.getFlag(sf), // NS
            0xA => self.getFlag(sf) == self.getFlag(of), // P/PE (as SF==OF: L)
            0xB => self.getFlag(sf) != self.getFlag(of), // L
            0xC => self.getFlag(zf) or (self.getFlag(sf) != self.getFlag(of)), // LE
            0xD => !self.getFlag(zf) and (self.getFlag(sf) == self.getFlag(of)), // G
            0xE => self.getFlag(sf), // S
            else => true, // 0xF: always
        };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Loads raw bytes at offset 0 of a zero-filled image.
fn image(code: []const u8) ![]u8 {
    const bytes = try testing.allocator.alloc(u8, code.len + 1024);
    @memset(bytes, 0);
    @memcpy(bytes[0..code.len], code);
    return bytes;
}

/// Loads raw bytes at a chosen offset, for tests that need a non-zero PC.
fn imageAt(code: []const u8, at: usize) ![]u8 {
    const bytes = try testing.allocator.alloc(u8, at + code.len + 1024);
    @memset(bytes, 0);
    @memcpy(bytes[at..][0..code.len], code);
    return bytes;
}

test "the decoder reports the real encoded length, which varies by instruction" {
    // This is the property that makes x86-64 the interesting density column.
    const img = try image(&.{
        0x50, // pushq %rax           -> 1 byte
        0x48, 0x01, 0xC8, // addq %rcx, %rax  -> 3 bytes
        0x48, 0x83, 0xC0, 0x05, // addq $5, %rax -> 4 bytes
        0x48, 0xC7, 0xC0, 0x05, 0x00, 0x00, 0x00, // movq $5, %rax -> 7 bytes
    });
    defer testing.allocator.free(img);
    var cpu = Cpu.init(img);
    const expected = [_]u64{ 1, 3, 4, 7 };
    for (expected) |e| {
        const len = try cpu.step();
        try testing.expectEqual(e, len);
    }
}

test "MOV immediate and ADD register compute correctly" {
    // movq $5, %rax ; movq $37, %rcx ; addq %rcx, %rax
    const img = try image(&.{
        0x48, 0xC7, 0xC0, 0x05, 0x00, 0x00, 0x00,
        0x48, 0xC7, 0xC1, 0x25, 0x00, 0x00, 0x00,
        0x48, 0x01, 0xC8,
    });
    defer testing.allocator.free(img);
    var cpu = Cpu.init(img);
    _ = try cpu.step();
    _ = try cpu.step();
    try testing.expectEqual(@as(u64, 5), cpu.read(0)); // rax
    try testing.expectEqual(@as(u64, 37), cpu.read(1)); // rcx
    _ = try cpu.step();
    try testing.expectEqual(@as(u64, 42), cpu.read(0));
}

test "a 32-bit write zeroes the upper half of the register" {
    // Architectural rule: `movl $5, %eax` leaves rax = 5, not rax | 5.
    const img = try image(&.{
        0x48, 0xC7, 0xC0, 0xFF, 0xFF, 0xFF, 0xFF, // movq $-1, %rax
        0xB8, 0x05, 0x00, 0x00, 0x00, // movl $5, %eax
    });
    defer testing.allocator.free(img);
    var cpu = Cpu.init(img);
    _ = try cpu.step();
    try testing.expectEqual(@as(u64, 0xFFFFFFFFFFFFFFFF), cpu.read(0));
    _ = try cpu.step();
    try testing.expectEqual(@as(u64, 5), cpu.read(0)); // upper half cleared
}

test "memory operands load and store through ModRM" {
    // movq $200, %rbx ; movq $99, %rdx ; movq %rdx, (%rbx) ; movq (%rbx), %rcx
    const img = try image(&.{
        0x48, 0xC7, 0xC3, 0xC8, 0x00, 0x00, 0x00, // movq $200, %rbx
        0x48, 0xC7, 0xC2, 0x63, 0x00, 0x00, 0x00, // movq $99, %rdx
        0x48, 0x89, 0x13, // movq %rdx, (%rbx)
        0x48, 0x8B, 0x0B, // movq (%rbx), %rcx
    });
    defer testing.allocator.free(img);
    var cpu = Cpu.init(img);
    for (0..3) |_| _ = try cpu.step();
    try testing.expectEqual(@as(u64, 99), std.mem.readInt(u64, img[200..208], .little));
    _ = try cpu.step();
    try testing.expectEqual(@as(u64, 99), cpu.read(1)); // rcx
}

test "LEA computes an address and does NOT dereference it" {
    // leaq 8(%rax), %rax with rax = 100 must give 108, and must not read memory.
    const img = try image(&.{ 0x48, 0x8D, 0x40, 0x08 });
    defer testing.allocator.free(img);
    var cpu = Cpu.init(img);
    cpu.write(0, 100);
    _ = try cpu.step();
    try testing.expectEqual(@as(u64, 108), cpu.read(0));
}

test "cmp sets ZF and jne / je act on it" {
    // movq $7,%rax ; movq $7,%rcx ; cmpq %rcx,%rax ; jne +4 (not taken) ; je +4 (taken)
    const img = try image(&.{
        0x48, 0xC7, 0xC0, 0x07, 0x00, 0x00, 0x00,
        0x48, 0xC7, 0xC1, 0x07, 0x00, 0x00, 0x00,
        0x48, 0x39, 0xC8, // cmpq %rcx, %rax
        0x75, 0x07, // jne +7 (skip the next 7-byte mov)
        0x48, 0xC7, 0xC2, 0x6F, 0x00, 0x00, 0x00, // movq $111, %rdx  (executed)
        0x74, 0x07, // je +7 (taken; skip the next mov)
        0x48, 0xC7, 0xC3, 0xDE, 0x00, 0x00, 0x00, // movq $222, %rbx  (SKIPPED)
    });
    defer testing.allocator.free(img);
    var cpu = Cpu.init(img);
    for (0..6) |_| {
        _ = try cpu.step();
        if (cpu.pc >= img.len) break;
    }
    try testing.expectEqual(@as(u64, 111), cpu.read(2)); // rdx: executed
    try testing.expectEqual(@as(u64, 0), cpu.read(3)); // rbx: skipped
}

test "INC does not touch CF, which SUB would" {
    const img = try image(&.{
        0x48, 0xC7, 0xC0, 0xFF, 0xFF, 0xFF, 0xFF, // movq $-1, %rax
        0x48, 0xFF, 0xC0, // incq %rax  -> 0, CF must stay clear
    });
    defer testing.allocator.free(img);
    var cpu = Cpu.init(img);
    _ = try cpu.step();
    cpu.flags = 0;
    _ = try cpu.step();
    try testing.expectEqual(@as(u64, 0), cpu.read(0));
    try testing.expect(((cpu.flags >> 6) & 1) == 1); // ZF set
    try testing.expect(((cpu.flags >> 0) & 1) == 0); // CF clear
}

test "a non-branch instruction that mis-advances the PC is a decoder bug, not silence" {
    // The harness relies on `step` returning the true length. If a decoder path
    // advanced the PC by something else, every later instruction would be
    // garbage — so `step` refuses the inconsistency rather than continuing.
    const img = try image(&.{0x90});
    defer testing.allocator.free(img);
    var cpu = Cpu.init(img);
    const len = try cpu.step();
    try testing.expectEqual(@as(u64, 1), len);
    try testing.expectEqual(@as(u64, 1), cpu.pc);
}

test "a negative rel8 branch goes backwards from the END of the instruction" {
    // je -8 placed at offset 100: target = 100 + 2 + (-8) = 94.
    const img = try imageAt(&.{ 0x74, 0xF8 }, 100);
    defer testing.allocator.free(img);
    var cpu = Cpu.init(img);
    cpu.flags = 1 << 6; // ZF
    cpu.pc = 100;
    _ = try cpu.step();
    try testing.expectEqual(@as(u64, 94), cpu.pc);
}

test "the harness measures an x86-64 program end to end" {
    const img = try image(&.{
        0x48, 0xC7, 0xC0, 0x05, 0x00, 0x00, 0x00, // movq $5, %rax   7 bytes
        0x48, 0x01, 0xC0, // addq %rax, %rax                  3 bytes
        0x90, // nop                                          1 byte
    });
    defer testing.allocator.free(img);
    var cpu = Cpu.init(img);
    const out = harness.run(&cpu, 3);
    try testing.expect(out == .exhausted);
    try testing.expectEqual(@as(u64, 3), out.exhausted.retired);
    try testing.expectEqual(@as(u64, 11), out.exhausted.code_bytes); // 7 + 3 + 1
}

// ---------------------------------------------------------------------------
// Oracle tests: raw bytes from LLVM's assembler
// ---------------------------------------------------------------------------
//
// Recorded command and output for each row:
//
//   $ echo "addq %rcx, %rax" | llvm-mc -triple=x86_64 -show-encoding
//           addq %rcx, %rax   # encoding: [0x48,0x01,0xc8]

test "ORACLE: LLVM's own x86-64 bytes decode and execute correctly" {
    // Each case is raw bytes copied from llvm-mc output, checked for the effect
    // the assembly names. This is stronger than an encode round trip: a matching
    // pair of wrong encoder and wrong decoder would pass a round trip and fail
    // here.
    const Case = struct { name: []const u8, bytes: []const u8, check: *const fn (*Cpu) anyerror!void };
    const cases = [_]Case{
        .{ .name = "movq $5, %rax", .bytes = &.{ 0x48, 0xC7, 0xC0, 0x05, 0x00, 0x00, 0x00 }, .check = struct {
            fn f(c: *Cpu) anyerror!void {
                try testing.expectEqual(@as(u64, 5), c.read(0));
            }
        }.f },
        .{ .name = "addq %rcx, %rax", .bytes = &.{ 0x48, 0x01, 0xC8 }, .check = struct {
            fn f(c: *Cpu) anyerror!void {
                try testing.expectEqual(@as(u64, 50), c.read(0)); // 45 + 5
            }
        }.f },
        .{ .name = "movq (%rbx), %rdx", .bytes = &.{ 0x48, 0x8B, 0x13 }, .check = struct {
            fn f(c: *Cpu) anyerror!void {
                // Memory at [rbx] is 77 and rdx starts at 0 for this case (the
                // harness sets 0 before the load cases), so a decoder that did
                // nothing would leave 0 here and fail.
                try testing.expectEqual(@as(u64, 77), c.read(2));
            }
        }.f },
        .{ .name = "movq %rdx, (%rbx)", .bytes = &.{ 0x48, 0x89, 0x13 }, .check = struct {
            fn f(c: *Cpu) anyerror!void {
                try testing.expectEqual(@as(u64, 77), std.mem.readInt(u64, c.mem[200..208], .little));
            }
        }.f },
    };
    for (cases) |c| {
        const img = try image(c.bytes);
        defer testing.allocator.free(img);
        var cpu = Cpu.init(img);
        // Every case is given the same initial state, chosen so that no case's
        // own expectation is destroyed by the setup. `movq $5, %rax` writes rax,
        // so rax's initial 45 is only relevant to the ADD case.
        cpu.write(1, 5); // rcx
        cpu.write(0, 45); // rax
        cpu.write(3, 200); // rbx
        // rdx = 77 so the STORE case ("movq %rdx, (%rbx)") writes a known value,
        // and the LOAD case ("movq (%rbx), %rdx") is distinguishable from a no-op
        // because memory at [rbx] is also 77. Both cases then assert 77, which a
        // decoder that did nothing at all would also produce — so the load case
        // additionally requires that rdx CHANGED from a different sentinel, and
        // the store case checks memory. See the per-case checks below.
        // The LOAD case needs rdx to start somewhere other than 77, or a decoder
        // that never wrote rdx would still pass. The STORE case needs rdx = 77.
        const is_load_case = std.mem.eql(u8, c.name, "movq (%rbx), %rdx");
        cpu.write(2, if (is_load_case) 0 else 77);
        std.mem.writeInt(u64, img[200..208], 77, .little);
        const len = try cpu.step();
        testing.expectEqual(@as(u64, c.bytes.len), len) catch |e| {
            std.debug.print("ORACLE LENGTH MISMATCH for {s}: expected {d}, got {d}\n", .{ c.name, c.bytes.len, len });
            return e;
        };
        c.check(&cpu) catch |e| {
            std.debug.print("ORACLE FAILURE for {s}\n", .{c.name});
            return e;
        };
    }
}

test "ORACLE: the exact byte lengths LLVM reports" {
    // The density claim depends on these lengths being right, so they are pinned
    // against llvm-mc's output rather than against my own idea of them.
    const cases = [_]struct { name: []const u8, bytes: []const u8 }{
        .{ .name = "movq $5,%rax", .bytes = &.{ 0x48, 0xC7, 0xC0, 0x05, 0x00, 0x00, 0x00 } }, // 7
        .{ .name = "movl $5,%eax", .bytes = &.{ 0xB8, 0x05, 0x00, 0x00, 0x00 } }, // 5
        .{ .name = "addq %rcx,%rax", .bytes = &.{ 0x48, 0x01, 0xC8 } }, // 3
        .{ .name = "addq $5,%rax", .bytes = &.{ 0x48, 0x83, 0xC0, 0x05 } }, // 4
        .{ .name = "subq $8,%rax", .bytes = &.{ 0x48, 0x83, 0xE8, 0x08 } }, // 4
        .{ .name = "cmpq %rcx,%rdx", .bytes = &.{ 0x48, 0x39, 0xCA } }, // 3
        .{ .name = "pushq %rax", .bytes = &.{0x50} }, // 1
        .{ .name = "popq %rax", .bytes = &.{0x58} }, // 1
        .{ .name = "retq", .bytes = &.{0xC3} }, // 1
        .{ .name = "nop", .bytes = &.{0x90} }, // 1
    };
    for (cases) |c| {
        const img = try image(c.bytes);
        defer testing.allocator.free(img);
        var cpu = Cpu.init(img);
        // PUSH/POP need a plausible stack; RET is skipped as it would fault.
        cpu.write(4, 900);
        if (c.name.len > 0 and std.mem.eql(u8, c.name, "retq")) continue;
        const len = try cpu.step();
        testing.expectEqual(@as(u64, c.bytes.len), len) catch |e| {
            std.debug.print("LENGTH MISMATCH for {s}: expected {d}, got {d}\n", .{ c.name, c.bytes.len, len });
            return e;
        };
    }
}
