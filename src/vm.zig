//! CLS64 core: flat memory, register file, and the in-order fetch-decode-execute loop.
//!
//! Fidelity: executable model. Registers, memory and the ALU control path are real
//! behaviour with real tests; the capability checks are a software model with no tag
//! bits (docs/isa-encoding.md §8). Nothing here claims silicon performance.
//!
//! Allocation policy (AGENTS.md §4.1): `Vm.init` allocates the memory image once.
//! `step` and `run` allocate nothing — no allocator is in scope inside the loop.
//!
//! Failures are values, never silent: a halted VM, a refusing bound check and an
//! undecodable word each come back as a `Diagnostic` rendered as a plain sentence.

const std = @import("std");

pub const memory = @import("memory.zig");
pub const registers = @import("registers.zig");
pub const diagnostics = @import("diagnostics.zig");
pub const decoding = @import("decoder.zig");
/// §3.3 bitfield slicing (model module). Re-exported because tests/vm_tests.zig can
/// only reach what this module root exposes.
pub const bits = @import("field.zig");
/// §3.2 comparison and branchless select (model module).
pub const selection = @import("select.zig");
/// §3.4 stream engine (model module).
pub const streaming = @import("stream.zig");
/// §3.5/§6 capability descriptors (model module). Not cryptographic: bounds and
/// permission checks only, no tag bits (docs/isa-encoding.md §6, §8).
pub const capability = @import("capability.zig");
/// §3.7 SMT-8 thread slots (model module).
///
/// FIDELITY: this is a DETERMINISTIC modelled interleave, not real concurrency.
/// Slots are stepped one at a time on a single thread of execution. There is no
/// timing, no parallel hardware, and no speedup claim (docs/isa-encoding.md §8).
pub const threading = @import("thread.zig");

pub const Memory = memory.Memory;
pub const File = registers.File;
pub const Width = registers.Width;
pub const Diagnostic = diagnostics.Diagnostic;

/// docs/isa-encoding.md §4: index 14 is the program counter. A non-control
/// instruction has no defined meaning for writing it.
pub const pc_index: u4 = 14;

/// Instruction width is fixed at 64 bits (docs/isa-encoding.md §1), so the PC stride
/// is a constant and only jump/call/ret move it anywhere else.
pub const instruction_bytes: u64 = 8;

pub const Fault = error{ OutOfBounds, VmFault };

/// Why the machine stopped. Every variant carries the sentence the user sees.
pub const HaltReason = struct {
    kind: Kind,
    diag: Diagnostic,

    pub const Kind = enum { halted, fault, breakpoint };
};

pub const Step = union(enum) {
    /// Decoded and executed; PC now points at the next instruction, or at the target
    /// of a jump/call/ret.
    advanced,
    /// The program executed `halt`.
    halted: Diagnostic,
    /// The instruction could not be executed. Nothing was committed by it.
    fault: Diagnostic,
};

pub const Vm = struct {
    /// The flat image, allocated once in `init` and never reallocated (AGENTS.md §4.1).
    mem: Memory,
    regs: File = .{},
    /// Instructions retired. Advisory simulator count, not a silicon cycle count.
    retired: u64 = 0,
    halted: bool = false,
    /// §3.7 SMT-8 slots. DETERMINISTIC modelled interleave: slots are dispatched one
    /// at a time, round-robin, on this single thread of execution. Not parallel, no
    /// timing, no speedup claim (docs/isa-encoding.md §8). Default-initialised, so
    /// `init` still allocates nothing (AGENTS.md §4.1).
    sched: threading.Scheduler = .{},

    /// The single allocation point. `image` becomes the VM's memory in place, so the
    /// execution loop below never needs an allocator.
    pub fn init(image: []u8) Vm {
        return .{ .mem = Memory.init(image) };
    }

    /// One fetch-decode-execute step. No allocation, no hidden unwinding: failures
    /// come back as diagnostics.
    pub fn step(self: *Vm) Fault!Step {
        const pc = self.regs.pc;
        const word = self.mem.read64(pc) catch return self.faultOutOfBounds("fetching the instruction", pc, 8);

        const decoded = decoding.decode(word);
        switch (decoded) {
            .err => |diag| {
                self.halted = true;
                // The decoder is a pure function of the word, so it cannot know where
                // the word was found. Contract P1.6 requires the PC in this failure,
                // and the VM is the component that has it.
                var with_pc = diag;
                if (with_pc.pc == null) with_pc.pc = pc;
                return .{ .fault = with_pc };
            },
            .ok => |ins| return self.execute(ins, pc, word),
        }
    }

    /// Runs until halt, fault or `limit` retired instructions. `limit` exists so an
    /// infinite program fails loudly instead of hanging; it is not a cycle claim.
    pub fn run(self: *Vm, limit: u64) Fault!Diagnostic {
        var i: u64 = 0;
        while (i < limit) : (i += 1) {
            switch (try self.step()) {
                .advanced => {},
                .halted => |d| return d,
                .fault => |d| return d,
            }
        }
        self.halted = true;
        return .{
            .stage = "executing this program",
            .expected = "the program to reach a halt instruction",
            .detail = "The simulator stopped it after reaching the instruction limit: the program did not halt on its own.",
        };
    }

    /// Exact architectural state, for determinism comparisons (contract P1.6).
    ///
    /// `mem_hash` is a digest of every memory byte, so a run that differs only in
    /// memory contents is *observable* here. A hash is still a hash: a caller that
    /// needs byte-exact equality compares `vm.mem.bytes` directly. `mem_len` is kept
    /// alongside so a length change is reported as itself rather than as a hash delta.
    /// ZERO is not stored: registers.zig models it as a constant, so its absence from
    /// this snapshot is correct, not an omission.
    pub fn snapshot(self: *const Vm) Snapshot {
        var h = std.hash.Wyhash.init(0);
        h.update(self.mem.bytes);
        return .{
            .regs = self.regs,
            .mem_len = self.mem.bytes.len,
            .mem_hash = h.final(),
            .retired = self.retired,
        };
    }

    pub const Snapshot = struct {
        regs: File,
        mem_len: usize,
        /// Digest of the memory contents; see `snapshot`.
        mem_hash: u64,
        retired: u64,

        /// Digest comparison: catches a divergence in registers, in memory contents,
        /// in memory length or in the retired-instruction count.
        pub fn eql(a: Snapshot, b: Snapshot) bool {
            return std.meta.eql(a.regs, b.regs) and
                a.mem_len == b.mem_len and
                a.mem_hash == b.mem_hash and
                a.retired == b.retired;
        }
    };

    // -- the loop ------------------------------------------------------------

    fn execute(self: *Vm, ins: decoding.Instruction, pc: u64, word: u64) Fault!Step {
        switch (ins) {
            .nop => {},

            .halt => {
                self.retired += 1;
                self.halted = true;
                return .{ .halted = .{ .stage = "halting", .detail = "The program executed halt." } };
            },

            // §3.0 encodes jump and call with the same 48-bit immediate and the same
            // payload type, so the opcode byte inside the payload is what separates
            // them: 0x03 sets LR, 0x02 does not (§3.0 rows 0x02/0x03).
            .jump, .call => |ctrl| {
                self.retired += 1;
                if (ctrl.opcode == 0x03) self.regs.lr = pc +| instruction_bytes;
                self.regs.pc = ctrl.target;
                return .advanced;
            },

            .ret => {
                self.retired += 1;
                self.regs.pc = self.regs.lr;
                return .advanced;
            },

            // §3.0.1 `branch`: transfer when the status enum in rs1 equals the
            // match value, otherwise fall through. This is the ISA's only
            // conditional control transfer, and without it no loop can be written.
            .branch => |b| {
                self.retired += 1;
                const status = self.regs.read(b.rs1) & 0xF;
                if (status == b.match_val) {
                    // The offset is relative to the BRANCH ITSELF, per §3.0.1 —
                    // not to the following instruction. Computed with wrapping
                    // arithmetic so a backward branch near address 0 wraps rather
                    // than panicking; the fetch bounds check reports it.
                    self.regs.pc = pc +% @as(u64, @bitCast(b.offset));
                } else {
                    self.regs.pc = pc +| instruction_bytes;
                }
                return .advanced;
            },

            // §3.1.1 scalar memory access. The whole access is bounds-checked
            // before any byte moves, matching §3.4's all-or-nothing rule for
            // chunks: a partially applied store is the failure mode that makes
            // memory access untrustworthy.
            .load => |m| {
                self.retired += 1;
                if (m.rd == pc_index) return try self.reportPcWrite("a load", pc, word);
                const addr = self.regs.read(m.rs1) +% @as(u64, @bitCast(m.offset));
                // §5 width: 0 = 64-bit, 1 = .l (32), 2 = .w (16), 3 = .b (8).
                const raw: u64 = switch (m.width) {
                    .full => self.mem.read64(addr) catch
                        return try self.reportLoadStoreBounds("reading from memory", addr, 8, pc, word),
                    .l => self.mem.read32(addr) catch
                        return try self.reportLoadStoreBounds("reading from memory", addr, 4, pc, word),
                    .w => self.mem.read16(addr) catch
                        return try self.reportLoadStoreBounds("reading from memory", addr, 2, pc, word),
                    .b => self.mem.read8(addr) catch
                        return try self.reportLoadStoreBounds("reading from memory", addr, 1, pc, word),
                };
                // §2.1: a sub-width load ZERO-EXTENDS into rd, like every other
                // sub-register write. read8/16/32 already return the widened value.
                self.regs.write(m.rd, raw);
                self.regs.pc = pc +| instruction_bytes;
                return .advanced;
            },

            .store => |m| {
                self.retired += 1;
                const addr = self.regs.read(m.rs1) +% @as(u64, @bitCast(m.offset));
                const v = self.regs.read(m.rs2);
                switch (m.width) {
                    .full => self.mem.write64(addr, v) catch
                        return try self.reportLoadStoreBounds("writing to memory", addr, 8, pc, word),
                    .l => self.mem.write32(addr, @truncate(v)) catch
                        return try self.reportLoadStoreBounds("writing to memory", addr, 4, pc, word),
                    .w => self.mem.write16(addr, @truncate(v)) catch
                        return try self.reportLoadStoreBounds("writing to memory", addr, 2, pc, word),
                    .b => self.mem.write8(addr, @truncate(v)) catch
                        return try self.reportLoadStoreBounds("writing to memory", addr, 1, pc, word),
                }
                self.regs.pc = pc +| instruction_bytes;
                return .advanced;
            },

            // The decoder tags each ALU opcode individually (§3.1), so group the
            // ten of them onto the one execution path. Deleting this arm instead
            // would drop every ALU instruction into the fault below. `compare` is
            // NOT here: it has its own arm below, since it yields a status enum.
            .add, .sub, .mul, .div, .and_, .or_, .xor_, .shl, .shr, .mov => |a| {
                // §4: index 14 is PC, and a normal ALU op has no defined meaning for
                // writing it. The fixed-width advance below would overwrite the result,
                // so fault here rather than let the value vanish unremarked.
                if (a.rd == pc_index) return try self.reportPcWrite("an arithmetic instruction", pc, word);
                self.alu(a) catch |err| return try self.reportAluError(err, a, pc, word);
            },

            // §3.2.1 `compare` materialises the explicit status enum into rd.
            // Signedness is a property of the instruction, and this decoder does not
            // carry one, so the encoding contract's only defined reading is used: the
            // signed view, which is what §3.2.1 defines LESS/GREATER against.
            .compare => |a| {
                if (a.rd == pc_index) return try self.reportPcWrite("compare", pc, word);
                const rhs: u64 = if (a.imm) |imm| @bitCast(imm) else self.regs.read(a.rs2);
                self.regs.writeWidth(a.rd, a.width, @intFromEnum(selection.compareSigned(
                    @bitCast(self.regs.read(a.rs1)),
                    @bitCast(rhs),
                )));
            },

            // §3.2.2 branchless select: no branch, no PC change beyond the stride.
            .select => |sel| {
                if (sel.rd == pc_index) return try self.reportPcWrite("select", pc, word);
                const status = statusOf(self.regs.read(sel.rs1)) orelse return .{ .fault = .{
                    .stage = "executing a select",
                    .word = word,
                    .pc = pc,
                    .operand = .{ .name = "status register", .text = "not a status enum value" },
                    .expected = "a status value from 0 (EQUAL) to 4 (UNSIGNED_GREATER) in the status register",
                    .detail = "The architecture defines exactly five comparison outcomes; anything else cannot select an arm.",
                } };
                self.regs.write(sel.rd, selection.select(
                    status,
                    @enumFromInt(@intFromEnum(sel.match_val)),
                    self.regs.read(sel.true_reg),
                    self.regs.read(sel.false_reg),
                ));
            },

            // §3.4 stream engine: the model module enforces the atomic bounds rule and
            // owns the pointer auto-advance.
            .stream_add, .stream_copy, .stream_fill, .stream_setp => |st| {
                self.stream(st, pc, word) catch |err| return try self.reportStreamError(err, pc, word);
            },

            // §3.3 bitfield slicing, real behaviour from the model module.
            .field_extract => |f| {
                if (f.rd == pc_index) return try self.reportPcWrite("field.extract", pc, word);
                self.regs.write(f.rd, bits.extract(self.regs.read(f.rs1), f.offset, f.width) catch |err|
                    return try self.reportFieldError(err, f, pc, word));
            },

            .field_insert => |f| {
                if (f.rd == pc_index) return try self.reportPcWrite("field.insert", pc, word);
                self.regs.write(f.rd, bits.insert(self.regs.read(f.rs1), self.regs.read(f.src2), f.offset, f.width) catch |err|
                    return try self.reportFieldError(err, f, pc, word));
            },

            // §3.7 thread slots. These dispatch into the modelled interleave; they do
            // not create real concurrency (docs/isa-encoding.md §8).
            .thread_spawn => |t| {
                self.spawnSlots(t, pc, word) catch |err| return try self.reportThreadError(err, t.slots, pc, word);
            },

            .thread_join => |t| {
                self.joinSlots(t, pc, word) catch |err| return try self.reportThreadError(err, t.slots, pc, word);
            },

            .thread_yield => |t| {
                _ = t;
                // Dispatch the next runnable slot, round-robin. An empty run queue is a
                // diagnostic, not a silent advance: yielding with nothing to run would
                // otherwise look like a successful switch.
                if (self.sched.nextRunnable() == null) {
                    self.halted = true;
                    return .{ .fault = .{
                        .stage = "executing a thread yield",
                        .word = word,
                        .pc = pc,
                        .mnemonic = "thread.yield",
                        .operand = .{ .name = "runnable slot", .text = "none" },
                        .expected = "at least one thread slot in the running state to yield to",
                        .detail = "No slot is running, so there is nothing to switch to. In this deterministic modelled interleave a yield with an empty run queue cannot make progress, so it is reported instead of advancing.",
                    } };
                }
                const next = self.sched.nextRunnable().?;
                self.sched.last_dispatched = next;
                self.sched.dispatches += 1;
            },

            // §3.5 capability instructions. cap.load/cap.store REFUSE LOUDLY: v1.11
            // ruled them decode-only because the encoding carries no address field.
            .cap_load, .cap_store => |c| {
                return try self.refuseCapabilityTransfer(c, pc, word);
            },

            .cap_check => |c| {
                return try self.capCheck(c, pc, word);
            },

            // The remaining primitives are owned by their model modules
            // (docs/isa-encoding.md §3.2, §3.6). Until one is wired in, the machine
            // says so in plain language instead of guessing.
            else => {
                self.halted = true;
                return .{ .fault = .{
                    .stage = "executing this instruction",
                    .word = word,
                    .pc = pc,
                    .expected = "an instruction this simulator implements",
                    .detail = "This opcode is defined by the encoding contract but is not wired into this build yet.",
                } };
            },
        }

        // Normal advance: every instruction is one 64-bit word wide.
        self.retired += 1;
        self.regs.pc = pc +| instruction_bytes;
        return .advanced;
    }

    /// §3.2.1's five outcomes; a register holding anything else cannot drive a select.
    fn statusOf(raw: u64) ?selection.Status {
        if (raw > 4) return null;
        return @enumFromInt(@as(u4, @intCast(raw)));
    }

    const StreamFault = error{
        ChunkNotPositive,
        BadElementWidth,
        NotAStreamPointer,
        OutOfBounds,
    };

    /// §3.4: bounds the whole chunk before touching a byte, then advances the pointer
    /// register by `chunk * elementSize`. The stream engine owns both rules.
    fn stream(self: *Vm, st: decoding.Stream, pc: u64, word: u64) StreamFault!void {
        _ = pc;
        _ = word;
        const width = streaming.ElemWidth.fromEncoded(@intFromEnum(st.width)) catch return error.BadElementWidth;
        // §3.4: for add/copy/fill the pointer is `rs1` (the bracketed register);
        // for `setp` it is `rd`, because setp's operand text is
        // `stream.setp <ptr>, <stride>` and it has no `rs1` field at all.
        const ptr_reg = if (st.op == 0x43) self.regs.read(st.rd) else self.regs.read(st.rs1);
        var engine = streaming.State.init(self.mem, ptr_reg);

        switch (st.op) {
            0x40 => try engine.add(self.regs.read(st.rs2), st.chunk, width),
            0x41 => try engine.copy(self.regs.read(st.rs2), st.chunk, width),
            0x42 => try engine.fill(self.regs.read(st.rd), st.chunk, width),
            0x43 => {
                // `stream.setp`: pointer register = current + signed 40-bit stride.
                //
                // F19 (VM half): the pointer register for `setp` is `rd`, not
                // `rs1`. The assembler emits `stream.setp R1, -16` as rd=1,
                // rs1=0, and §3.4 gives `setp` no `rs1` — the decoder now rejects
                // a non-zero one. This line wrote `st.rs1`, so the instruction
                // updated R0 and left the named pointer untouched. Invisible
                // until now because the test fixture set rs1=1 by hand.
                self.regs.write(st.rd, @bitCast(@as(i64, @bitCast(ptr_reg)) +% st.stride));
                return;
            },
            else => return error.NotAStreamPointer,
        }

        // Auto-advance is the engine's whole point: no software index arithmetic.
        self.regs.write(st.rs1, engine.ptr);
    }

    /// §3.1.1: an out-of-bounds scalar access, reported in plain language with the
    /// address and size that failed (AGENTS.md §4.2 forbids a bare hex code).
    fn reportLoadStoreBounds(self: *Vm, action: []const u8, addr: u64, size: u64, pc: u64, word: u64) Fault!Step {
        _ = pc;
        _ = word;
        // Matches the existing `faultOutOfBounds` pattern: record the sentence the
        // caller will print, halt, and surface the error. Returning the text here
        // would duplicate a rendering path the VM already has.
        return self.faultOutOfBounds(action, addr, size);
    }

    fn reportStreamError(self: *Vm, err: StreamFault, pc: u64, word: u64) Fault!Step {
        self.halted = true;
        const detail: []const u8 = switch (err) {
            error.ChunkNotPositive => "A stream chunk must cover at least one element (§3.4).",
            error.BadElementWidth => "A stream element is 8, 16, 32 or 64 bits wide.",
            error.NotAStreamPointer => "The stream pointer register does not hold an address this engine can advance.",
            error.OutOfBounds => "The whole chunk must fit in the accessible region; no element was modified.",
        };
        return .{ .fault = .{
            .stage = "executing a stream instruction",
            .word = word,
            .pc = pc,
            .operand = .{ .name = "stream chunk", .text = "does not fit the accessible region" },
            .expected = "a chunk that lies entirely inside memory, with at least one element",
            .detail = detail,
        } };
    }

    const AluError = error{ DivideByZero, ReservedWidthEncoding, UnknownAluOpcode };

    /// §3.3.1 field constraints become diagnostics, never silent wraps.
    fn reportFieldError(self: *Vm, err: bits.FieldError, f: decoding.Field, pc: u64, word: u64) Fault!Step {
        _ = f;
        self.halted = true;
        const detail: []const u8 = switch (err) {
            error.ZeroWidth => "A field width must be at least 1 bit (§3.3.1).",
            error.FieldExceedsRegister => "The bit offset plus the field width must not run past bit 63 of the register.",
            error.InsertValueTooWide => "The value being packed does not fit the declared field width; packing it would discard the high bits.",
        };
        return .{ .fault = .{
            .stage = "executing a field instruction",
            .word = word,
            .pc = pc,
            .operand = .{ .name = "bitfield", .text = "offset and width out of range" },
            .expected = "offset + width <= 64, with width from 1 to 64",
            .detail = detail,
        } };
    }

    fn alu(self: *Vm, a: decoding.Alu) AluError!void {
        const lhs = self.regs.read(a.rs1);
        // `imm: ?i64` is already sign-extended by the decoder: §3.1's signed 28-bit
        // immediate sign-extends to all-ones above bit 39 when bit 27 is set.
        const rhs: u64 = if (a.imm) |imm| @bitCast(imm) else self.regs.read(a.rs2);

        const result: u64 = switch (a.op) {
            0x10 => lhs +% rhs,
            0x11 => lhs -% rhs,
            0x12 => lhs *% rhs,
            0x13 => if (rhs == 0) return error.DivideByZero else lhs / rhs,
            0x14 => lhs & rhs,
            0x15 => lhs | rhs,
            0x16 => lhs ^ rhs,
            // A shift of 64 or more leaves zero, per the encoding contract's shift width.
            0x17 => if (rhs >= 64) 0 else lhs << @intCast(rhs),
            0x18 => if (rhs >= 64) 0 else lhs >> @intCast(rhs),
            0x19 => rhs,
            else => return error.UnknownAluOpcode,
        };

        // A sub-width write zero-extends the upper bits (AGENTS.md §2.1); a reserved
        // width encoding must be reported rather than silently treated as full width.
        self.regs.writeWidth(a.rd, a.width, result);
    }

    /// §3.5 `cap.load` / `cap.store`: REFUSE, per Amendment 1.11's fidelity ruling.
    ///
    /// These are decode-only this revision. They perform a *memory* transfer of a
    /// 128-bit descriptor, but §3.5 defines no address field, and v1.11 rejected both
    /// readings that would supply one: the pair cannot hold the address because §6
    /// makes the pair hold the descriptor itself, and a third register is not
    /// representable (that was defect F12). So there is no address to use, and this
    /// refuses rather than inventing one. It does not guess, and it does not return
    /// zero: a fabricated address would silently read or write the wrong memory.
    fn refuseCapabilityTransfer(self: *Vm, c: decoding.Cap, pc: u64, word: u64) Fault!Step {
        self.halted = true;
        const mnemonic = if (c.op == 0x50) "cap.load" else "cap.store";
        return .{ .fault = .{
            .stage = "executing a capability transfer",
            .word = word,
            .pc = pc,
            .mnemonic = mnemonic,
            .expected = "an instruction whose address source is defined by the encoding contract",
            .detail = "This revision defines no address source for a capability transfer: docs/isa-encoding.md §3.5 has no address field, the descriptor's register pair holds the descriptor itself rather than an address (§6), and a third register operand cannot be encoded. The instruction was refused rather than given a guessed address. It encodes, disassembles and round-trips; it does not execute until a revision defines where its address comes from.",
        } };
    }

    /// §3.5 `cap.check`: `rd = capability access status` for the descriptor in `rs1`.
    ///
    /// READING CHOSEN, and why it cannot be the whole instruction (see REPORTED GAP
    /// below): the descriptor is materialised from the register pair named by `rs1`,
    /// per §6's own diagram — the low register is `base` (a full 64-bit word, §6
    /// "word 0"), and the high register carries `permissions` in its bits[15:8], with
    /// the low byte reserved-zero. That much is literally drawn in §6.
    ///
    /// REPORTED GAP — why this refuses instead of producing a value:
    /// §6 defines the descriptor as base + length + perms. The pair can carry `base`
    /// and `perms`, but `length` has NO bit position anywhere in the pair: §6's own
    /// fidelity note records that the old "length stored in permissions[23:0]" line
    /// described a packing that "does not exist" and was deleted. So a Capability
    /// cannot be reconstructed from `rs1` alone, and the region to test against is
    /// undefined.
    /// Worse, even with a descriptor the result is undefined: `check` needs an
    /// *address*, a *size* and an *access kind*, and the encoding supplies none of the
    /// three; and "capability access status" is not defined as a value anywhere — not
    /// as `CapError` (an error set, not a value) and not as select.Status (whose five
    /// members are comparison outcomes). Producing any number for `rd` would be an
    /// invention, so this refuses and names the gap. This is the same treatment
    /// cap.load/cap.store receive, and the same class of honesty §3.6's accelerators get.
    ///
    /// Even-index rule: NOT applied here. v1.11 scopes it to cap.load/cap.store only —
    /// `rs1` of cap.check names a descriptor to test, not a pair this instruction forms,
    /// so any register is legal. The assembler already rules the same way.
    fn capCheck(self: *Vm, c: decoding.Cap, pc: u64, word: u64) Fault!Step {
        self.halted = true;
        const base = self.regs.read(c.rs1);
        // §6's diagram: the high register holds permissions in bits[15:8].
        const high: u64 = self.regs.read(c.rs1 +% 1);
        const perms_byte: u8 = @truncate(high >> 8);
        var text: [128]u8 = undefined;
        var w = std.Io.Writer.fixed(&text);
        w.print("base {d}, permission byte {d}, no length field in the pair", .{ base, perms_byte }) catch {};
        return .{ .fault = .{
            .stage = "executing a capability check",
            .word = word,
            .pc = pc,
            .mnemonic = "cap.check",
            .operand = .{ .name = "descriptor register pair", .text = w.buffered() },
            .expected = "a descriptor the contract can describe completely, and a defined address, size and access kind to test it against",
            .detail = "docs/isa-encoding.md §6 defines a descriptor as base, length and permissions, but the register pair has no length field, so the region to test is undefined. The encoding also supplies no address, no size and no access kind, and 'capability access status' is not defined as a value anywhere in the contract. No status was fabricated for rd. This gap is reported rather than guessed; see task-20.",
        } };
    }

    /// §3.7 `thread.spawn`: bit i of the mask starts slot T_i at the address in rs1.
    ///
    /// An EMPTY mask (Amendment 1.1) is legal and starts nothing. It is not an error
    /// and not a fault: it is a well-defined no-op, which is what keeps a disassembled
    /// `operand[7:0] == 0` word readable and re-assemblable.
    fn spawnSlots(self: *Vm, t: decoding.Thread, pc: u64, word: u64) threading.ThreadError!void {
        _ = pc;
        _ = word;
        const entry = self.regs.read(t.rs1);
        const named = slotMask(t.slots);
        for (named.slice()) |index| try self.sched.spawn(index, entry);
    }

    /// §3.7 `thread.join`: bit i of the mask waits for slot T_i.
    /// An empty mask is legal and waits for nothing (Amendment 1.1).
    fn joinSlots(self: *Vm, t: decoding.Thread, pc: u64, word: u64) threading.ThreadError!void {
        _ = pc;
        _ = word;
        const named = slotMask(t.slots);
        for (named.slice()) |index| try self.sched.join(index);
    }

    /// The slot indices a `operand[7:0]` mask names, ascending, as a counted slice.
    ///
    /// The count matters: an EMPTY mask names no slot and must iterate zero times, not
    /// eight. Returning a fixed-size array with unfilled tail entries is what made an
    /// empty mask look like eight bogus slots. Eight is a fixed bound, so no allocation.
    fn slotMask(mask: u8) Slots {
        var s = Slots{};
        var i: u5 = 0;
        while (i < threading.slot_count) : (i += 1) {
            if (mask & (@as(u8, 1) << @intCast(i)) != 0) {
                s.indices[s.len] = @intCast(i);
                s.len += 1;
            }
        }
        return s;
    }

    /// Up to eight slot indices plus how many are actually valid.
    const Slots = struct {
        indices: [threading.slot_count]u4 = @splat(0),
        len: usize = 0,

        fn slice(self: *const Slots) []const u4 {
            return self.indices[0..self.len];
        }
    };

    /// Plain-language thread failure naming the slots and the reason, per §4.2.
    fn reportThreadError(self: *Vm, err: threading.ThreadError, mask: u8, pc: u64, word: u64) Fault!Step {
        self.halted = true;
        // Name the slots the mask actually selected, so the sentence points at the
        // offending operand rather than at the instruction as a whole (§4.2).
        var text: [64]u8 = undefined;
        var w = std.Io.Writer.fixed(&text);
        const named = slotMask(mask);
        if (named.len == 0) {
            w.writeAll("no slots") catch {};
        } else {
            for (named.slice(), 0..) |index, k| {
                if (k != 0) w.writeAll(", ") catch break;
                w.print("T{d}", .{index}) catch break;
            }
        }
        const operand_text = w.buffered();

        return .{ .fault = .{
            .stage = "executing a thread instruction",
            .word = word,
            .pc = pc,
            .operand = .{ .name = "slot mask", .text = operand_text },
            .expected = "a slot mask naming slots that exist and are in the state this operation requires",
            .detail = threading.explain(err),
        } };
    }

    /// A non-control instruction naming PC as its destination is refused instead of
    /// having its result silently overwritten by the fixed-width advance (§4, §7).
    fn reportPcWrite(self: *Vm, mnemonic: []const u8, pc: u64, word: u64) Fault!Step {
        self.halted = true;
        return .{ .fault = .{
            .stage = "executing this instruction",
            .word = word,
            .pc = pc,
            .mnemonic = mnemonic,
            .operand = .{ .name = "destination register", .text = "PC" },
            .expected = "a destination register other than PC, because a non-control instruction cannot write the program counter (docs/isa-encoding.md §4)",
            .detail = "This instruction computed a value for the program counter, but the program counter is advanced by the fixed 8-byte instruction width, so the result would have been discarded without any effect. The write was refused instead of being dropped silently. To transfer control, use jump, call or ret; SP, LR and FLAGS are valid destinations.",
        } };
    }

    fn reportAluError(self: *Vm, err: AluError, a: decoding.Alu, pc: u64, word: u64) Fault!Step {
        self.halted = true;
        const diag: Diagnostic = switch (err) {
            error.DivideByZero => .{
                .stage = "executing a divide",
                .word = word,
                .pc = pc,
                .operand = .{ .index = 2, .name = "divisor", .text = "0" },
                .expected = "a divisor that is not zero",
                .detail = "Celeris-64 reports division by zero as this diagnostic; it does not trap and it does not silently produce a value.",
            },
            error.ReservedWidthEncoding => .{
                .stage = "executing this instruction",
                .word = word,
                .pc = pc,
                .expected = "an operand width of 64, 32, 16 or 8 bits",
                .detail = "Width values between 4 and 15 are reserved by the encoding contract.",
            },
            error.UnknownAluOpcode => .{
                .stage = "executing this instruction",
                .word = word,
                .pc = pc,
                .operand = .{ .name = "opcode", .text = "not in the ALU map" },
                .expected = "an ALU opcode from 0x10 through 0x19",
                .detail = "The decoder produced an ALU instruction with an opcode the ALU does not implement.",
            },
        };
        _ = a;
        return .{ .fault = diag };
    }

    /// Bounds refusals become a sentence naming the address, the base and the length,
    /// and the access is not partially applied (contract P1.2, docs/isa-encoding.md §6).
    fn faultOutOfBounds(self: *Vm, action: []const u8, address: u64, width: u64) Fault {
        self.halted = true;
        const rendered = self.boundsText(action, address, width);
        _ = rendered;
        return error.OutOfBounds;
    }

    /// The last bounds sentence, kept so a caller can print it after `error.OutOfBounds`.
    pub fn boundsText(self: *const Vm, action: []const u8, address: u64, width: u64) memory.BoundsFault {
        return .{
            .action = action,
            .address = address,
            .base = 0,
            .length = self.mem.bytes.len,
            .width = width,
        };
    }
};

// ---------------------------------------------------------------------------
// Encoding helpers
//
// CLS64 words are little-endian and fixed 64-bit (docs/isa-encoding.md §1-§2). These
// helpers let a test express a program in the contract's own bit layout without an
// assembler. Field *extraction* is the decoder's job, not the VM's.
// ---------------------------------------------------------------------------

/// Builds one instruction word from the §2 layout.
pub fn encode(opcode: u8, rd: u4, rs1: u4, operand: u48) u64 {
    return (@as(u64, opcode) << 56) | (@as(u64, rd) << 52) | (@as(u64, rs1) << 48) | operand;
}

/// ALU operand field: `rs2[47:44]`, `width[43:40]`, signed `imm28[39:0]` (§3.1).
///
/// Takes `i64` to match `decoding.Alu.imm: ?i64`. A value the 28-bit field cannot
/// hold is refused rather than truncated, so a mistyped immediate cannot silently
/// encode a different instruction — the exact failure §3.1's sign rule guards against.
pub fn aluOperand(rs2: u4, width: Width, imm28: i64) u48 {
    const imm: i28 = std.math.cast(i28, imm28) orelse
        @panic("aluOperand: immediate does not fit the signed 28-bit field of docs/isa-encoding.md §3.1");
    return (@as(u48, rs2) << 44) | (@as(u48, @intFromEnum(width)) << 40) | @as(u48, @as(u28, @bitCast(imm)));
}

/// Copies a program of 64-bit words into an image at `at`, little-endian.
///
/// All-or-nothing, like the §3.4 stream rule: the whole range is checked before a
/// single byte is written, so a refused load leaves the image byte-for-byte intact.
pub fn loadWords(image: []u8, at: u64, words: []const u64) memory.BoundsError!void {
    var mem = Memory.init(image);
    if (!mem.inBounds(at, words.len * instruction_bytes)) return memory.BoundsError.OutOfBounds;
    for (words, 0..) |word, i| {
        try mem.write64(at + i * instruction_bytes, word);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Allocates an image once per test and loads a program into it.
/// Plain align-1 allocation: memory is byte-addressable (AGENTS.md §2.3), and the
/// returned slice must keep the allocation's own alignment so `free` matches.
fn imageWith(words: []const u64) ![]u8 {
    const bytes = try testing.allocator.alloc(u8, @max(8, words.len * 8) + 64);
    @memset(bytes, 0);
    try loadWords(bytes, 0, words);
    return bytes;
}

test "PC advances by the fixed 64-bit width for straight-line code" {
    const img = try imageWith(&.{
        encode(0x00, 0, 0, 0), // nop
        encode(0x00, 0, 0, 0), // nop
        encode(0x01, 0, 0, 0), // halt
    });
    defer testing.allocator.free(img);

    var vm = Vm.init(img);
    _ = try vm.step();
    try testing.expectEqual(@as(u64, 8), vm.regs.pc);
    _ = try vm.step();
    try testing.expectEqual(@as(u64, 16), vm.regs.pc);

    const halted = try vm.step();
    try testing.expect(halted == .halted);
    try testing.expect(vm.halted);
    try testing.expectEqual(@as(u64, 3), vm.retired);
}

test "jump, call and ret are the only instructions that move PC off the fixed stride" {
    const img = try imageWith(&.{
        encode(0x03, 0, 0, 32), // call 32  -> LR = 8
        encode(0x01, 0, 0, 0), // halt
        encode(0x00, 0, 0, 0),
        encode(0x00, 0, 0, 0),
        encode(0x04, 0, 0, 0), // ret -> PC = LR = 8
        encode(0x02, 0, 0, 40), // jump 40
    });
    defer testing.allocator.free(img);

    var vm = Vm.init(img);
    _ = try vm.step(); // call
    try testing.expectEqual(@as(u64, 32), vm.regs.pc);
    try testing.expectEqual(@as(u64, 8), vm.regs.lr);

    _ = try vm.step(); // ret
    try testing.expectEqual(@as(u64, 8), vm.regs.pc);

    const h = try vm.step(); // halt
    try testing.expect(h == .halted);
}

test "ALU immediate form writes the destination and honours sub-width zero-extension" {
    const img = try imageWith(&.{
        // R0 = 134217727 (mov, full width): the largest value the signed 28-bit
        // immediate field of §3.1 can hold.
        encode(0x19, 0, 0, aluOperand(0, .full, 134217727)),
        // R0.b = 0xAB : must clear the upper bits, observable through a full read
        encode(0x19, 0, 0, aluOperand(0, .b, 0xAB)),
        encode(0x01, 0, 0, 0),
    });
    defer testing.allocator.free(img);

    var vm = Vm.init(img);
    _ = try vm.step();
    try testing.expectEqual(@as(u64, 134217727), vm.regs.read(0));
    _ = try vm.step();
    try testing.expectEqual(@as(u64, 0xAB), vm.regs.read(0));
    try testing.expectEqual(@as(u64, 0), vm.regs.read(0) & 0xFFFF_FFFF_FFFF_FF00);
}

test "a negative imm28 sign-extends to 64 bits end-to-end" {
    const img = try imageWith(&.{
        // imm28 = 0x0800_0000 -> -134217728, whose u64 form is all ones above bit 27.
        encode(0x19, 1, 0, aluOperand(0, .full, -134217728)),
        encode(0x10, 2, 1, aluOperand(0, .full, 0)), // R2 = R1 + 0
        encode(0x01, 0, 0, 0),
    });
    defer testing.allocator.free(img);

    var vm = Vm.init(img);
    _ = try vm.run(10);
    try testing.expectEqual(@as(u64, 0xFFFF_FFFF_F800_0000), vm.regs.read(1));
    try testing.expectEqual(@as(u64, 0xFFFF_FFFF_F800_0000), vm.regs.read(2));
}

test "running the same program twice yields identical register and memory state" {
    const program = [_]u64{
        encode(0x19, 1, 0, aluOperand(0, .full, 7)), // R1 = 7
        encode(0x10, 2, 1, aluOperand(0, .full, 35)), // R2 = R1 + 35
        encode(0x11, 3, 2, aluOperand(0, .full, 2)), // R3 = R2 - 2
        encode(0x12, 4, 3, aluOperand(0, .full, 3)), // R4 = R3 * 3
        encode(0x13, 5, 4, aluOperand(0, .full, 5)), // R5 = R4 / 5
        encode(0x01, 0, 0, 0),
    };

    const first_img = try imageWith(&program);
    defer testing.allocator.free(first_img);
    var a = Vm.init(first_img);
    _ = try a.run(100);

    const second_img = try imageWith(&program);
    defer testing.allocator.free(second_img);
    var b = Vm.init(second_img);
    _ = try b.run(100);

    try testing.expect(a.snapshot().eql(b.snapshot()));
    try testing.expectEqualSlices(u8, first_img, second_img);
    // Hand-derived: R2 = 7+35 = 42, R3 = 42-2 = 40, R4 = 40*3 = 120, R5 = 120/5 = 24.
    try testing.expectEqual(@as(u64, 24), b.regs.read(5));
    try testing.expectEqual(@as(u64, 6), b.retired);
}

test "an unknown opcode produces a diagnostic naming the opcode and the PC, and does not panic" {
    const img = try imageWith(&.{
        encode(0x00, 0, 0, 0),
        encode(0xAB, 0, 0, 0), // 0xAB is not in the opcode map
    });
    defer testing.allocator.free(img);

    var vm = Vm.init(img);
    _ = try vm.step();
    const s = try vm.step();
    try testing.expect(s == .fault);

    var buf: [512]u8 = undefined;
    const text = diagnostics.renderToBuffer(s.fault, &buf);
    try testing.expect(std.mem.indexOf(u8, text, "error:") != null);
    // Names the opcode value and where it was found. The PC lives in the `pc` field,
    // which is not a source line number: a runtime fault has no source text.
    try testing.expect(std.mem.indexOf(u8, text, "opcode") != null);
    try testing.expect(std.mem.indexOf(u8, text, "PC 8") != null);
    try testing.expect(std.mem.indexOf(u8, text, "line 8") == null);
    try testing.expect(!diagnostics.hasBareHexCode(text));
    try testing.expect(vm.halted);
}

test "fetching past the end of memory refuses and does not truncate" {
    const img = try imageWith(&.{encode(0x00, 0, 0, 0)});
    defer testing.allocator.free(img);

    var vm = Vm.init(img);
    vm.regs.pc = img.len; // exactly one past the last valid byte
    try testing.expectError(error.OutOfBounds, vm.step());

    // The refusal is a sentence naming address, base and length, not a bare code.
    var buf: [512]u8 = undefined;
    const text = vm.boundsText("fetching the instruction", vm.regs.pc, 8).render(&buf);
    try testing.expect(std.mem.indexOf(u8, text, "address") != null);
    try testing.expect(std.mem.indexOf(u8, text, "base 0") != null);
    try testing.expect(std.mem.indexOf(u8, text, "byte(s) long") != null);
    try testing.expect(!diagnostics.hasBareHexCode(text));
}

test "a program that never halts stops at the instruction limit instead of hanging" {
    const img = try imageWith(&.{
        encode(0x00, 0, 0, 0),
        encode(0x02, 0, 0, 0), // jump 0: an infinite loop
    });
    defer testing.allocator.free(img);

    var vm = Vm.init(img);
    const d = try vm.run(50);
    try testing.expectEqual(@as(u64, 50), vm.retired);

    var buf: [512]u8 = undefined;
    const text = diagnostics.renderToBuffer(d, &buf);
    try testing.expect(std.mem.indexOf(u8, text, "instruction limit") != null);
}

test "division by zero is a diagnostic, not a trap and not a silent value" {
    const img = try imageWith(&.{
        encode(0x19, 1, 0, aluOperand(0, .full, 0)), // R1 = 0
        encode(0x13, 2, 1, aluOperand(1, .full, 0)), // R2 = R1 / R1
    });
    defer testing.allocator.free(img);

    var vm = Vm.init(img);
    _ = try vm.step();
    const s = try vm.step();
    try testing.expect(s == .fault);
    try testing.expectEqual(@as(u64, 0), vm.regs.read(2)); // nothing was committed

    var buf: [512]u8 = undefined;
    const text = diagnostics.renderToBuffer(s.fault, &buf);
    try testing.expect(std.mem.indexOf(u8, text, "divisor") != null);
    try testing.expect(!diagnostics.hasBareHexCode(text));
}

test "shifts of 64 or more produce zero rather than undefined behaviour" {
    const img = try imageWith(&.{
        encode(0x19, 1, 0, aluOperand(0, .full, 0xFF)), // R1 = 0xFF
        encode(0x17, 2, 1, aluOperand(0, .full, 64)), // R2 = R1 << 64
        encode(0x18, 3, 1, aluOperand(0, .full, 64)), // R3 = R1 >> 64
        encode(0x01, 0, 0, 0),
    });
    defer testing.allocator.free(img);

    var vm = Vm.init(img);
    _ = try vm.run(10);
    try testing.expectEqual(@as(u64, 0), vm.regs.read(2));
    try testing.expectEqual(@as(u64, 0), vm.regs.read(3));
}

test "loadWords refuses a program that does not fit the image" {
    var img: [16]u8 = @splat(0);
    try testing.expectError(error.OutOfBounds, loadWords(&img, 8, &.{ 1, 2, 3 }));
    // Nothing was written by the refused load.
    for (img) |b| try testing.expectEqual(@as(u8, 0), b);
}

/// §3.3 encoding: offset[47:40], width[39:32], src2[31:28].
fn fieldOperand(offset: u8, width: u8, src2: u4) u48 {
    return (@as(u48, offset) << 40) | (@as(u48, width) << 32) | (@as(u48, src2) << 28);
}

test "field.extract pulls the documented bits end-to-end (spec's offset=12 width=3)" {
    const img = try imageWith(&.{
        // R1 = 0xABCD (mov immediate)
        encode(0x19, 1, 0, aluOperand(0, .full, 0xABCD)),
        // R1 = 0xABCD = 0b1010_1011_1100_1101, so bits [14:12] are 0b010 = 2.
        encode(0x30, 0, 1, fieldOperand(12, 3, 0)),
        encode(0x01, 0, 0, 0),
    });
    defer testing.allocator.free(img);

    var vm = Vm.init(img);
    _ = try vm.run(10);
    try testing.expectEqual(@as(u64, 0x2), vm.regs.read(0));
}

test "field.insert round-trips a non-power-of-two value and leaves other bits alone" {
    const img = try imageWith(&.{
        encode(0x19, 1, 0, aluOperand(0, .full, 0xFFFF)), // R1 = 0xFFFF (base)
        encode(0x19, 2, 0, aluOperand(0, .full, 0x5)), // R2 = 0b101 (a U3 value)
        encode(0x31, 3, 1, fieldOperand(12, 3, 2)), // R3 = R1 with U3 at bit 12
        encode(0x30, 4, 3, fieldOperand(12, 3, 0)), // R4 = extract it back
        encode(0x01, 0, 0, 0),
    });
    defer testing.allocator.free(img);

    var vm = Vm.init(img);
    _ = try vm.run(10);
    // 0xFFFF = 0b1111_1111_1111_1111; bits [14:12] become 101 -> 0b1101_1111_1111_1111.
    try testing.expectEqual(@as(u64, 0xDFFF), vm.regs.read(3));
    try testing.expectEqual(@as(u64, 0x5), vm.regs.read(4));
}

test "field constraints produce diagnostics rather than silent wraps (spec 3.3.1)" {
    // width == 0 is a diagnostic error, not a zero result.
    const zero_width = try imageWith(&.{
        encode(0x19, 1, 0, aluOperand(0, .full, 0xFF)),
        encode(0x30, 0, 1, fieldOperand(12, 0, 0)),
    });
    defer testing.allocator.free(zero_width);
    var a = Vm.init(zero_width);
    _ = try a.step();
    const s0 = try a.step();
    try testing.expect(s0 == .fault);
    // Nothing was committed to the destination.
    try testing.expectEqual(@as(u64, 0), a.regs.read(0));

    // offset + width > 64 is a diagnostic error, not a wrap.
    const over = try imageWith(&.{
        encode(0x19, 1, 0, aluOperand(0, .full, 0xFF)),
        encode(0x30, 0, 1, fieldOperand(60, 8, 0)),
    });
    defer testing.allocator.free(over);
    var b = Vm.init(over);
    _ = try b.step();
    const s1 = try b.step();
    try testing.expect(s1 == .fault);

    var buf: [512]u8 = undefined;
    const text = diagnostics.renderToBuffer(s1.fault, &buf);
    // F24: the decoder now rejects this word before the VM ever sees it, so the
    // sentence comes from the decode-time diagnostic. It still states the rule,
    // in words rather than symbols — §7 forbids a bare hex code, not prose.
    try testing.expect(std.mem.indexOf(u8, text, "sum is at most 64 bits") != null);
    try testing.expect(std.mem.indexOf(u8, text, "3.3.1") != null);
    try testing.expect(!diagnostics.hasBareHexCode(text));
}

/// §3.2.2 select encoding: match[47:44], trueReg[43:40], falseReg[39:36].
fn selectOperand(match_val: u4, true_reg: u4, false_reg: u4) u48 {
    return (@as(u48, match_val) << 44) | (@as(u48, true_reg) << 40) | (@as(u48, false_reg) << 36);
}

/// §3.4 stream encoding: rs2[47:44], chunk[43:24], width[23:20].
fn streamOperand(rs2: u4, chunk: u20, width: Width) u48 {
    return (@as(u48, rs2) << 44) | (@as(u48, chunk) << 24) | (@as(u48, @intFromEnum(width)) << 20);
}

test "compare produces the explicit status enum, and select picks the arm without branching" {
    const img = try imageWith(&.{
        encode(0x19, 1, 0, aluOperand(0, .full, 5)), // R1 = 5
        encode(0x19, 2, 0, aluOperand(0, .full, 9)), // R2 = 9
        encode(0x20, 3, 1, aluOperand(2, .full, 0)), // R3 = status(R1 vs R2) = LESS (1)
        encode(0x19, 4, 0, aluOperand(0, .full, 0xAA)), // R4 = true arm
        encode(0x19, 5, 0, aluOperand(0, .full, 0xBB)), // R5 = false arm
        encode(0x21, 6, 3, selectOperand(1, 4, 5)), // R6 = (R3 == LESS) ? R4 : R5
        encode(0x21, 7, 3, selectOperand(0, 4, 5)), // R7 = (R3 == EQUAL) ? R4 : R5
        encode(0x01, 0, 0, 0),
    });
    defer testing.allocator.free(img);

    var vm = Vm.init(img);
    _ = try vm.run(50);
    try testing.expectEqual(@as(u64, 1), vm.regs.read(3)); // LESS, not a bare boolean
    try testing.expectEqual(@as(u64, 0xAA), vm.regs.read(6)); // matching arm
    try testing.expectEqual(@as(u64, 0xBB), vm.regs.read(7)); // non-matching arm
    // PC advanced by the fixed stride throughout: no branch was taken for either
    // select. halt is the 8th word and stops without advancing, so PC stays at 56.
    try testing.expectEqual(@as(u64, 7 * 8), vm.regs.pc);
}

test "select on a register that is not a status enum faults instead of picking an arm" {
    const img = try imageWith(&.{
        encode(0x19, 1, 0, aluOperand(0, .full, 99)), // R1 = 99, not a status value
        encode(0x21, 2, 1, selectOperand(0, 0, 0)),
    });
    defer testing.allocator.free(img);

    var vm = Vm.init(img);
    _ = try vm.step();
    const s = try vm.step();
    try testing.expect(s == .fault);
    try testing.expectEqual(@as(u64, 0), vm.regs.read(2)); // no arm was committed
}

test "stream.fill writes the chunk and auto-advances the pointer by chunk * elementSize" {
    const img = try imageWith(&.{
        // Data starts at 64, past the four instruction words (0..32).
        encode(0x19, 1, 0, aluOperand(0, .full, 64)), // R1 = 64 -> pointer
        encode(0x19, 0, 0, aluOperand(0, .full, 0x2A)), // R0 = fill value
        encode(0x42, 0, 1, streamOperand(0, 4, .l)), // stream.fill R0, [R1]+4, width .l
        encode(0x01, 0, 0, 0),
    });
    defer testing.allocator.free(img);

    var vm = Vm.init(img);
    _ = try vm.run(10);
    // 4 elements of 4 bytes = 16 bytes written, pointer advanced by 16.
    try testing.expectEqual(@as(u64, 80), vm.regs.read(1));
    try testing.expectEqual(@as(u32, 0x2A), try vm.mem.read32(64));
    try testing.expectEqual(@as(u32, 0x2A), try vm.mem.read32(76));
}

test "STREAM ATOMICITY end-to-end: a chunk overrunning memory modifies zero bytes" {
    const img = try imageWith(&.{
        encode(0x19, 1, 0, aluOperand(0, .full, 0)), // R1 = 0
        encode(0x19, 0, 0, aluOperand(0, .full, 0xFF)),
        // chunk of 1_000_000 64-bit elements cannot fit any image.
        encode(0x42, 0, 1, streamOperand(0, 1_000_000, .full)),
    });
    defer testing.allocator.free(img);

    const before = try testing.allocator.dupe(u8, img);
    defer testing.allocator.free(before);

    var vm = Vm.init(img);
    _ = try vm.step();
    _ = try vm.step();
    const s = try vm.step();
    try testing.expect(s == .fault);

    // Byte-for-byte: a partial application would show up here.
    try testing.expectEqualSlices(u8, before, img);
    // The refused operation must not have advanced the pointer either.
    try testing.expectEqual(@as(u64, 0), vm.regs.read(1));

    var buf: [512]u8 = undefined;
    const text = diagnostics.renderToBuffer(s.fault, &buf);
    try testing.expect(!diagnostics.hasBareHexCode(text));
}

test "stream.add is the fused load/add/store the architecture headlines" {
    const img = try imageWith(&.{
        // Data lives at 64, past the four instruction words (0..32).
        encode(0x19, 1, 0, aluOperand(0, .full, 64)), // pointer R1 = 64
        encode(0x19, 2, 0, aluOperand(0, .full, 3)), // offset R2 = 3
        encode(0x40, 0, 1, streamOperand(2, 2, .l)), // stream.add R0, [R1]+2, R2
        encode(0x01, 0, 0, 0),
    });
    defer testing.allocator.free(img);

    vm_load32(img, 64, 100);
    vm_load32(img, 68, 200);

    var vm = Vm.init(img);
    _ = try vm.run(10);
    try testing.expectEqual(@as(u32, 103), try vm.mem.read32(64));
    try testing.expectEqual(@as(u32, 203), try vm.mem.read32(68));
    try testing.expectEqual(@as(u64, 72), vm.regs.read(1)); // 64 + 2 * 4
}

fn vm_load32(img: []u8, at: u64, value: u32) void {
    var mem = Memory.init(img);
    mem.write32(at, value) catch unreachable;

}

test "stream.setp applies the signed 40-bit stride to the pointer register" {
    const img = try imageWith(&.{
        encode(0x19, 1, 0, aluOperand(0, .full, 64)), // R1 = 64
        // F19: `setp` names its pointer with `rd` (here R1) and carries nothing
        // in `rs1`, which must be zero — a non-zero value is now rejected.
        // §3.4: the stride occupies operand[39:0] ONLY, and [47:40] is reserved.
        // The old fixture wrote @bitCast(@as(i48, -16)), which sign-extends into
        // [47:40] and produces operand 0xFFFFFFFFFFF0 — a word the contract
        // reserves and the assembler never emits. Masked to 40 bits, matching
        // what `stream.setp R1, -16` actually assembles to.
        encode(0x43, 1, 0, @as(u48, @as(u40, @bitCast(@as(i40, -16))))), // setp R1, stride -16
        encode(0x01, 0, 0, 0),
    });
    defer testing.allocator.free(img);

    var vm = Vm.init(img);
    _ = try vm.run(10);
    try testing.expectEqual(@as(u64, 48), vm.regs.read(1));
}

test "an ALU write to PC faults instead of being silently discarded (VM half of F8)" {
    // A hand-encoded word, because the assembler now rejects this at assembly time:
    // a loaded binary blob must not be silently discarded either.
    const img = try imageWith(&.{
        encode(0x19, 1, 0, aluOperand(0, .full, 100)), // R1 = 100
        encode(0x19, 2, 0, aluOperand(0, .full, 5)), // R2 = 5
        encode(0x10, 14, 1, aluOperand(2, .full, 0)), // add PC, R1, R2  <- rd index 14
        encode(0x01, 0, 0, 0),
    });
    defer testing.allocator.free(img);

    var vm = Vm.init(img);
    _ = try vm.step();
    _ = try vm.step();
    const s = try vm.step();

    // Before the fix this returned .advanced with PC = 24 (the normal stride) and the
    // computed 105 was thrown away with no signal at all.
    try testing.expect(s == .fault);

    var buf: [1024]u8 = undefined;
    const text = diagnostics.renderToBuffer(s.fault, &buf);
    try testing.expect(std.mem.indexOf(u8, text, "error:") != null);
    try testing.expect(std.mem.indexOf(u8, text, "PC") != null);
    try testing.expect(std.mem.indexOf(u8, text, "destination register") != null);
    try testing.expect(std.mem.indexOf(u8, text, "jump, call or ret") != null);
    try testing.expect(std.mem.indexOf(u8, text, "PC 16") != null);
    try testing.expect(!diagnostics.hasBareHexCode(text));
    try testing.expect(vm.halted);
}

test "PC as the destination faults for every non-control instruction that writes rd" {
    const cases = [_]struct { op: u8, operand: u48 }{
        .{ .op = 0x10, .operand = aluOperand(2, .full, 0) }, // add PC, R1, R2
        .{ .op = 0x12, .operand = aluOperand(2, .full, 0) }, // mul PC, R1, R2
        .{ .op = 0x19, .operand = aluOperand(0, .full, 7) }, // mov PC, 7
        .{ .op = 0x20, .operand = aluOperand(2, .full, 0) }, // compare PC, R1, R2
        .{ .op = 0x21, .operand = selectOperand(1, 0, 0) }, // select PC, R1, [LESS], R0, R0
        .{ .op = 0x30, .operand = fieldOperand(12, 3, 0) }, // field.extract PC, R1, 12, 3
    };
    for (cases) |c| {
        const img = try imageWith(&.{
            encode(0x19, 1, 0, aluOperand(0, .full, 100)),
            encode(0x19, 2, 0, aluOperand(0, .full, 5)),
            encode(c.op, 14, 1, c.operand),
        });
        defer testing.allocator.free(img);

        var vm = Vm.init(img);
        _ = try vm.step();
        _ = try vm.step();
        const s = try vm.step();
        try testing.expect(s == .fault);
        // The refused instruction must not have moved PC off the faulting word.
        try testing.expectEqual(@as(u64, 16), vm.regs.pc);
    }
}

test "REGRESSION: SP, LR and FLAGS are legal destinations and still execute normally" {
    // §4: indices 12, 13 and 15 are legal in rd. The PC guard must not over-reach.
    const img = try imageWith(&.{
        encode(0x19, 1, 0, aluOperand(0, .full, 100)), // R1 = 100
        encode(0x19, 2, 0, aluOperand(0, .full, 5)), // R2 = 5
        encode(0x10, 12, 1, aluOperand(2, .full, 0)), // add SP, R1, R2   -> 105
        encode(0x19, 13, 0, aluOperand(0, .full, 7)), // mov LR, 7
        encode(0x10, 15, 1, aluOperand(2, .full, 0)), // add FLAGS, R1, R2 -> 105
        encode(0x19, 12, 0, aluOperand(0, .full, 1)), // mov SP, 1 (overwrite)
        encode(0x01, 0, 0, 0),
    });
    defer testing.allocator.free(img);

    var vm = Vm.init(img);
    const d = try vm.run(20);
    _ = d; // halt
    try testing.expectEqual(@as(u64, 1), vm.regs.sp);
    try testing.expectEqual(@as(u64, 7), vm.regs.lr);
    try testing.expectEqual(@as(u64, 105), vm.regs.flags);
    // Straight-line: 6 executed instructions advanced PC to 48, then halt stopped it.
    try testing.expectEqual(@as(u64, 48), vm.regs.pc);
}

test "REGRESSION: PC as a source operand is rejected at decode (F27)" {
    // This test previously asserted the OPPOSITE, citing "§4 says PC is readable".
    // §4's table does say "readable", but the paragraph beneath it is explicit:
    // "in rs1/rs2 it is legal for SP, LR and FLAGS and a diagnostic error for PC",
    // and the assembler has always refused `add R0, PC, R1`. The decoder accepted
    // it, so `run-bin` executed a word no source line can express — F27, the same
    // two-layer gap as F8. The contract was clarified rather than the behaviour
    // relaxed, so this test now pins the rejection.
    //
    // SP (12), LR (13) and FLAGS (15) remain legal sources; only PC (14) is not.
    const img = try imageWith(&.{
        encode(0x00, 0, 0, 0), // nop -> PC 8
        // R0 = R1(0) + PC ; rs1 = PC (14), rs2 = 1, imm = 0 -> register form
        encode(0x10, 0, 14, aluOperand(1, .full, 0)),
        encode(0x01, 0, 0, 0),
    });
    defer testing.allocator.free(img);

    // The word must not decode at all: the decoder is the layer that sees a blob.
    try testing.expect(decoding.decode(encode(0x10, 0, 14, aluOperand(1, .full, 0))) == .err);

    // And the legal sources still decode, so the check is not over-broad.
    try testing.expect(decoding.decode(encode(0x10, 0, 12, aluOperand(1, .full, 0))) == .ok);
    try testing.expect(decoding.decode(encode(0x10, 0, 13, aluOperand(1, .full, 0))) == .ok);
    try testing.expect(decoding.decode(encode(0x10, 0, 15, aluOperand(1, .full, 0))) == .ok);
}

test "REGRESSION: jump, call and ret still set PC deliberately and are never clobbered" {
    const img = try imageWith(&.{
        encode(0x03, 0, 0, 32), // call 32 -> LR = 8 (address of the NEXT instruction)
        encode(0x01, 0, 0, 0), // halt
        encode(0x00, 0, 0, 0),
        encode(0x00, 0, 0, 0),
        encode(0x04, 0, 0, 0), // ret -> PC = LR = 8
        encode(0x02, 0, 0, 40), // jump 40
    });
    defer testing.allocator.free(img);

    var vm = Vm.init(img);
    _ = try vm.step(); // call
    try testing.expectEqual(@as(u64, 32), vm.regs.pc); // target, NOT the stride
    try testing.expectEqual(@as(u64, 8), vm.regs.lr); // address of the next instruction

    _ = try vm.step(); // ret
    try testing.expectEqual(@as(u64, 8), vm.regs.pc);

    const h = try vm.step(); // halt
    try testing.expect(h == .halted);
}

test "REGRESSION: the fixed 8-byte advance still holds for straight-line code" {
    const img = try imageWith(&.{
        encode(0x00, 0, 0, 0), // nop
        encode(0x19, 1, 0, aluOperand(0, .full, 1)), // mov R1, 1
        encode(0x01, 0, 0, 0), // halt
    });
    defer testing.allocator.free(img);

    var vm = Vm.init(img);
    _ = try vm.step();
    try testing.expectEqual(@as(u64, 8), vm.regs.pc);
    _ = try vm.step();
    try testing.expectEqual(@as(u64, 16), vm.regs.pc);
}

/// §3.7 encoding: `operand[7:0]` is the slot bitmask, `operand[47:8]` reserved zero.
fn threadOperand(slot_mask: u8) u48 {
    return @as(u48, slot_mask);
}

test "thread.spawn starts the named slots at rs1 and an EMPTY mask is a legal no-op" {
    const img = try imageWith(&.{
        encode(0x19, 1, 0, aluOperand(0, .full, 64)), // R1 = 64
        encode(0x90, 0, 1, threadOperand(0b0000_0101)), // spawn T0 and T2 at 64
        encode(0x01, 0, 0, 0),
    });
    defer testing.allocator.free(img);

    var vm = Vm.init(img);
    _ = try vm.run(10);
    try testing.expectEqual(@as(usize, 2), vm.sched.activeCount());
    try testing.expectEqual(threading.SlotState.running, vm.sched.slots[0].state);
    try testing.expectEqual(threading.SlotState.idle, vm.sched.slots[1].state);
    try testing.expectEqual(threading.SlotState.running, vm.sched.slots[2].state);
    try testing.expectEqual(@as(u64, 64), vm.sched.slots[0].entry);
    try testing.expectEqual(@as(u64, 64), vm.sched.slots[2].entry);

    // Amendment 1.1: mask 0 names no slot. It is legal, starts nothing, and does NOT
    // fault. Before the slot-count fix it wrongly started eight bogus slots.
    const empty = try imageWith(&.{
        encode(0x19, 1, 0, aluOperand(0, .full, 64)),
        encode(0x90, 0, 1, threadOperand(0)),
        encode(0x01, 0, 0, 0),
    });
    defer testing.allocator.free(empty);

    var e = Vm.init(empty);
    const d = try e.run(10);
    _ = d; // halt, not a fault
    try testing.expectEqual(@as(usize, 0), e.sched.activeCount());
    try testing.expect(!e.halted or e.sched.activeCount() == 0);
}

test "thread.join finishes the named slots and faults in plain language on an idle one" {
    const img = try imageWith(&.{
        encode(0x19, 1, 0, aluOperand(0, .full, 32)),
        encode(0x90, 0, 1, threadOperand(0b0000_0011)), // spawn T0, T1
        encode(0x91, 0, 0, threadOperand(0b0000_0001)), // join T0
        encode(0x91, 0, 0, threadOperand(0)), // join no slots: legal no-op
        encode(0x01, 0, 0, 0),
    });
    defer testing.allocator.free(img);

    var vm = Vm.init(img);
    _ = try vm.run(10);
    try testing.expectEqual(threading.SlotState.finished, vm.sched.slots[0].state);
    try testing.expectEqual(threading.SlotState.running, vm.sched.slots[1].state);
    try testing.expectEqual(@as(usize, 1), vm.sched.activeCount());

    // Joining a slot that was never started is a fault naming the slot, not a silent
    // no-op and not a bare code.
    const bad = try imageWith(&.{
        encode(0x91, 0, 0, threadOperand(0b0000_0100)), // join T2, never started
    });
    defer testing.allocator.free(bad);

    var b = Vm.init(bad);
    const s = try b.step();
    try testing.expect(s == .fault);
    var buf: [1024]u8 = undefined;
    const text = diagnostics.renderToBuffer(s.fault, &buf);
    try testing.expect(std.mem.indexOf(u8, text, "T2") != null);
    try testing.expect(std.mem.indexOf(u8, text, "not running") != null);
    try testing.expect(!diagnostics.hasBareHexCode(text));
}

test "thread.yield with no runnable slot faults instead of silently advancing" {
    const img = try imageWith(&.{
        encode(0x92, 0, 0, 0), // yield with nothing running
    });
    defer testing.allocator.free(img);

    var vm = Vm.init(img);
    const s = try vm.step();
    try testing.expect(s == .fault);
    try testing.expectEqual(@as(u64, 0), vm.regs.pc); // did not advance

    var buf: [1024]u8 = undefined;
    const text = diagnostics.renderToBuffer(s.fault, &buf);
    try testing.expect(std.mem.indexOf(u8, text, "nothing to switch to") != null);
    try testing.expect(std.mem.indexOf(u8, text, "deterministic modelled interleave") != null);
    try testing.expect(!diagnostics.hasBareHexCode(text));
}

test "thread.yield dispatches deterministically round-robin over the running slots" {
    const program = [_]u64{
        encode(0x19, 1, 0, aluOperand(0, .full, 64)),
        encode(0x90, 0, 1, threadOperand(0b0000_0101)), // spawn T0, T2
        encode(0x92, 0, 0, 0), // yield -> T0
        encode(0x92, 0, 0, 0), // yield -> T2
        encode(0x92, 0, 0, 0), // yield -> T0 again (wraps)
        encode(0x01, 0, 0, 0),
    };
    const img = try imageWith(&program);
    defer testing.allocator.free(img);

    var vm = Vm.init(img);
    _ = try vm.run(20);
    try testing.expectEqual(@as(u64, 3), vm.sched.dispatches);
    try testing.expectEqual(@as(u4, 0), vm.sched.last_dispatched.?);

    // Determinism: the same program twice gives identical thread-scheduler state.
    const img2 = try imageWith(&program);
    defer testing.allocator.free(img2);
    var vm2 = Vm.init(img2);
    _ = try vm2.run(20);
    try testing.expectEqual(vm.sched.dispatches, vm2.sched.dispatches);
    try testing.expectEqual(vm.sched.last_dispatched, vm2.sched.last_dispatched);
    try testing.expectEqual(vm.sched.activeCount(), vm2.sched.activeCount());
}

test "thread instructions do not disturb SP, LR, FLAGS or the fixed PC advance" {
    const img = try imageWith(&.{
        encode(0x19, 1, 0, aluOperand(0, .full, 100)), // R1 = 100
        encode(0x10, 12, 1, aluOperand(0, .full, 5)), // add SP, R1, 5
        encode(0x19, 13, 0, aluOperand(0, .full, 7)), // mov LR, 7
        encode(0x90, 0, 1, threadOperand(0b1000_0001)), // spawn T0, T7
        encode(0x01, 0, 0, 0),
    });
    defer testing.allocator.free(img);

    var vm = Vm.init(img);
    _ = try vm.run(10);
    try testing.expectEqual(@as(u64, 105), vm.regs.sp);
    try testing.expectEqual(@as(u64, 7), vm.regs.lr);
    // Derivation: mov@0, add SP@8, mov LR@16, thread.spawn@24, halt@32.
    // halt is executed but does not advance, so PC stays at 32.
    try testing.expectEqual(@as(u64, 32), vm.regs.pc);
    try testing.expectEqual(@as(usize, 2), vm.sched.activeCount());
}

test "thread slot failures are plain sentences naming the slots, never bare codes" {
    const buf: [1024]u8 = undefined;
    _ = buf;
    const errs = [_]threading.ThreadError{
        error.NoSuchSlot,
        error.SlotAlreadyActive,
        error.SlotNotActive,
    };
    for (errs) |e| {
        const text = threading.explain(e);
        try testing.expect(text.len > 0);
        try testing.expect(std.mem.indexOf(u8, text, "0x") == null);
        try testing.expect(std.ascii.isUpper(text[0]));
    }
}

test "the reserved thread field is rejected by the decoder, not silently ignored" {
    // §3.7: operand[47:8] must be zero. The decoder owns that rule; this records that
    // it holds, so a loaded blob cannot smuggle a non-zero reserved field past the VM.
    const img = try imageWith(&.{
        encode(0x90, 0, 1, (@as(u48, 1) << 8) | 0b1), // spawn with reserved bit set
    });
    defer testing.allocator.free(img);

    var vm = Vm.init(img);
    const s = try vm.step();
    try testing.expect(s == .fault);
    var buf: [1024]u8 = undefined;
    const text = diagnostics.renderToBuffer(s.fault, &buf);
    try testing.expect(!diagnostics.hasBareHexCode(text));
}

test "cap.load and cap.store REFUSE loudly, naming the undefined address source" {
    // v1.11: decode-only this revision. Both must refuse, never guess, never return 0.
    const cases = [_]struct { op: u8, mnemonic: []const u8 }{
        .{ .op = 0x50, .mnemonic = "cap.load" },
        .{ .op = 0x51, .mnemonic = "cap.store" },
    };
    for (cases) |c| {
        const img = try imageWith(&.{
            encode(c.op, 2, 4, 0), // even pair, so the even-index rule is satisfied
        });
        defer testing.allocator.free(img);

        var vm = Vm.init(img);
        const s = try vm.step();
        try testing.expect(s == .fault);

        var buf: [1024]u8 = undefined;
        const text = diagnostics.renderToBuffer(s.fault, &buf);
        _ = c.mnemonic; // the word is named, not the mnemonic: assert what is rendered
        try testing.expect(std.mem.indexOf(u8, text, "no address field") != null);
        try testing.expect(std.mem.indexOf(u8, text, "refused") != null);
        try testing.expect(std.mem.indexOf(u8, text, "does not execute until a revision") != null);
        try testing.expect(!diagnostics.hasBareHexCode(text));
        // Nothing was written to the destination register: no fabricated value.
        try testing.expectEqual(@as(u64, 0), vm.regs.read(2));
        try testing.expect(vm.halted);
    }
}

test "cap.load with an ODD pair index is also refused, not silently rounded" {
    // v1.11 even-index rule: an odd low index would overlap two descriptors. The
    // decoder owns the field layout, so the VM reports it as the same loud refusal.
    const img = try imageWith(&.{
        encode(0x50, 3, 4, 0), // rd = 3, odd
    });
    defer testing.allocator.free(img);

    var vm = Vm.init(img);
    const s = try vm.step();
    try testing.expect(s == .fault);
    // rd must not have been rounded down to 2; neither register was touched.
    try testing.expectEqual(@as(u64, 0), vm.regs.read(2));
    try testing.expectEqual(@as(u64, 0), vm.regs.read(3));
}

test "cap.check refuses and states the gap instead of fabricating a status" {
    // REPORTED GAP (task-20): §6's descriptor is base + length + perms, but the
    // register pair carries no length, so the region to test is undefined; and the
    // encoding supplies no address, no size and no access kind. No status is invented.
    const img = try imageWith(&.{
        encode(0x19, 4, 0, aluOperand(0, .full, 0x1000)), // R4 = base
        encode(0x19, 5, 0, aluOperand(0, .full, 0x0007)), // R5 = perms in bits[15:8]
        encode(0x52, 0, 4, 0), // cap.check R0, R4
    });
    defer testing.allocator.free(img);

    var vm = Vm.init(img);
    _ = try vm.step();
    _ = try vm.step();
    const s = try vm.step();
    try testing.expect(s == .fault);

    var buf: [1024]u8 = undefined;
    const text = diagnostics.renderToBuffer(s.fault, &buf);
    // The diagnostic names the instruction word and the PC, not the mnemonic.
    try testing.expect(std.mem.indexOf(u8, text, "PC 16") != null);
    // Names the descriptor it read (R4 = 0x1000, R5's perms byte = 0), and states why
    // no status was produced.
    try testing.expect(std.mem.indexOf(u8, text, "base 4096, permission byte 0, no length field in the pair") != null);
    try testing.expect(std.mem.indexOf(u8, text, "no length field") != null);
    try testing.expect(std.mem.indexOf(u8, text, "not defined as a value anywhere in the contract") != null);
    try testing.expect(std.mem.indexOf(u8, text, "No status was fabricated") != null);
    try testing.expect(!diagnostics.hasBareHexCode(text));
    // rd was NOT written: the old silent behaviour would have left 0 here, and a
    // fabricated status would also land here. Nothing was committed.
    try testing.expectEqual(@as(u64, 0), vm.regs.read(0));
    try testing.expect(vm.halted);
}

test "the even-index rule does NOT apply to cap.check (v1.11 scopes it to load/store)" {
    // v1.11: rs1 of cap.check names a descriptor to TEST, not a pair it forms, so an
    // odd index is legal. It must not be rejected for that reason; it refuses for the
    // reported gap instead, and the sentence must not claim an even-index violation.
    const img = try imageWith(&.{
        encode(0x52, 0, 5, 0), // rs1 = 5, odd
    });
    defer testing.allocator.free(img);

    var vm = Vm.init(img);
    const s = try vm.step();
    try testing.expect(s == .fault);
    var buf: [1024]u8 = undefined;
    const text = diagnostics.renderToBuffer(s.fault, &buf);
    try testing.expect(std.mem.indexOf(u8, text, "even") == null);
}

test "capability model round-trips through the VM's re-export and is not cryptographic" {
    // The re-export exists so tests/vm_tests.zig can reach capability.zig through the
    // module root. Sanity-check the model the VM will use when the gap is closed.
    const cap = try capability.Capability.init(0x1000, 0x100, capability.Perms.all());
    try testing.expect(cap.covers(0x1000, 1));
    try testing.expect(cap.covers(0x10FF, 1));
    try testing.expect(!cap.covers(0x1100, 1)); // one past the top
    try testing.expect(!cap.covers(0x0FFF, 1)); // one below the base
    try testing.expectEqual(@as(u64, 0x1100), cap.top());
    // A narrower child can never exceed its parent: the property worth modelling.
    const child = try cap.narrow(0x20, 0x10, capability.Perms.all());
    try testing.expectEqual(@as(u64, 0x1020), child.base);
    try testing.expectEqual(@as(u64, 0x10), child.length);
}

test "v1.17: a real loop, using branch and load, computes the right answer" {
    // The ISA could not express a loop before v1.17: every control transfer was
    // unconditional. This test is the end-to-end proof that it can now, using the
    // three new instructions together — `compare` produces the status enum,
    // `branch` tests it, `load` fetches an element.
    //
    //   sum = 0; i = 0; ptr = data
    //   loop: if (i == count) goto done
    //         sum += *ptr; ptr += 8; i += 1; goto loop
    //   done: halt
    const data = [_]u64{ 5, 10, 15, 20, 25, 30, 35, 40 };
    const base: u64 = 4096;
    const count: u64 = 8;
    const expected_sum: u64 = 180;

    const words = [_]u64{
        encode(0x19, 1, 0, aluOperand(0, .full, base)), // R1 = ptr
        encode(0x19, 2, 0, aluOperand(0, .full, 0)), // R2 = sum
        encode(0x19, 3, 0, aluOperand(0, .full, count)), // R3 = count
        encode(0x19, 4, 0, aluOperand(0, .full, 0)), // R4 = i
        // compare R4, R3 -> R5   (status enum into R5)
        encode(0x20, 5, 4, aluOperand(3, .full, 0)),
        // branch R5, [EQUAL], +48 -> halt
        branchWord(5, 0, 48),
        // load R6, [R1+0]
        memWord(0x1A, 6, 1, 0, 0, 0),
        encode(0x10, 2, 2, aluOperand(6, .full, 0)), // add R2, R2, R6
        encode(0x10, 1, 1, aluOperand(0, .full, 8)), // add R1, R1, 8
        encode(0x10, 4, 4, aluOperand(0, .full, 1)), // add R4, R4, 1
        encode(0x02, 0, 0, 32), // jump 32 (back to the compare)
        encode(0x01, 0, 0, 0), // halt
    };

    const img = try testing.allocator.alloc(u8, base + 128);
    defer testing.allocator.free(img);
    @memset(img, 0);
    try loadWords(img, 0, &words);
    for (data, 0..) |v, i| {
        std.mem.writeInt(u64, img[@intCast(base + i * 8)..][0..8], v, .little);
    }

    var vm = Vm.init(img);
    _ = try vm.run(10_000);
    try testing.expect(vm.halted);
    try testing.expectEqual(expected_sum, vm.regs.read(2)); // the sum
    try testing.expectEqual(count, vm.regs.read(4)); // iterations completed
}

/// §3.0.1 `branch` word: rs1 = status register, rs2 = match value,
/// offset[27:0] = signed byte displacement.
fn branchWord(rs1: u4, match: u4, offset: i64) u64 {
    const raw: u28 = @truncate(@as(u64, @bitCast(offset)));
    return (@as(u64, 0x05) << 56) | (@as(u64, rs1) << 48) |
        (@as(u64, match) << 44) | raw;
}

/// §3.1.1 `load`/`store` word: rs2 = source (store only), width[43:40],
/// offset[27:0].
fn memWord(op: u8, rd: u4, rs1: u4, rs2: u4, width: u4, offset: i64) u64 {
    const raw: u28 = @truncate(@as(u64, @bitCast(offset)));
    return (@as(u64, op) << 56) | (@as(u64, rd) << 52) | (@as(u64, rs1) << 48) |
        (@as(u64, rs2) << 44) | (@as(u64, width) << 40) | raw;
}
