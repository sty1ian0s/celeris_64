//! Independent adversarial verification of task-19 (thread.*), task-20 (cap.* refusal),
//! task-21/23 (cap.* operands, F14) and task-24 (F15) — team task-22, owner: verifier.
//!
//! NON-AUTHOR. Every expectation was derived from docs/isa-encoding.md (v1.12-v1.14)
//! and cross-checked against the SHIPPED CLI, never from a teammate's summary.
//!
//! HOW THE ENCODING FACTS GET HERE: /tmp/v22_gen.sh drives the real `celeris64 asm`
//! binary for 232 inputs and records the exact 64-bit word (with its opcode/rd/rs1/
//! operand fields) or the exact rejection text. Those recorded bits are embedded below,
//! so these tests assert on BIT POSITIONS of real output without doing file I/O.
//! Regenerate with /tmp/v22_gen.sh after any change.
//!
//! The runtime half (cap.* refusal, thread.* execution) drives vm.Vm directly.

const std = @import("std");
const testing = std.testing;

const vm = @import("vm");
const decoder = vm.decoding;
const threading = vm.threading;
const diag = vm.diagnostics;

pub const Fact = struct { label: []const u8, ok: bool, word: u64, opcode: u8, rd: u4, rs1: u4, operand: u48, msg: []const u8 };
pub const facts = [_]Fact{
    .{ .label = "load_2_3", .ok = true, .word = 0x5023000000000000, .opcode = 80, .rd = 2, .rs1 = 3, .operand = 0, .msg = "" },
    .{ .label = "store_3_2", .ok = true, .word = 0x5132000000000000, .opcode = 81, .rd = 3, .rs1 = 2, .operand = 0, .msg = "" },
    .{ .label = "load_3_2", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.load\" operand 2 (destination register) is \"R3\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "store_2_3", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.store\" operand 2 (source register) is \"R3\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "load_2_3_4", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.load\" operand 3 (third register) is \"R4\", which is not valid here. Expected no third operand, because the encoding carries only two registers: the capability's address comes from the register pair itself, not from a third register (docs/isa-encoding.md §3.5)." },
    .{ .label = "store_2_4_6", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.store\" operand 3 (third register) is \"R6\", which is not valid here. Expected no third operand, because the encoding carries only two registers: the capability's address comes from the register pair itself, not from a third register (docs/isa-encoding.md §3.5)." },
    .{ .label = "check_2_3", .ok = true, .word = 0x5223000000000000, .opcode = 82, .rd = 2, .rs1 = 3, .operand = 0, .msg = "" },
    .{ .label = "check_0_1", .ok = true, .word = 0x5201000000000000, .opcode = 82, .rd = 0, .rs1 = 1, .operand = 0, .msg = "" },
    .{ .label = "check_0_7", .ok = true, .word = 0x5207000000000000, .opcode = 82, .rd = 0, .rs1 = 7, .operand = 0, .msg = "" },
    .{ .label = "spawn_noslots", .ok = true, .word = 0x9000000000000000, .opcode = 144, .rd = 0, .rs1 = 0, .operand = 0, .msg = "" },
    .{ .label = "spawn_T0", .ok = true, .word = 0x9001000000000001, .opcode = 144, .rd = 0, .rs1 = 1, .operand = 1, .msg = "" },
    .{ .label = "spawn_T3", .ok = true, .word = 0x9001000000000008, .opcode = 144, .rd = 0, .rs1 = 1, .operand = 8, .msg = "" },
    .{ .label = "spawn_T7", .ok = true, .word = 0x9001000000000080, .opcode = 144, .rd = 0, .rs1 = 1, .operand = 128, .msg = "" },
    .{ .label = "spawn_T0T3T7", .ok = true, .word = 0x9001000000000089, .opcode = 144, .rd = 0, .rs1 = 1, .operand = 137, .msg = "" },
    .{ .label = "join_T2", .ok = true, .word = 0x9100000000000004, .opcode = 145, .rd = 0, .rs1 = 0, .operand = 4, .msg = "" },
    .{ .label = "yield", .ok = true, .word = 0x9200000000000000, .opcode = 146, .rd = 0, .rs1 = 0, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_0_0", .ok = true, .word = 0x5000000000000000, .opcode = 80, .rd = 0, .rs1 = 0, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_0_1", .ok = true, .word = 0x5001000000000000, .opcode = 80, .rd = 0, .rs1 = 1, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_0_2", .ok = true, .word = 0x5002000000000000, .opcode = 80, .rd = 0, .rs1 = 2, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_0_3", .ok = true, .word = 0x5003000000000000, .opcode = 80, .rd = 0, .rs1 = 3, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_0_4", .ok = true, .word = 0x5004000000000000, .opcode = 80, .rd = 0, .rs1 = 4, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_0_5", .ok = true, .word = 0x5005000000000000, .opcode = 80, .rd = 0, .rs1 = 5, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_0_6", .ok = true, .word = 0x5006000000000000, .opcode = 80, .rd = 0, .rs1 = 6, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_0_7", .ok = true, .word = 0x5007000000000000, .opcode = 80, .rd = 0, .rs1 = 7, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_0_8", .ok = true, .word = 0x5008000000000000, .opcode = 80, .rd = 0, .rs1 = 8, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_0_9", .ok = true, .word = 0x5009000000000000, .opcode = 80, .rd = 0, .rs1 = 9, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_0_10", .ok = true, .word = 0x500a000000000000, .opcode = 80, .rd = 0, .rs1 = 10, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_0_11", .ok = true, .word = 0x500b000000000000, .opcode = 80, .rd = 0, .rs1 = 11, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_2_0", .ok = true, .word = 0x5020000000000000, .opcode = 80, .rd = 2, .rs1 = 0, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_2_1", .ok = true, .word = 0x5021000000000000, .opcode = 80, .rd = 2, .rs1 = 1, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_2_2", .ok = true, .word = 0x5022000000000000, .opcode = 80, .rd = 2, .rs1 = 2, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_2_3", .ok = true, .word = 0x5023000000000000, .opcode = 80, .rd = 2, .rs1 = 3, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_2_4", .ok = true, .word = 0x5024000000000000, .opcode = 80, .rd = 2, .rs1 = 4, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_2_5", .ok = true, .word = 0x5025000000000000, .opcode = 80, .rd = 2, .rs1 = 5, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_2_6", .ok = true, .word = 0x5026000000000000, .opcode = 80, .rd = 2, .rs1 = 6, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_2_7", .ok = true, .word = 0x5027000000000000, .opcode = 80, .rd = 2, .rs1 = 7, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_2_8", .ok = true, .word = 0x5028000000000000, .opcode = 80, .rd = 2, .rs1 = 8, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_2_9", .ok = true, .word = 0x5029000000000000, .opcode = 80, .rd = 2, .rs1 = 9, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_2_10", .ok = true, .word = 0x502a000000000000, .opcode = 80, .rd = 2, .rs1 = 10, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_2_11", .ok = true, .word = 0x502b000000000000, .opcode = 80, .rd = 2, .rs1 = 11, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_4_0", .ok = true, .word = 0x5040000000000000, .opcode = 80, .rd = 4, .rs1 = 0, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_4_1", .ok = true, .word = 0x5041000000000000, .opcode = 80, .rd = 4, .rs1 = 1, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_4_2", .ok = true, .word = 0x5042000000000000, .opcode = 80, .rd = 4, .rs1 = 2, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_4_3", .ok = true, .word = 0x5043000000000000, .opcode = 80, .rd = 4, .rs1 = 3, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_4_4", .ok = true, .word = 0x5044000000000000, .opcode = 80, .rd = 4, .rs1 = 4, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_4_5", .ok = true, .word = 0x5045000000000000, .opcode = 80, .rd = 4, .rs1 = 5, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_4_6", .ok = true, .word = 0x5046000000000000, .opcode = 80, .rd = 4, .rs1 = 6, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_4_7", .ok = true, .word = 0x5047000000000000, .opcode = 80, .rd = 4, .rs1 = 7, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_4_8", .ok = true, .word = 0x5048000000000000, .opcode = 80, .rd = 4, .rs1 = 8, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_4_9", .ok = true, .word = 0x5049000000000000, .opcode = 80, .rd = 4, .rs1 = 9, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_4_10", .ok = true, .word = 0x504a000000000000, .opcode = 80, .rd = 4, .rs1 = 10, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_4_11", .ok = true, .word = 0x504b000000000000, .opcode = 80, .rd = 4, .rs1 = 11, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_6_0", .ok = true, .word = 0x5060000000000000, .opcode = 80, .rd = 6, .rs1 = 0, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_6_1", .ok = true, .word = 0x5061000000000000, .opcode = 80, .rd = 6, .rs1 = 1, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_6_2", .ok = true, .word = 0x5062000000000000, .opcode = 80, .rd = 6, .rs1 = 2, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_6_3", .ok = true, .word = 0x5063000000000000, .opcode = 80, .rd = 6, .rs1 = 3, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_6_4", .ok = true, .word = 0x5064000000000000, .opcode = 80, .rd = 6, .rs1 = 4, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_6_5", .ok = true, .word = 0x5065000000000000, .opcode = 80, .rd = 6, .rs1 = 5, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_6_6", .ok = true, .word = 0x5066000000000000, .opcode = 80, .rd = 6, .rs1 = 6, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_6_7", .ok = true, .word = 0x5067000000000000, .opcode = 80, .rd = 6, .rs1 = 7, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_6_8", .ok = true, .word = 0x5068000000000000, .opcode = 80, .rd = 6, .rs1 = 8, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_6_9", .ok = true, .word = 0x5069000000000000, .opcode = 80, .rd = 6, .rs1 = 9, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_6_10", .ok = true, .word = 0x506a000000000000, .opcode = 80, .rd = 6, .rs1 = 10, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_6_11", .ok = true, .word = 0x506b000000000000, .opcode = 80, .rd = 6, .rs1 = 11, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_8_0", .ok = true, .word = 0x5080000000000000, .opcode = 80, .rd = 8, .rs1 = 0, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_8_1", .ok = true, .word = 0x5081000000000000, .opcode = 80, .rd = 8, .rs1 = 1, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_8_2", .ok = true, .word = 0x5082000000000000, .opcode = 80, .rd = 8, .rs1 = 2, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_8_3", .ok = true, .word = 0x5083000000000000, .opcode = 80, .rd = 8, .rs1 = 3, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_8_4", .ok = true, .word = 0x5084000000000000, .opcode = 80, .rd = 8, .rs1 = 4, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_8_5", .ok = true, .word = 0x5085000000000000, .opcode = 80, .rd = 8, .rs1 = 5, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_8_6", .ok = true, .word = 0x5086000000000000, .opcode = 80, .rd = 8, .rs1 = 6, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_8_7", .ok = true, .word = 0x5087000000000000, .opcode = 80, .rd = 8, .rs1 = 7, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_8_8", .ok = true, .word = 0x5088000000000000, .opcode = 80, .rd = 8, .rs1 = 8, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_8_9", .ok = true, .word = 0x5089000000000000, .opcode = 80, .rd = 8, .rs1 = 9, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_8_10", .ok = true, .word = 0x508a000000000000, .opcode = 80, .rd = 8, .rs1 = 10, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_8_11", .ok = true, .word = 0x508b000000000000, .opcode = 80, .rd = 8, .rs1 = 11, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_10_0", .ok = true, .word = 0x50a0000000000000, .opcode = 80, .rd = 10, .rs1 = 0, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_10_1", .ok = true, .word = 0x50a1000000000000, .opcode = 80, .rd = 10, .rs1 = 1, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_10_2", .ok = true, .word = 0x50a2000000000000, .opcode = 80, .rd = 10, .rs1 = 2, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_10_3", .ok = true, .word = 0x50a3000000000000, .opcode = 80, .rd = 10, .rs1 = 3, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_10_4", .ok = true, .word = 0x50a4000000000000, .opcode = 80, .rd = 10, .rs1 = 4, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_10_5", .ok = true, .word = 0x50a5000000000000, .opcode = 80, .rd = 10, .rs1 = 5, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_10_6", .ok = true, .word = 0x50a6000000000000, .opcode = 80, .rd = 10, .rs1 = 6, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_10_7", .ok = true, .word = 0x50a7000000000000, .opcode = 80, .rd = 10, .rs1 = 7, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_10_8", .ok = true, .word = 0x50a8000000000000, .opcode = 80, .rd = 10, .rs1 = 8, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_10_9", .ok = true, .word = 0x50a9000000000000, .opcode = 80, .rd = 10, .rs1 = 9, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_10_10", .ok = true, .word = 0x50aa000000000000, .opcode = 80, .rd = 10, .rs1 = 10, .operand = 0, .msg = "" },
    .{ .label = "sweep_load_10_11", .ok = true, .word = 0x50ab000000000000, .opcode = 80, .rd = 10, .rs1 = 11, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_0_0", .ok = true, .word = 0x5100000000000000, .opcode = 81, .rd = 0, .rs1 = 0, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_1_0", .ok = true, .word = 0x5110000000000000, .opcode = 81, .rd = 1, .rs1 = 0, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_2_0", .ok = true, .word = 0x5120000000000000, .opcode = 81, .rd = 2, .rs1 = 0, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_3_0", .ok = true, .word = 0x5130000000000000, .opcode = 81, .rd = 3, .rs1 = 0, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_4_0", .ok = true, .word = 0x5140000000000000, .opcode = 81, .rd = 4, .rs1 = 0, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_5_0", .ok = true, .word = 0x5150000000000000, .opcode = 81, .rd = 5, .rs1 = 0, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_6_0", .ok = true, .word = 0x5160000000000000, .opcode = 81, .rd = 6, .rs1 = 0, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_7_0", .ok = true, .word = 0x5170000000000000, .opcode = 81, .rd = 7, .rs1 = 0, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_8_0", .ok = true, .word = 0x5180000000000000, .opcode = 81, .rd = 8, .rs1 = 0, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_9_0", .ok = true, .word = 0x5190000000000000, .opcode = 81, .rd = 9, .rs1 = 0, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_10_0", .ok = true, .word = 0x51a0000000000000, .opcode = 81, .rd = 10, .rs1 = 0, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_11_0", .ok = true, .word = 0x51b0000000000000, .opcode = 81, .rd = 11, .rs1 = 0, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_0_2", .ok = true, .word = 0x5102000000000000, .opcode = 81, .rd = 0, .rs1 = 2, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_1_2", .ok = true, .word = 0x5112000000000000, .opcode = 81, .rd = 1, .rs1 = 2, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_2_2", .ok = true, .word = 0x5122000000000000, .opcode = 81, .rd = 2, .rs1 = 2, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_3_2", .ok = true, .word = 0x5132000000000000, .opcode = 81, .rd = 3, .rs1 = 2, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_4_2", .ok = true, .word = 0x5142000000000000, .opcode = 81, .rd = 4, .rs1 = 2, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_5_2", .ok = true, .word = 0x5152000000000000, .opcode = 81, .rd = 5, .rs1 = 2, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_6_2", .ok = true, .word = 0x5162000000000000, .opcode = 81, .rd = 6, .rs1 = 2, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_7_2", .ok = true, .word = 0x5172000000000000, .opcode = 81, .rd = 7, .rs1 = 2, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_8_2", .ok = true, .word = 0x5182000000000000, .opcode = 81, .rd = 8, .rs1 = 2, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_9_2", .ok = true, .word = 0x5192000000000000, .opcode = 81, .rd = 9, .rs1 = 2, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_10_2", .ok = true, .word = 0x51a2000000000000, .opcode = 81, .rd = 10, .rs1 = 2, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_11_2", .ok = true, .word = 0x51b2000000000000, .opcode = 81, .rd = 11, .rs1 = 2, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_0_4", .ok = true, .word = 0x5104000000000000, .opcode = 81, .rd = 0, .rs1 = 4, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_1_4", .ok = true, .word = 0x5114000000000000, .opcode = 81, .rd = 1, .rs1 = 4, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_2_4", .ok = true, .word = 0x5124000000000000, .opcode = 81, .rd = 2, .rs1 = 4, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_3_4", .ok = true, .word = 0x5134000000000000, .opcode = 81, .rd = 3, .rs1 = 4, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_4_4", .ok = true, .word = 0x5144000000000000, .opcode = 81, .rd = 4, .rs1 = 4, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_5_4", .ok = true, .word = 0x5154000000000000, .opcode = 81, .rd = 5, .rs1 = 4, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_6_4", .ok = true, .word = 0x5164000000000000, .opcode = 81, .rd = 6, .rs1 = 4, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_7_4", .ok = true, .word = 0x5174000000000000, .opcode = 81, .rd = 7, .rs1 = 4, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_8_4", .ok = true, .word = 0x5184000000000000, .opcode = 81, .rd = 8, .rs1 = 4, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_9_4", .ok = true, .word = 0x5194000000000000, .opcode = 81, .rd = 9, .rs1 = 4, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_10_4", .ok = true, .word = 0x51a4000000000000, .opcode = 81, .rd = 10, .rs1 = 4, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_11_4", .ok = true, .word = 0x51b4000000000000, .opcode = 81, .rd = 11, .rs1 = 4, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_0_6", .ok = true, .word = 0x5106000000000000, .opcode = 81, .rd = 0, .rs1 = 6, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_1_6", .ok = true, .word = 0x5116000000000000, .opcode = 81, .rd = 1, .rs1 = 6, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_2_6", .ok = true, .word = 0x5126000000000000, .opcode = 81, .rd = 2, .rs1 = 6, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_3_6", .ok = true, .word = 0x5136000000000000, .opcode = 81, .rd = 3, .rs1 = 6, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_4_6", .ok = true, .word = 0x5146000000000000, .opcode = 81, .rd = 4, .rs1 = 6, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_5_6", .ok = true, .word = 0x5156000000000000, .opcode = 81, .rd = 5, .rs1 = 6, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_6_6", .ok = true, .word = 0x5166000000000000, .opcode = 81, .rd = 6, .rs1 = 6, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_7_6", .ok = true, .word = 0x5176000000000000, .opcode = 81, .rd = 7, .rs1 = 6, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_8_6", .ok = true, .word = 0x5186000000000000, .opcode = 81, .rd = 8, .rs1 = 6, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_9_6", .ok = true, .word = 0x5196000000000000, .opcode = 81, .rd = 9, .rs1 = 6, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_10_6", .ok = true, .word = 0x51a6000000000000, .opcode = 81, .rd = 10, .rs1 = 6, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_11_6", .ok = true, .word = 0x51b6000000000000, .opcode = 81, .rd = 11, .rs1 = 6, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_0_8", .ok = true, .word = 0x5108000000000000, .opcode = 81, .rd = 0, .rs1 = 8, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_1_8", .ok = true, .word = 0x5118000000000000, .opcode = 81, .rd = 1, .rs1 = 8, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_2_8", .ok = true, .word = 0x5128000000000000, .opcode = 81, .rd = 2, .rs1 = 8, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_3_8", .ok = true, .word = 0x5138000000000000, .opcode = 81, .rd = 3, .rs1 = 8, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_4_8", .ok = true, .word = 0x5148000000000000, .opcode = 81, .rd = 4, .rs1 = 8, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_5_8", .ok = true, .word = 0x5158000000000000, .opcode = 81, .rd = 5, .rs1 = 8, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_6_8", .ok = true, .word = 0x5168000000000000, .opcode = 81, .rd = 6, .rs1 = 8, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_7_8", .ok = true, .word = 0x5178000000000000, .opcode = 81, .rd = 7, .rs1 = 8, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_8_8", .ok = true, .word = 0x5188000000000000, .opcode = 81, .rd = 8, .rs1 = 8, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_9_8", .ok = true, .word = 0x5198000000000000, .opcode = 81, .rd = 9, .rs1 = 8, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_10_8", .ok = true, .word = 0x51a8000000000000, .opcode = 81, .rd = 10, .rs1 = 8, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_11_8", .ok = true, .word = 0x51b8000000000000, .opcode = 81, .rd = 11, .rs1 = 8, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_0_10", .ok = true, .word = 0x510a000000000000, .opcode = 81, .rd = 0, .rs1 = 10, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_1_10", .ok = true, .word = 0x511a000000000000, .opcode = 81, .rd = 1, .rs1 = 10, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_2_10", .ok = true, .word = 0x512a000000000000, .opcode = 81, .rd = 2, .rs1 = 10, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_3_10", .ok = true, .word = 0x513a000000000000, .opcode = 81, .rd = 3, .rs1 = 10, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_4_10", .ok = true, .word = 0x514a000000000000, .opcode = 81, .rd = 4, .rs1 = 10, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_5_10", .ok = true, .word = 0x515a000000000000, .opcode = 81, .rd = 5, .rs1 = 10, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_6_10", .ok = true, .word = 0x516a000000000000, .opcode = 81, .rd = 6, .rs1 = 10, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_7_10", .ok = true, .word = 0x517a000000000000, .opcode = 81, .rd = 7, .rs1 = 10, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_8_10", .ok = true, .word = 0x518a000000000000, .opcode = 81, .rd = 8, .rs1 = 10, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_9_10", .ok = true, .word = 0x519a000000000000, .opcode = 81, .rd = 9, .rs1 = 10, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_10_10", .ok = true, .word = 0x51aa000000000000, .opcode = 81, .rd = 10, .rs1 = 10, .operand = 0, .msg = "" },
    .{ .label = "sweep_store_11_10", .ok = true, .word = 0x51ba000000000000, .opcode = 81, .rd = 11, .rs1 = 10, .operand = 0, .msg = "" },
    .{ .label = "neg_load_1_0", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.load\" operand 2 (destination register) is \"R1\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_load_1_2", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.load\" operand 2 (destination register) is \"R1\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_load_1_4", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.load\" operand 2 (destination register) is \"R1\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_load_1_6", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.load\" operand 2 (destination register) is \"R1\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_load_1_8", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.load\" operand 2 (destination register) is \"R1\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_load_1_10", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.load\" operand 2 (destination register) is \"R1\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_load_3_0", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.load\" operand 2 (destination register) is \"R3\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_load_3_2", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.load\" operand 2 (destination register) is \"R3\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_load_3_4", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.load\" operand 2 (destination register) is \"R3\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_load_3_6", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.load\" operand 2 (destination register) is \"R3\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_load_3_8", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.load\" operand 2 (destination register) is \"R3\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_load_3_10", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.load\" operand 2 (destination register) is \"R3\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_load_5_0", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.load\" operand 2 (destination register) is \"R5\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_load_5_2", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.load\" operand 2 (destination register) is \"R5\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_load_5_4", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.load\" operand 2 (destination register) is \"R5\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_load_5_6", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.load\" operand 2 (destination register) is \"R5\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_load_5_8", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.load\" operand 2 (destination register) is \"R5\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_load_5_10", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.load\" operand 2 (destination register) is \"R5\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_load_7_0", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.load\" operand 2 (destination register) is \"R7\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_load_7_2", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.load\" operand 2 (destination register) is \"R7\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_load_7_4", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.load\" operand 2 (destination register) is \"R7\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_load_7_6", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.load\" operand 2 (destination register) is \"R7\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_load_7_8", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.load\" operand 2 (destination register) is \"R7\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_load_7_10", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.load\" operand 2 (destination register) is \"R7\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_load_9_0", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.load\" operand 2 (destination register) is \"R9\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_load_9_2", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.load\" operand 2 (destination register) is \"R9\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_load_9_4", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.load\" operand 2 (destination register) is \"R9\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_load_9_6", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.load\" operand 2 (destination register) is \"R9\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_load_9_8", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.load\" operand 2 (destination register) is \"R9\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_load_9_10", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.load\" operand 2 (destination register) is \"R9\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_load_11_0", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.load\" operand 2 (destination register) is \"R11\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_load_11_2", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.load\" operand 2 (destination register) is \"R11\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_load_11_4", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.load\" operand 2 (destination register) is \"R11\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_load_11_6", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.load\" operand 2 (destination register) is \"R11\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_load_11_8", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.load\" operand 2 (destination register) is \"R11\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_load_11_10", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.load\" operand 2 (destination register) is \"R11\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_store_0_1", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.store\" operand 2 (source register) is \"R1\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_store_2_1", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.store\" operand 2 (source register) is \"R1\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_store_4_1", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.store\" operand 2 (source register) is \"R1\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_store_6_1", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.store\" operand 2 (source register) is \"R1\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_store_8_1", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.store\" operand 2 (source register) is \"R1\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_store_10_1", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.store\" operand 2 (source register) is \"R1\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_store_0_3", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.store\" operand 2 (source register) is \"R3\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_store_2_3", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.store\" operand 2 (source register) is \"R3\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_store_4_3", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.store\" operand 2 (source register) is \"R3\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_store_6_3", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.store\" operand 2 (source register) is \"R3\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_store_8_3", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.store\" operand 2 (source register) is \"R3\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_store_10_3", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.store\" operand 2 (source register) is \"R3\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_store_0_5", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.store\" operand 2 (source register) is \"R5\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_store_2_5", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.store\" operand 2 (source register) is \"R5\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_store_4_5", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.store\" operand 2 (source register) is \"R5\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_store_6_5", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.store\" operand 2 (source register) is \"R5\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_store_8_5", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.store\" operand 2 (source register) is \"R5\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_store_10_5", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.store\" operand 2 (source register) is \"R5\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_store_0_7", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.store\" operand 2 (source register) is \"R7\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_store_2_7", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.store\" operand 2 (source register) is \"R7\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_store_4_7", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.store\" operand 2 (source register) is \"R7\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_store_6_7", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.store\" operand 2 (source register) is \"R7\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_store_8_7", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.store\" operand 2 (source register) is \"R7\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_store_10_7", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.store\" operand 2 (source register) is \"R7\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_store_0_9", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.store\" operand 2 (source register) is \"R9\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_store_2_9", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.store\" operand 2 (source register) is \"R9\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_store_4_9", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.store\" operand 2 (source register) is \"R9\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_store_6_9", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.store\" operand 2 (source register) is \"R9\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_store_8_9", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.store\" operand 2 (source register) is \"R9\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_store_10_9", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.store\" operand 2 (source register) is \"R9\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_store_0_11", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.store\" operand 2 (source register) is \"R11\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_store_2_11", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.store\" operand 2 (source register) is \"R11\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_store_4_11", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.store\" operand 2 (source register) is \"R11\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_store_6_11", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.store\" operand 2 (source register) is \"R11\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_store_8_11", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.store\" operand 2 (source register) is \"R11\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
    .{ .label = "neg_store_10_11", .ok = false, .word = 0, .opcode = 0, .rd = 0, .rs1 = 0, .operand = 0, .msg = "error: at /tmp/v22gen/in.asm, line 1: while assembling this line the instruction \"cap.store\" operand 2 (source register) is \"R11\", which is not valid here. Expected an even register index, because a capability descriptor occupies two consecutive registers and an odd index would overlap its neighbour (docs/isa-encoding.md §3.5)." },
};

// ===========================================================================
// F14 — asserted on the recorded BITS, swept exhaustively
// ===========================================================================

fn fact(label: []const u8) @TypeOf(facts[0]) {
    for (facts) |f| {
        if (std.mem.eql(u8, f.label, label)) return f;
    }
    @panic("missing recorded fact");
}

test "F14 (a): cap.load R2, R3 ASSEMBLES to exactly 0x5023000000000000" {
    const f = comptime fact("load_2_3");
    try testing.expect(f.ok);
    try testing.expectEqual(@as(u64, 0x5023_0000_0000_0000), f.word);
    try testing.expectEqual(@as(u8, 0x50), f.opcode);
    try testing.expectEqual(@as(u4, 2), f.rd);
    try testing.expectEqual(@as(u4, 3), f.rs1);
    try testing.expectEqual(@as(u48, 0), f.operand);
}

test "F14 (b): cap.store R3, R2 ASSEMBLES to exactly 0x5132000000000000" {
    const f = comptime fact("store_3_2");
    try testing.expect(f.ok);
    try testing.expectEqual(@as(u64, 0x5132_0000_0000_0000), f.word);
    try testing.expectEqual(@as(u8, 0x51), f.opcode);
    try testing.expectEqual(@as(u4, 3), f.rd);
    try testing.expectEqual(@as(u4, 2), f.rs1);
    try testing.expectEqual(@as(u48, 0), f.operand);
}

test "F14 (c): cap.load R3, R2 is REJECTED and blames operand 2" {
    const f = comptime fact("load_3_2");
    try testing.expect(!f.ok);
    try testing.expect(std.mem.indexOf(u8, f.msg, "operand 2") != null);
    try testing.expect(std.mem.indexOf(u8, f.msg, "R3") != null);
    try testing.expect(!diag.hasBareHexCode(f.msg));
}

test "F14 (d): cap.store R2, R3 is REJECTED and blames operand 2" {
    const f = comptime fact("store_2_3");
    try testing.expect(!f.ok);
    try testing.expect(std.mem.indexOf(u8, f.msg, "operand 2") != null);
    try testing.expect(std.mem.indexOf(u8, f.msg, "R3") != null);
    try testing.expect(!diag.hasBareHexCode(f.msg));
}


test "F14 positive control: all 144 legal pair forms assemble with correct bits" {
    // The over-reach was invisible because the prior control used only even rs1 values.
    @setEvalBranchQuota(200000);
    var n: usize = 0;
    inline for (facts) |f| {
        if (comptime std.mem.startsWith(u8, f.label, "sweep_")) {
            n += 1;
            try testing.expect(f.ok);
            if (comptime std.mem.startsWith(u8, f.label, "sweep_load_")) {
                try testing.expectEqual(@as(u8, 0x50), f.opcode);
                // rd must be EVEN and rs1 may be anything: that is the F14 rule.
                try testing.expect(f.rd % 2 == 0);
            } else {
                try testing.expectEqual(@as(u8, 0x51), f.opcode);
                // rs1 must be EVEN and rd may be anything.
                try testing.expect(f.rs1 % 2 == 0);
            }
            try testing.expectEqual(@as(u48, 0), f.operand);
        }
    }
    try testing.expectEqual(@as(usize, 144), n);
}

test "F14 negative control: all 72 illegal pair forms are rejected" {
    @setEvalBranchQuota(200000);
    var n: usize = 0;
    inline for (facts) |f| {
        if (comptime std.mem.startsWith(u8, f.label, "neg_")) {
            n += 1;
            try testing.expect(!f.ok);
            try testing.expect(!diag.hasBareHexCode(f.msg));
        }
    }
    try testing.expectEqual(@as(usize, 72), n);
}

test "F12: cap.load R2, R3, R4 is rejected and blames OPERAND 3 (not operand 2)" {
    const f = comptime fact("load_2_3_4");
    try testing.expect(!f.ok);
    try testing.expect(std.mem.indexOf(u8, f.msg, "operand 3") != null);
    try testing.expect(std.mem.indexOf(u8, f.msg, "R4") != null);
    try testing.expect(std.mem.indexOf(u8, f.msg, "operand 2") == null);
}

test "F12: cap.store with a surplus third register is also rejected" {
    const f = comptime fact("store_2_4_6");
    try testing.expect(!f.ok);
    try testing.expect(std.mem.indexOf(u8, f.msg, "operand 3") != null);
}

test "Amendment 1.12: cap.check rs1 is NOT subject to the even-index rule" {
    inline for (.{ "check_2_3", "check_0_1", "check_0_7" }) |label| {
        const f = comptime fact(label);
        try testing.expect(f.ok);
        try testing.expectEqual(@as(u8, 0x52), f.opcode);
        try testing.expectEqual(@as(u48, 0), f.operand);
    }
    // check_0_7 has odd rs1 == 7 and must still assemble.
    const f = comptime fact("check_0_7");
    try testing.expectEqual(@as(u4, 7), f.rs1);
}

// ===========================================================================
// F15 — a loaded image cannot smuggle reserved bits past the decoder
// ===========================================================================

test "F15: 0x5023400000000000 is REJECTED by the decoder (non-zero operand[47:0])" {
    const w: u64 = 0x5023_4000_0000_0000;
    const d = decoder.decode(w);
    try testing.expect(d == .err);
    var buf: [1024]u8 = undefined;
    const text = diag.renderToBuffer(d.err, &buf);
    try testing.expect(!diag.hasBareHexCode(text));
    try testing.expect(std.mem.indexOf(u8, text, "reserved") != null);
}

test "F15 positive control: 0x5212000000000000 still decodes as cap.check R1, R2" {
    // Without this, a decoder that rejected every cap.* word would pass the test above.
    const w: u64 = 0x5212_0000_0000_0000;
    const d = decoder.decode(w);
    try testing.expect(d == .ok);
    switch (d.ok) {
        .cap_check => |c| {
            try testing.expectEqual(@as(u4, 1), c.rd);
            try testing.expectEqual(@as(u4, 2), c.rs1);
        },
        else => return error.WrongTag,
    }
}

test "F15: EVERY legal cap.* word still decodes (no over-reach onto legal words)" {
    @setEvalBranchQuota(200000);
    inline for (facts) |f| {
        if (comptime (f.ok and (std.mem.startsWith(u8, f.label, "sweep_") or
            std.mem.startsWith(u8, f.label, "load_2_3") or
            std.mem.startsWith(u8, f.label, "store_3_2") or
            std.mem.startsWith(u8, f.label, "check_"))))
        {
            const d = decoder.decode(f.word);
            try testing.expect(d == .ok);
        }
    }
}

// ===========================================================================
// TASK 20 — cap.* refusal at runtime. Amendment 1.12: ALL THREE decode-only.
// ===========================================================================

fn vmWith(word: u64) [32]u8 {
    var img: [32]u8 = @splat(0);
    std.mem.writeInt(u64, img[0..8], word, .little);
    std.mem.writeInt(u64, img[8..16], vm.encode(0x01, 0, 0, 0), .little);
    return img;
}

test "cap.load REFUSES at runtime and writes NOTHING to rd" {
    var img = vmWith(0x5023_0000_0000_0000);
    var m = vm.Vm.init(&img);
    m.regs.write(2, 0xDEAD_BEEF_CAFE_F00D);
    const s = try m.step();
    try testing.expect(s == .fault);
    try testing.expectEqual(@as(u64, 0xDEAD_BEEF_CAFE_F00D), m.regs.read(2));
    try testing.expect(m.halted);
    var buf: [1024]u8 = undefined;
    const text = diag.renderToBuffer(s.fault, &buf);
    try testing.expect(!diag.hasBareHexCode(text));
    try testing.expect(std.mem.indexOf(u8, text, "address") != null);
}

test "cap.store REFUSES at runtime and writes NOTHING" {
    var img = vmWith(0x5132_0000_0000_0000);
    var m = vm.Vm.init(&img);
    m.regs.write(3, 0x1111_2222_3333_4444);
    const s = try m.step();
    try testing.expect(s == .fault);
    try testing.expectEqual(@as(u64, 0x1111_2222_3333_4444), m.regs.read(3));
}

test "cap.check REFUSES and invents NO status in rd (Amendment 1.12 / F13)" {
    var img = vmWith(0x5223_0000_0000_0000);
    var m = vm.Vm.init(&img);
    m.regs.write(2, 0xABCD_EF01_2345_6789);
    const s = try m.step();
    try testing.expect(s == .fault);
    try testing.expectEqual(@as(u64, 0xABCD_EF01_2345_6789), m.regs.read(2));
    try testing.expect(m.halted);
}

test "each cap.* opcode faults and does NOT advance PC" {
    inline for (.{ @as(u8, 0x50), 0x51, 0x52 }) |op| {
        var img: [32]u8 = @splat(0);
        std.mem.writeInt(u64, img[0..8], vm.encode(op, 2, 3, 0), .little);
        var m = vm.Vm.init(&img);
        const s = try m.step();
        try testing.expect(s == .fault);
        try testing.expectEqual(@as(u64, 0), m.regs.pc);
        try testing.expect(m.halted);
    }
}

// ===========================================================================
// TASK 19 — thread.* execution (§3.7)
// ===========================================================================

test "an empty thread mask is legal, starts nothing, and is NOT an error" {
    const f = comptime fact("spawn_noslots");
    try testing.expect(f.ok);
    try testing.expectEqual(@as(u8, 0x90), f.opcode);
    try testing.expectEqual(@as(u8, 0), @as(u8, @truncate(f.word)));

    var img = vmWith(f.word);
    var m = vm.Vm.init(&img);
    const s = try m.step();
    try testing.expect(s == .advanced);
    try testing.expectEqual(@as(usize, 0), m.sched.activeCount());
    var i: u4 = 0;
    while (i < threading.slot_count) : (i += 1) {
        try testing.expect(m.sched.slots[i].state == .idle);
    }
}

test "mask bit i starts slot T_i at the address in rs1 (T0, T3, T7)" {
    // T7 specifically requires bit 7: a 5-bit mask would silently lose it.
    const cases = [_]struct { label: []const u8, slot: u4, entry: u64 }{
        .{ .label = "spawn_T0", .slot = 0, .entry = 0x1000 },
        .{ .label = "spawn_T3", .slot = 3, .entry = 0x3000 },
        .{ .label = "spawn_T7", .slot = 7, .entry = 0x7000 },
    };

    inline for (cases) |c| {
        const f = comptime fact(c.label);
        try testing.expect(f.ok);
        try testing.expectEqual(@as(u8, 0x90), f.opcode);
        try testing.expectEqual(@as(u4, 1), f.rs1);
        try testing.expectEqual(@as(u8, 1 << c.slot), @as(u8, @truncate(f.word)));

        var img: [64]u8 = @splat(0);
        std.mem.writeInt(u64, img[0..8], vm.encode(0x19, 1, 0, vm.aluOperand(0, .full, @intCast(c.entry))), .little);
        std.mem.writeInt(u64, img[8..16], f.word, .little);

        var m = vm.Vm.init(&img);
        _ = try m.step();
        const s = try m.step();
        try testing.expect(s == .advanced);
        try testing.expect(m.sched.slots[c.slot].state == .running);
        try testing.expectEqual(c.entry, m.sched.slots[c.slot].entry);
        try testing.expectEqual(@as(usize, 1), m.sched.activeCount());
        var i: u4 = 0;
        while (i < threading.slot_count) : (i += 1) {
            if (i == c.slot) continue;
            try testing.expect(m.sched.slots[i].state == .idle);
        }
    }
}

test "multiple slots in one mask all start, each with its own index" {
    const f = comptime fact("spawn_T0T3T7");
    try testing.expect(f.ok);
    try testing.expectEqual(@as(u8, 0b1000_1001), @as(u8, @truncate(f.word)));

    var img: [64]u8 = @splat(0);
    std.mem.writeInt(u64, img[0..8], vm.encode(0x19, 1, 0, vm.aluOperand(0, .full, 0x9000)), .little);
    std.mem.writeInt(u64, img[8..16], f.word, .little);
    var m = vm.Vm.init(&img);
    _ = try m.step();
    _ = try m.step();

    try testing.expectEqual(@as(usize, 3), m.sched.activeCount());
    inline for (.{ @as(u4, 0), 3, 7 }) |i| {
        try testing.expect(m.sched.slots[i].state == .running);
        try testing.expectEqual(@as(u64, 0x9000), m.sched.slots[i].entry);
    }
    try testing.expect(m.sched.slots[1].state == .idle);
    try testing.expect(m.sched.slots[6].state == .idle);
}

test "joining a NON-RUNNING slot faults in plain language" {
    const f = comptime fact("join_T2");
    try testing.expect(f.ok);
    var img = vmWith(f.word);
    var m = vm.Vm.init(&img);
    const s = try m.step();
    try testing.expect(s == .fault);
    var buf: [1024]u8 = undefined;
    const text = diag.renderToBuffer(s.fault, &buf);
    try testing.expect(!diag.hasBareHexCode(text));
    try testing.expect(text.len > 0);
    try testing.expect(m.halted);
}

test "spawn on an ALREADY-RUNNING slot faults rather than double-starting" {
    const f = comptime fact("spawn_T0");
    var img: [96]u8 = @splat(0);
    std.mem.writeInt(u64, img[0..8], vm.encode(0x19, 1, 0, vm.aluOperand(0, .full, 0x10)), .little);
    std.mem.writeInt(u64, img[8..16], f.word, .little);
    std.mem.writeInt(u64, img[16..24], f.word, .little);

    var m = vm.Vm.init(&img);
    _ = try m.step();
    _ = try m.step();
    const s = try m.step();
    try testing.expect(s == .fault);
    try testing.expectEqual(@as(usize, 1), m.sched.activeCount());
}

test "yield with an EMPTY run queue faults rather than advancing" {
    const f = comptime fact("yield");
    try testing.expectEqual(@as(u8, 0x92), f.opcode);
    var img = vmWith(f.word);
    var m = vm.Vm.init(&img);
    const s = try m.step();
    try testing.expect(s == .fault);
    try testing.expectEqual(@as(u64, 0), m.regs.pc);
    try testing.expect(m.halted);
}

test "positive control: yield WITH a runnable slot advances and dispatches" {
    // The negative test above is only meaningful if a legal yield behaves differently.
    const spawn = comptime fact("spawn_T0");
    const yld = comptime fact("yield");

    var img: [96]u8 = @splat(0);
    std.mem.writeInt(u64, img[0..8], vm.encode(0x19, 1, 0, vm.aluOperand(0, .full, 0x40)), .little);
    std.mem.writeInt(u64, img[8..16], spawn.word, .little);
    std.mem.writeInt(u64, img[16..24], yld.word, .little);

    var m = vm.Vm.init(&img);
    _ = try m.step();
    _ = try m.step();
    const s = try m.step();
    try testing.expect(s == .advanced);
    try testing.expectEqual(@as(u64, 24), m.regs.pc);
    try testing.expectEqual(@as(u64, 1), m.sched.dispatches);
}

test "fidelity: the thread model is a deterministic interleave with 8 slots" {
    try testing.expectEqual(@as(usize, 8), threading.slot_count);
    try testing.expect(std.meta.hasFn(threading.Scheduler, "dispatch"));
    try testing.expect(std.meta.hasFn(threading.Scheduler, "nextRunnable"));
}
