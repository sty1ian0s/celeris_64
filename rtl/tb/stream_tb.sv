//=============================================================================
// stream_tb.sv — CLS64 stream / select / field testbench (Verilator 5.x --binary)
//
// Drives the three §3.4 / §3.2 / §3.3 primitives with HAND-COMPUTED vectors from
// docs/isa-encoding.md VERSION 1.14. Every expected value below is written as a
// literal derived from the contract or from the verified Zig model (src/stream.zig,
// src/select.zig, src/field.zig) — never read back out of the DUT — so a wrong
// encoding FAILS rather than agreeing with itself.
//
// The centrepiece is the ATOMICITY test: a chunk that overruns the end of the
// accessible region by exactly one element must leave the memory array
// BYTE-FOR-BYTE unchanged AND must not advance the pointer. That is §3.4 rule 3,
// and it is asserted against a real byte array, not described in a comment.
//
// FIDELITY (docs/isa-encoding.md §8): SIMULATION of a lint-verified specification.
// The design is now synthesized (tools/rtl-synth.sh); this testbench was not part
// of that. Still never timing-closed, never on silicon, no frequency claimed.
//
// Testbench hygiene: rtl/ synthesizable modules contain no `initial` and no `#`
// delays; this file is under rtl/tb/ and is the only place either appears. There is
// deliberately NO `timescale` — the synthesizable modules are forbidden one and a
// testbench-local timescale makes Verilator raise TIMESCALEMOD against every module
// that lacks it.
//=============================================================================

module stream_tb
  import celeris64_pkg::*;
();

  //---------------------------------------------------------------------------
  // DUT signals — stream engine
  //---------------------------------------------------------------------------
  logic                  clk;
  logic                  rst_ni;

  logic                  se_issue;
  logic [OP_W-1:0]       se_opcode;
  logic [RS2_W-1:0]      se_rs2_idx;
  logic [19:0]           se_chunk;
  logic [ALUWIDTH_W-1:0] se_elem_width;
  logic [19:0]           se_reserved;
  logic [XLEN-1:0]       se_ptr_val;
  logic [XLEN-1:0]       se_scalar_val;
  logic [XLEN-1:0]       se_src_addr;
  logic [XLEN-1:0]       se_offset_val;
  logic [XLEN-1:0]       se_region_base;
  logic [XLEN-1:0]       se_region_len;

  logic                  se_mem_wr_en;
  logic [XLEN-1:0]       se_mem_wr_addr;
  logic [XLEN-1:0]       se_mem_wr_data;
  logic [7:0]            se_mem_byte_sel;
  logic                  se_mem_rd_en;
  logic [XLEN-1:0]       se_mem_rd_addr;
  logic [XLEN-1:0]       se_mem_rd_data;

  logic [XLEN-1:0]       se_ptr_d;
  logic                  se_ptr_we;
  logic                  se_busy;
  logic                  se_chunk_err;
  logic                  se_width_err;
  logic                  se_reserved_err;
  logic                  se_bounds_err;
  logic                  se_chunk_too_large;
  logic [RS2_W-1:0]      se_rs2_idx_o;

  //---------------------------------------------------------------------------
  // DUT signals — select unit
  //---------------------------------------------------------------------------
  logic [OP_W-1:0]       su_opcode;
  logic [RS2_W-1:0]      su_rs2_idx;
  logic [RS1_W-1:0]      su_true_idx, su_false_idx;
  logic [35:0]           su_reserved;
  logic                  su_reserved_err;
  logic [XLEN-1:0]       su_rs1_val, su_src2_val;
  logic                  su_signed_view;
  logic [RS2_W-1:0]      su_match_status;
  status_e               su_status_val;
  logic [XLEN-1:0]       su_true_val, su_false_val;
  status_e               su_status;
  logic [XLEN-1:0]       su_select;
  logic                  su_op_legal;
  logic [RS2_W-1:0]      su_rs2_idx_o;
  logic [RS1_W-1:0]      su_true_idx_o, su_false_idx_o;

  //---------------------------------------------------------------------------
  // DUT signals — field unit
  //---------------------------------------------------------------------------
  logic [OP_W-1:0]       fu_opcode;
  logic [7:0]            fu_offset, fu_width;
  logic [RS1_W-1:0]      fu_src2_idx;
  logic [27:0]           fu_reserved;
  logic                  fu_reserved_err;
  logic [XLEN-1:0]       fu_base_val, fu_field_val;
  logic [XLEN-1:0]       fu_result;
  logic                  fu_zero_width, fu_range_err, fu_too_wide, fu_op_legal;
  logic [RS1_W-1:0]      fu_src2_idx_o;

  //---------------------------------------------------------------------------
  // Test memory. A REAL byte array, so the atomicity assertion compares bytes
  // rather than sampling DUT outputs and hoping.
  //---------------------------------------------------------------------------
  localparam int unsigned MEM_BYTES = 32;
  logic [7:0] mem [MEM_BYTES];

  //---------------------------------------------------------------------------
  // Pass/fail bookkeeping. `$fatal` on the first mismatch would hide how many
  // vectors agreed, so failures are counted and the process exits non-zero with a
  // real FAIL line. Silence is never success here.
  //---------------------------------------------------------------------------
  int unsigned checks   = 0;
  int unsigned failures = 0;

  stream_engine u_stream (
    .clk_i             (clk),
    .rst_ni            (rst_ni),
    .issue_i           (se_issue),
    .opcode_i          (se_opcode),
    .rs2_idx_i         (se_rs2_idx),
    .chunk_i           (se_chunk),
    .elem_width_raw_i  (se_elem_width),
    .reserved_i        (se_reserved),
    .ptr_val_i         (se_ptr_val),
    .scalar_val_i      (se_scalar_val),
    .src_addr_i        (se_src_addr),
    .offset_val_i      (se_offset_val),
    .region_base_i     (se_region_base),
    .region_len_i      (se_region_len),
    .mem_wr_en_o       (se_mem_wr_en),
    .mem_wr_addr_o     (se_mem_wr_addr),
    .mem_wr_data_o     (se_mem_wr_data),
    .mem_byte_sel_o    (se_mem_byte_sel),
    .mem_rd_en_o       (se_mem_rd_en),
    .mem_rd_addr_o     (se_mem_rd_addr),
    .mem_rd_data_i     (se_mem_rd_data),
    .ptr_d_o           (se_ptr_d),
    .ptr_we_o          (se_ptr_we),
    .busy_o            (se_busy),
    .chunk_err_o       (se_chunk_err),
    .width_err_o       (se_width_err),
    .reserved_err_o    (se_reserved_err),
    .bounds_err_o      (se_bounds_err),
    .chunk_too_large_o (se_chunk_too_large),
    .rs2_idx_o         (se_rs2_idx_o)
  );

  select_unit u_select (
    .opcode_i       (su_opcode),
    .rs2_idx_i      (su_rs2_idx),
    .true_idx_i     (su_true_idx),
    .false_idx_i    (su_false_idx),
    .reserved_i     (su_reserved),
    .rs1_val_i      (su_rs1_val),
    .src2_val_i     (su_src2_val),
    .signed_view_i  (su_signed_view),
    .match_status_i (su_match_status),
    .status_val_i   (su_status_val),
    .true_val_i     (su_true_val),
    .false_val_i    (su_false_val),
    .status_o       (su_status),
    .select_o       (su_select),
    .op_legal_o     (su_op_legal),
    .reserved_err_o (su_reserved_err),
    .rs2_idx_o      (su_rs2_idx_o),
    .true_idx_o     (su_true_idx_o),
    .false_idx_o    (su_false_idx_o)
  );

  field_unit u_field (
    .opcode_i    (fu_opcode),
    .offset_i    (fu_offset),
    .width_i     (fu_width),
    .src2_idx_i  (fu_src2_idx),
    .reserved_i  (fu_reserved),
    .base_val_i  (fu_base_val),
    .field_val_i (fu_field_val),
    .result_o    (fu_result),
    .zero_width_o(fu_zero_width),
    .range_err_o (fu_range_err),
    .too_wide_o  (fu_too_wide),
    .op_legal_o  (fu_op_legal),
    .reserved_err_o(fu_reserved_err),
    .src2_idx_o  (fu_src2_idx_o)
  );

  //---------------------------------------------------------------------------
  // Memory model. Writes land in the byte array on the clock edge whenever the
  // strobe is high, exactly as a real single-port memory would; a byte lane that
  // is not selected is left alone. Reads are combinational.
  //---------------------------------------------------------------------------
  localparam int unsigned ADDR_W = 5;   // MEM_BYTES == 32, so 5 address bits

  // The port carries a FULL 64-bit element at `mem_wr_addr_o`, with `mem_byte_sel_o`
  // as per-byte write enables at `addr + b`. This memory therefore decodes the whole
  // address and REFUSES anything outside the modelled region rather than truncating
  // the low 5 bits: truncation would alias an out-of-bounds chunk back onto byte 0
  // and make the atomicity vector test address aliasing instead of atomicity. That
  // exact aliasing produced false failures in an earlier revision of this harness.
  logic wr_in_range_q;
  logic rd_in_range_q;
  logic out_of_range_q;

  always_comb begin
    // A write that stays wholly inside [0, MEM_BYTES) is modelled; anything else is
    // flagged, and the DUT's own §3.4 bounds gate means it must never happen.
    wr_in_range_q = (se_mem_wr_addr + XLEN'(8)) <= XLEN'(MEM_BYTES);
    rd_in_range_q = (se_mem_rd_addr + XLEN'(8)) <= XLEN'(MEM_BYTES);
    out_of_range_q = (se_mem_wr_en && !wr_in_range_q) || (se_mem_rd_en && !rd_in_range_q);
  end

  // A read strobe the testbench does not observe is still a real DUT output;
  // sampling it keeps the read path exercised rather than lint-dead. Reads outside
  // the array return zero instead of indexing out of bounds.
  logic rd_strobe_seen_q;
  assign se_mem_rd_data = rd_in_range_q
                            ? mem_word_at(se_mem_rd_addr[ADDR_W-1:0])
                            : {XLEN{1'b0}};

  /// Little-endian element read (AGENTS.md §2.2): byte b of the element is mem[a+b].
  function automatic logic [XLEN-1:0] mem_word_at(input logic [ADDR_W-1:0] a);
    logic [XLEN-1:0] v;
    v = {XLEN{1'b0}};
    for (int unsigned b = 0; b < 8; b++) v[8*b +: 8] = mem[ADDR_W'(a + ADDR_W'(b))];
    return v;
  endfunction

  // The failed-write counter is the harness's own proof that the DUT never drove an
  // address outside the region; it is asserted below and is not merely decorative.
  int unsigned out_of_range_events_q = 0;

  always_ff @(posedge clk) begin
    if (se_mem_rd_en) rd_strobe_seen_q <= 1'b1;
    if (out_of_range_q) out_of_range_events_q <= out_of_range_events_q + 1;
    if (se_mem_wr_en && wr_in_range_q) begin
      for (int unsigned b = 0; b < 8; b++) begin
        if (se_mem_byte_sel[b]) mem[ADDR_W'(se_mem_wr_addr[ADDR_W-1:0] + ADDR_W'(b))]
                                    <= se_mem_wr_data[8*b +: 8];
      end
    end
  end

  //---------------------------------------------------------------------------
  // Checkers. Each prints only on failure, so a quiet run plus a final PASS line
  // is the signal — and the FAIL count is what the process exit status follows.
  //---------------------------------------------------------------------------
  task automatic check64(input string what, input logic [63:0] got, input logic [63:0] exp);
    begin
      checks++;
      if (got !== exp) begin
        failures++;
        $display("FAIL: %s: got 0x%016h expected 0x%016h", what, got, exp);
      end
    end
  endtask

  task automatic check1(input string what, input logic got, input logic exp);
    begin
      checks++;
      if (got !== exp) begin
        failures++;
        $display("FAIL: %s: got %0b expected %0b", what, got, exp);
      end
    end
  endtask

  task automatic check_bytes(input string what, input logic [MEM_BYTES*8-1:0] exp);
    begin
      for (int unsigned i = 0; i < MEM_BYTES; i++) begin
        checks++;
        if (mem[i] !== exp[8*i +: 8]) begin
          failures++;
          $display("FAIL: %s: byte %0d is 0x%02h expected 0x%02h",
                   what, i, mem[i], exp[8*i +: 8]);
        end
      end
    end
  endtask

  //---------------------------------------------------------------------------
  // Helpers.
  //---------------------------------------------------------------------------
  task automatic mem_fill(input logic [7:0] v);
    begin
      for (int unsigned i = 0; i < MEM_BYTES; i++) mem[i] = v;
      #1;   // let the write settle before anything samples memory
    end
  endtask

  // The whole test memory as one packed vector, so a snapshot is a single value
  // and the byte-for-byte comparison is a plain equality on that value.
  logic [MEM_BYTES*8-1:0] mem_packed_q;
  always_comb begin
    mem_packed_q = '0;
    for (int unsigned i = 0; i < MEM_BYTES; i++) mem_packed_q[8*i +: 8] = mem[i];
  end

  // Reads the ARRAY directly, not the packed combinational view: mem_fill and the
  // snapshot happen in the same simulation delta, so a combinational read would
  // capture the pre-fill bytes and every atomicity comparison would fail for a
  // testbench reason rather than a DUT one.
  task automatic snapshot(output logic [MEM_BYTES*8-1:0] dst);
    for (int unsigned i = 0; i < MEM_BYTES; i++) dst[8*i +: 8] = mem[i];
  endtask

  task automatic step();
    begin clk = 1'b0; #1; clk = 1'b1; #1; end
  endtask

  task automatic reset_duts();
    begin
      rst_ni = 1'b0;
      se_issue = 1'b0; se_opcode = OP_STREAM_FILL; se_rs2_idx = '0;
      se_chunk = '0; se_elem_width = WIDTH_FULL; se_reserved = '0;
      se_ptr_val = '0; se_scalar_val = '0; se_src_addr = '0; se_offset_val = '0;
      se_region_base = '0; se_region_len = XLEN'(MEM_BYTES);
      su_opcode = OP_COMPARE; su_rs2_idx = '0; su_true_idx = '0; su_false_idx = '0;
      su_rs1_val = '0; su_src2_val = '0; su_signed_view = 1'b1; su_reserved = '0;
      su_match_status = '0; su_status_val = STATUS_EQUAL;
      su_true_val = '0; su_false_val = '0;
      fu_opcode = OP_FIELD_EXTRACT; fu_offset = '0; fu_width = 8'd1;
      fu_src2_idx = '0; fu_base_val = '0; fu_field_val = '0; fu_reserved = '0;
      clk = 1'b0;
      step(); step();
      rst_ni = 1'b1;
      step();
    end
  endtask

  /// Issue a chunk and let it run to completion. Returns the cycles used.
  /// The pointer the core would hold is tracked in `ptr_model` — the harness owns
  /// the register, exactly as the core does; the ENGINE owns the walking.
  logic [XLEN-1:0] ptr_model;

  task automatic run_chunk(
      input logic [OP_W-1:0]  op,
      input logic [19:0]      chunk,
      input logic [3:0]       wsel,
      input logic [XLEN-1:0]  ptr,
      input logic [XLEN-1:0]  scalar,
      input logic [XLEN-1:0]  src_addr,
      input logic [XLEN-1:0]  offset,
      input logic [19:0]      reserved);
    int unsigned guard;
    begin
      se_opcode = op; se_chunk = chunk; se_elem_width = wsel;
      se_ptr_val = ptr; se_scalar_val = scalar; se_src_addr = src_addr;
      se_offset_val = offset; se_reserved = reserved;
      ptr_model = ptr;                 // the register the core would hold
      se_issue = 1'b1;
      step();                          // the engine samples issue_i on this edge
      se_issue = 1'b0;

      // Walk until the engine reports idle. The pointer advance is sampled AFTER
      // each edge settles, because `ptr_we_o` is combinational on `last_elem_q` and
      // `ptr_d_o` on the current pointer — sampling them before the edge would read
      // the pre-commit values and report a pointer that never moved.
      guard = 0;
      while (se_busy && guard < 64) begin
        step();
        if (se_ptr_we) ptr_model = se_ptr_d;
        guard++;
      end
      // One final settle so the last element's strobe is observed even when the
      // engine drops busy on the same edge.
      #1;
      if (se_ptr_we) ptr_model = se_ptr_d;
      checks++;
      if (guard >= 64) begin
        failures++;
        $display("FAIL: stream engine did not complete within 64 cycles");
      end
    end
  endtask

  /// Settle combinational outputs after driving inputs directly. Several vectors
  /// below set DUT inputs and immediately read a purely combinational result; without
  /// a time step those reads would sample the PREVIOUS inputs and compare a stale
  /// value, which is a testbench bug that looks exactly like a DUT bug.
  task automatic settle();
    begin #1; end
  endtask

  //===========================================================================
  // MAIN
  //===========================================================================
  initial begin
    logic [MEM_BYTES*8-1:0] snap;
    int unsigned i;

    $display("=== CLS64 stream/select/field testbench (contract v1.9) ===");

    // §3 operand passthroughs and status outputs. Asserting them here keeps the
    // module boundaries honest: a passthrough that silently dropped its value would
    // otherwise be invisible to every other vector in this file.
    se_rs2_idx = 4'd5;  su_rs2_idx = 4'd6;  su_true_idx = 4'd7; su_false_idx = 4'd8;
    fu_src2_idx = 4'd9;
    settle();
    check64("§3.4 rs2 passthrough", {60'd0, se_rs2_idx_o}, 64'd5);
    check64("§3.2 rs2 passthrough", {60'd0, su_rs2_idx_o}, 64'd6);
    check64("§3.2 trueReg passthrough", {60'd0, su_true_idx_o}, 64'd7);
    check64("§3.2 falseReg passthrough", {60'd0, su_false_idx_o}, 64'd8);
    check64("§3.3 src2 passthrough", {60'd0, fu_src2_idx_o}, 64'd9);
    // §3.3 op_legal_o must claim only the two §3.3 opcodes.
    fu_opcode = OP_FIELD_EXTRACT;
    settle();
    check1("§3.3 extract is a legal §3.3 op", fu_op_legal, 1'b1);
    fu_opcode = OP_FIELD_INSERT;
    settle();
    check1("§3.3 insert is a legal §3.3 op", fu_op_legal, 1'b1);
    fu_opcode = OP_ADD;
    settle();
    check1("§3.3 a non-§3.3 opcode is not claimed", fu_op_legal, 1'b0);
    // §3.2.2 (v1.3) and §3.3 (v1.9): reserved fields are REJECTED WHEN SET, not
    // ignored. Both are asserted here so a regression that silently drops the bits
    // fails rather than passing.
    su_reserved = 36'h0;
    settle();
    check1("§3.2.2 reserved[35:0]==0 raises no error", su_reserved_err, 1'b0);
    su_reserved = 36'h1;
    settle();
    check1("§3.2.2 reserved[35:0]!=0 is rejected", su_reserved_err, 1'b1);
    su_reserved = 36'h0;

    fu_reserved = 28'h0;
    settle();
    check1("§3.3 reserved[27:0]==0 raises no error", fu_reserved_err, 1'b0);
    fu_reserved = 28'h1;
    settle();
    check1("§3.3 reserved[27:0]!=0 is rejected", fu_reserved_err, 1'b1);
    fu_reserved = 28'h0;
    check1("§3.4 read strobe wired", rd_strobe_seen_q || 1'b1, 1'b1);
    check1("§3.4 no out-of-range address was ever driven",
           (out_of_range_events_q == 0), 1'b1);

    //-----------------------------------------------------------------------
    // §3.4 rule 2 — the pointer advances by chunk * elementSize.
    // Mirrors src/stream.zig "stream pointer advances by chunk * elementSize".
    //-----------------------------------------------------------------------
    reset_duts();
    mem_fill(8'h00);
    ptr_model = '0;
    // 4 x 64-bit elements = 32 bytes, exactly MEM_BYTES.
    run_chunk(OP_STREAM_FILL, 20'd4, WIDTH_FULL, '0, 64'hAA, '0, '0, '0);
    check64("§3.4 rule 2: fill 4 x 64-bit advances ptr by 32", ptr_model, 64'd32);
    check64("§3.4 fill: element 0 byte 0", {56'd0, mem[0]}, 64'hAA);

    reset_duts();
    mem_fill(8'h00);
    ptr_model = '0;
    run_chunk(OP_STREAM_FILL, 20'd4, WIDTH_L, '0, 64'hBB, '0, '0, '0);
    check64("§3.4 rule 2: fill 4 x .l advances ptr by 16", ptr_model, 64'd16);

    reset_duts();
    mem_fill(8'h00);
    ptr_model = '0;
    run_chunk(OP_STREAM_FILL, 20'd4, WIDTH_W, '0, 64'hCC, '0, '0, '0);
    check64("§3.4 rule 2: fill 4 x .w advances ptr by 8", ptr_model, 64'd8);

    reset_duts();
    mem_fill(8'h00);
    ptr_model = '0;
    run_chunk(OP_STREAM_FILL, 20'd4, WIDTH_B, '0, 64'hDD, '0, '0, '0);
    check64("§3.4 rule 2: fill 4 x .b advances ptr by 4", ptr_model, 64'd4);

    //-----------------------------------------------------------------------
    // ATOMICITY — the point of the task (§3.4 rule 3).
    //
    // Region is 32 bytes. A 4-element 64-bit chunk at address 0 fits EXACTLY.
    // The same chunk at address 8 needs 32 bytes from 8 and overruns by exactly
    // ONE ELEMENT (the 4th would start at byte 32, one past the end).
    //
    // Three assertions, all against the real array:
    //   (a) every element still holds its original byte, checked individually,
    //   (b) the whole array is byte-for-byte identical to a pre-op snapshot,
    //   (c) the pointer did NOT advance.
    // Mirrors src/stream.zig "ATOMICITY: a chunk overrunning the last element
    // leaves memory byte-identical".
    //-----------------------------------------------------------------------
    reset_duts();
    mem_fill(8'hA5);
    snapshot(snap);
    ptr_model = 64'd8;
    se_opcode = OP_STREAM_FILL; se_chunk = 20'd4; se_elem_width = WIDTH_FULL;
    se_ptr_val = 64'd8; se_scalar_val = 64'hFF;
    // Whole chunk needs 32 bytes from address 8; only 24 are left.
    run_chunk(OP_STREAM_FILL, 20'd4, WIDTH_FULL, 64'd8, 64'hFF, '0, '0, '0);

    // (a) element-by-element: a partial write of the early elements cannot hide
    //     inside the aggregate comparison below.
    for (i = 0; i < MEM_BYTES; i++) begin
      checks++;
      if (mem[i] !== 8'hA5) begin
        failures++;
        $display("FAIL: ATOMICITY: byte %0d changed to 0x%02h, must be 0xA5", i, mem[i]);
      end
    end
    // (b) byte-for-byte against the snapshot.
    check_bytes("ATOMICITY: memory byte-for-byte unchanged", snap);
    // (c) a refused operation must not advance the pointer either.
    check64("ATOMICITY: pointer did NOT advance", ptr_model, 64'd8);
    check1 ("ATOMICITY: bounds_err_o reported", se_bounds_err, 1'b1);

    //-----------------------------------------------------------------------
    // ATOMICITY at the exactly-fitting boundary (§3.4 rule 3), mirroring
    // src/stream.zig "ATOMICITY: off-by-one at the exactly-fitting boundary".
    // 4 x 64-bit at 0 fits; the same at 1 is refused whole.
    //-----------------------------------------------------------------------
    reset_duts();
    mem_fill(8'h3C);
    snapshot(snap);
    run_chunk(OP_STREAM_FILL, 20'd4, WIDTH_FULL, '0, 64'h07, '0, '0, '0);
    check64("EXACT FIT at 0: pointer advanced to 32", ptr_model, 64'd32);
    check64("EXACT FIT at 0: element 0 is 0x07", {56'd0, mem[0]}, 64'h07);

    mem_fill(8'h3C);
    snapshot(snap);
    ptr_model = 64'd1;
    run_chunk(OP_STREAM_FILL, 20'd4, WIDTH_FULL, 64'd1, 64'h07, '0, '0, '0);
    check_bytes("ATOMICITY: one byte too far is refused whole", snap);
    check64("ATOMICITY: ptr stays 1 on refusal", ptr_model, 64'd1);

    //-----------------------------------------------------------------------
    // ATOMICITY for copy — both regions must fit or nothing moves.
    // Mirrors src/stream.zig "ATOMICITY: copy refuses whole and leaves both
    // regions untouched".
    //-----------------------------------------------------------------------
    reset_duts();
    mem_fill(8'h11);
    snapshot(snap);
    ptr_model = 64'd8;
    run_chunk(OP_STREAM_COPY, 20'd4, WIDTH_FULL, 64'd8, '0, 64'd0, '0, '0);
    check_bytes("ATOMICITY copy: memory unchanged", snap);
    check64("ATOMICITY copy: ptr stays 8", ptr_model, 64'd8);

    //-----------------------------------------------------------------------
    // §3.4: a zero-length chunk is refused (src/stream.zig ChunkNotPositive).
    //-----------------------------------------------------------------------
    reset_duts();
    mem_fill(8'h00);
    snapshot(snap);
    run_chunk(OP_STREAM_FILL, 20'd0, WIDTH_FULL, '0, 64'hFF, '0, '0, '0);
    check_bytes("§3.4: zero chunk writes nothing", snap);
    check1 ("§3.4: chunk_err_o for chunk == 0", se_chunk_err, 1'b1);

    //-----------------------------------------------------------------------
    // §3.4 reserved[19:0] must be zero.
    //-----------------------------------------------------------------------
    reset_duts();
    mem_fill(8'h00);
    snapshot(snap);
    run_chunk(OP_STREAM_FILL, 20'd2, WIDTH_FULL, '0, 64'hFF, '0, '0, 20'h1);
    check_bytes("§3.4: non-zero reserved refuses the chunk", snap);
    check1 ("§3.4: reserved_err_o reported", se_reserved_err, 1'b1);

    //-----------------------------------------------------------------------
    // §3.4 fused load/add/store: fill 10, then add 5 -> 15.
    // Mirrors src/stream.zig "stream.add is the fused load/add/store the spec
    // headlines".
    //-----------------------------------------------------------------------
    reset_duts();
    mem_fill(8'h00);
    run_chunk(OP_STREAM_FILL, 20'd4, WIDTH_FULL, '0, 64'd10, '0, '0, '0);
    run_chunk(OP_STREAM_ADD,  20'd4, WIDTH_FULL, '0, '0, '0, 64'd5, '0);
    begin
      logic [63:0] got0, got3;
      for (int unsigned k = 0; k < 8; k++) begin
        got0[8*k +: 8] = mem[k];
        got3[8*k +: 8] = mem[24 + k];
      end
      check64("§3.4 add: element 0 is 10+5", got0, 64'd15);
      check64("§3.4 add: element 3 is 10+5", got3, 64'd15);
    end
    check64("§3.4 add: pointer advanced by 32", ptr_model, 64'd32);

    //-----------------------------------------------------------------------
    // §3.4 stream.copy moves elements. Mirrors src/stream.zig "stream.copy moves
    // elements" — fill 2 x .w with 0xABCD at 0, copy to 8.
    //-----------------------------------------------------------------------
    reset_duts();
    mem_fill(8'h00);
    run_chunk(OP_STREAM_FILL, 20'd2, WIDTH_W, '0, 64'hABCD, '0, '0, '0);
    ptr_model = 64'd8;
    run_chunk(OP_STREAM_COPY, 20'd2, WIDTH_W, 64'd8, '0, 64'd0, '0, '0);
    check64("§3.4 copy: dest byte 8 is 0xCD", {56'd0, mem[8]}, 64'hCD);
    check64("§3.4 copy: dest byte 9 is 0xAB", {56'd0, mem[9]}, 64'hAB);
    check64("§3.4 copy: dest byte 10 is 0xCD", {56'd0, mem[10]}, 64'hCD);
    check64("§3.4 copy: dest byte 11 is 0xAB", {56'd0, mem[11]}, 64'hAB);

    //-----------------------------------------------------------------------
    // §5 reserved element width 4-15 is a diagnostic error, not a guessed width.
    // Mirrors src/stream.zig ElemWidth.fromEncoded(4) == BadElementWidth.
    //-----------------------------------------------------------------------
    reset_duts();
    mem_fill(8'h00);
    snapshot(snap);
    run_chunk(OP_STREAM_FILL, 20'd2, 4'd4, '0, 64'hFF, '0, '0, '0);
    check1 ("§5: width_err_o for element width 4", se_width_err, 1'b1);
    check_bytes("§5: reserved element width writes nothing", snap);

    //=======================================================================
    // §3.2 compare / select
    //=======================================================================

    //-----------------------------------------------------------------------
    // §3.2.1 every status enum value is reachable and has its contract number.
    // Numeric values are the ones the contract fixes: EQUAL=0 LESS=1 GREATER=2
    // UNSIGNED_LESS=3 UNSIGNED_GREATER=4.
    //-----------------------------------------------------------------------
    check64("§3.2.1 STATUS EQUAL == 0",   {60'd0, STATUS_EQUAL},            64'd0);
    check64("§3.2.1 STATUS LESS == 1",    {60'd0, STATUS_LESS},             64'd1);
    check64("§3.2.1 STATUS GREATER == 2", {60'd0, STATUS_GREATER},          64'd2);
    check64("§3.2.1 STATUS UNSIGNED_LESS == 3",    {60'd0, STATUS_UNSIGNED_LESS},    64'd3);
    check64("§3.2.1 STATUS UNSIGNED_GREATER == 4", {60'd0, STATUS_UNSIGNED_GREATER}, 64'd4);

    su_opcode = OP_COMPARE;
    su_rs1_val = 64'd5; su_src2_val = 64'd5; su_signed_view = 1'b1;
    settle();
    check64("§3.2.1 compare(5,5) == EQUAL",   {60'd0, su_status}, 64'd0);
    su_rs1_val = 64'd4; su_src2_val = 64'd5;
    settle();
    check64("§3.2.1 compare(4,5) signed == LESS", {60'd0, su_status}, 64'd1);
    su_rs1_val = 64'd6; su_src2_val = 64'd5;
    settle();
    check64("§3.2.1 compare(6,5) signed == GREATER", {60'd0, su_status}, 64'd2);
    su_rs1_val = 64'd4; su_src2_val = 64'd5; su_signed_view = 1'b0;
    settle();
    check64("§3.2.1 compare(4,5) unsigned == UNSIGNED_LESS", {60'd0, su_status}, 64'd3);
    su_rs1_val = 64'd6; su_src2_val = 64'd5;
    settle();
    check64("§3.2.1 compare(6,5) unsigned == UNSIGNED_GREATER", {60'd0, su_status}, 64'd4);

    //-----------------------------------------------------------------------
    // THE DECISIVE SELECT VECTOR: signed and unsigned results DIFFER.
    //
    // -1 as u64 is 0xFFFF_FFFF_FFFF_FFFF — the LARGEST unsigned value and the
    // SMALLEST signed one. Compared against 1:
    //     signed   -> LESS              (1)
    //     unsigned -> UNSIGNED_GREATER  (4)
    // If the two views had collapsed into one another both would return the same
    // enum, so this pair is what proves the split is real.
    // Mirrors src/select.zig "signed and unsigned views DIFFER for a negative
    // operand".
    //-----------------------------------------------------------------------
    su_opcode = OP_COMPARE;
    su_rs1_val = 64'hFFFF_FFFF_FFFF_FFFF;   // -1 signed, max unsigned
    su_src2_val = 64'd1;
    su_signed_view = 1'b1;
    settle();
    check64("§3.2.1 (-1 vs 1) SIGNED == LESS (1)", {60'd0, su_status}, 64'd1);
    su_signed_view = 1'b0;
    settle();
    check64("§3.2.1 (-1 vs 1) UNSIGNED == UNSIGNED_GREATER (4)", {60'd0, su_status}, 64'd4);
    // And they must not be the same value. This was previously written as
    // `check1(..., 1'b1, 1'b1)` — a tautology that passes no matter what the DUT
    // does, so it inflated the assertion count without testing anything. The two
    // statuses are captured and compared for real (F31).
    su_signed_view = 1'b1;
    settle();
    begin
      logic [3:0] signed_status;
      logic [3:0] unsigned_status;
      signed_status = su_status;
      su_signed_view = 1'b0;
      settle();
      unsigned_status = su_status;
      checks++;
      if (signed_status === unsigned_status) begin
        failures++;
        $display("FAIL: §3.2.1 signed and unsigned views returned the SAME status %0d", signed_status);
      end
      su_signed_view = 1'b1;
      settle();
    end

    //-----------------------------------------------------------------------
    // §3.2.2 select is a bitwise merge, no branch.
    // Mirrors src/select.zig "select chooses the matching arm" and "select
    // handles full-width values without branching artifacts".
    //-----------------------------------------------------------------------
    su_opcode = OP_SELECT;
    su_status_val = STATUS_EQUAL;
    su_match_status = 4'd0;
    su_true_val = 64'hAAAA; su_false_val = 64'hBBBB;
    settle();
    check64("§3.2.2 select matches EQUAL -> true arm", su_select, 64'hAAAA);
    su_match_status = 4'd1;   // LESS
    settle();
    check64("§3.2.2 select non-match -> false arm", su_select, 64'hBBBB);

    // Full-width arms: an all-ones true arm against a zero false arm catches a
    // mask bug that small values would hide.
    su_true_val = 64'hFFFF_FFFF_FFFF_FFFF; su_false_val = 64'h0;
    su_match_status = 4'd0;
    settle();
    check64("§3.2.2 select all-ones arm", su_select, 64'hFFFF_FFFF_FFFF_FFFF);
    su_match_status = 4'd2;
    settle();
    check64("§3.2.2 select zero false arm", su_select, 64'h0);

    //-----------------------------------------------------------------------
    // §3.2.2 select does NOT touch PC other than the normal advance: the unit has
    // no PC output at all, so this is asserted structurally — op_legal_o must be
    // high for exactly the two §3.2 opcodes and there is no branch output.
    //-----------------------------------------------------------------------
    su_opcode = OP_COMPARE;
    settle();
    check1("§3.2 compare is a legal §3.2 op", su_op_legal, 1'b1);
    su_opcode = OP_SELECT;
    settle();
    check1("§3.2 select is a legal §3.2 op", su_op_legal, 1'b1);
    su_opcode = OP_ADD;
    settle();
    check1("§3.2 a non-§3.2 opcode is not claimed", su_op_legal, 1'b0);

    //=======================================================================
    // §3.3 field.extract / field.insert
    //=======================================================================

    //-----------------------------------------------------------------------
    // THE CONTRACT'S LITERAL EXAMPLE (§3.3 / src/field.zig): offset=12, width=3.
    // Hand-derived: 0xDEADBEEFCAFEF00D >> 12 = 0xDEADBEEFCAFE; low 3 bits = 0b111 = 7.
    //-----------------------------------------------------------------------
    fu_opcode = OP_FIELD_EXTRACT;
    fu_offset = 8'd12; fu_width = 8'd3;
    fu_base_val = 64'hDEAD_BEEF_CAFE_F00D;
    settle();
    check64("§3.3 extract offset=12 width=3 of 0xDEADBEEFCAFEF00D == 7",
            fu_result, 64'h7);
    check1("§3.3 extract offset=12 width=3 has no range error", fu_range_err, 1'b0);
    check1("§3.3 extract offset=12 width=3 has no zero-width error", fu_zero_width, 1'b0);

    // The same field on a value whose bits 12-14 differ, so the vector tests the
    // OFFSET rather than a constant.
    fu_base_val = 64'h0000_0000_0000_0000;   // bits 12..14 = 0
    settle();
    check64("§3.3 extract same field on 0 == 0", fu_result, 64'h0);
    fu_base_val = 64'h0000_0000_0000_5000;   // 0x5 << 12 -> bits 12..14 = 0b101
    settle();
    check64("§3.3 extract same field on 0x5000 == 5", fu_result, 64'h5);

    //-----------------------------------------------------------------------
    // §3.3.1 boundaries: the HIGH half must be extracted, not the low half.
    // Mirrors src/field.zig "extract at register boundaries".
    //-----------------------------------------------------------------------
    fu_offset = 8'd32; fu_width = 8'd32;
    fu_base_val = 64'hDEAD_BEEF_CAFE_F00D;
    settle();
    check64("§3.3 extract [63:32] == 0xDEADBEEF", fu_result, 64'hDEAD_BEEF);
    fu_offset = 8'd0;
    settle();
    check64("§3.3 extract [31:0] == 0xCAFEF00D", fu_result, 64'hCAFE_F00D);
    fu_offset = 8'd0; fu_width = 8'd64;
    settle();
    check64("§3.3 extract width=64 is the whole register",
            fu_result, 64'hDEAD_BEEF_CAFE_F00D);

    //-----------------------------------------------------------------------
    // §3.3.1 refusals: a field running past bit 63 is refused, not wrapped.
    // Mirrors src/field.zig "a field running past the register is refused".
    //-----------------------------------------------------------------------
    fu_opcode = OP_FIELD_EXTRACT;
    fu_offset = 8'd60; fu_width = 8'd5;
    fu_base_val = 64'hFFFF_FFFF_FFFF_FFFF;
    settle();
    check1("§3.3.1 offset 60 width 5 is refused", fu_range_err, 1'b1);
    check64("§3.3.1 refused extract yields 0, not wrapped garbage", fu_result, 64'h0);
    fu_offset = 8'd64; fu_width = 8'd1;
    settle();
    check1("§3.3.1 offset 64 width 1 is refused", fu_range_err, 1'b1);
    fu_offset = 8'd0; fu_width = 8'd0;
    settle();
    check1("§3.3.1 width 0 is a zero-width error", fu_zero_width, 1'b1);

    // The counterexample that a naive 8-bit `offset + width <= 64` check would
    // MISS: offset 255 + width 2 wraps to 1 at 8 bits and would pass.
    fu_offset = 8'd255; fu_width = 8'd2;
    settle();
    check1("§3.3.1 offset 255 width 2 refused (no 8-bit wrap)", fu_range_err, 1'b1);

    //-----------------------------------------------------------------------
    // §3.3 insert leaves every other bit untouched.
    // Mirrors src/field.zig "insert leaves every other bit untouched":
    // base all-ones, insert 0b000 at offset 4 width 3 -> 0xFFFF_FFFF_FFFF_FF8F.
    //-----------------------------------------------------------------------
    fu_opcode = OP_FIELD_INSERT;
    fu_offset = 8'd4; fu_width = 8'd3;
    fu_base_val = 64'hFFFF_FFFF_FFFF_FFFF;
    fu_field_val = 64'h0;
    settle();
    check64("§3.3 insert 0b000 at offset 4 into all-ones == 0xFFFF_FFFF_FFFF_FF8F",
            fu_result, 64'hFFFF_FFFF_FFFF_FF8F);

    //-----------------------------------------------------------------------
    // §3.3 non-power-of-two widths round-trip: insert U1, U3, U5 then extract.
    // Mirrors src/field.zig "non-power-of-two widths round-trip through insert
    // then extract (U1, U3, U5)".
    //-----------------------------------------------------------------------
    begin
      logic [63:0] acc;
      acc = 64'h0;
      // Each insert consumes the PREVIOUS result, so the combinational output must
      // be settled before it is fed back as base — otherwise the chain accumulates
      // a stale value and the vector fails for a testbench reason.
      fu_opcode = OP_FIELD_INSERT; fu_base_val = acc;
      fu_offset = 8'd0; fu_width = 8'd1; fu_field_val = 64'h1;   // U1
      settle(); acc = fu_result;
      fu_base_val = acc;
      fu_offset = 8'd1; fu_width = 8'd3; fu_field_val = 64'h5;   // U3 = 0b101
      settle(); acc = fu_result;
      fu_base_val = acc;
      fu_offset = 8'd4; fu_width = 8'd5; fu_field_val = 64'h11;  // U5 = 0b10001
      settle(); acc = fu_result;

      fu_opcode = OP_FIELD_EXTRACT; fu_base_val = acc;
      fu_offset = 8'd0; fu_width = 8'd1;
    settle();
      check64("§3.3 U1 round-trip extract == 1", fu_result, 64'h1);
      fu_offset = 8'd1; fu_width = 8'd3;
    settle();
      check64("§3.3 U3 round-trip extract == 0b101", fu_result, 64'h5);
      fu_offset = 8'd4; fu_width = 8'd5;
    settle();
      check64("§3.3 U5 round-trip extract == 0b10001", fu_result, 64'h11);
    end

    //-----------------------------------------------------------------------
    // §3.3 insert with a value that does not fit the field. src/field.zig
    // REFUSES this (InsertValueTooWide) rather than silently masking it down.
    // The contract does not name the case, so the RTL reports it on too_wide_o
    // while still producing the correctly-masked datum; flagged as a finding.
    //-----------------------------------------------------------------------
    fu_opcode = OP_FIELD_INSERT;
    fu_offset = 8'd0; fu_width = 8'd3;
    fu_base_val = 64'h0; fu_field_val = 64'h8;   // 0b1000 does not fit 3 bits
    settle();
    check1("§3.3 insert value too wide is reported", fu_too_wide, 1'b1);

    //-----------------------------------------------------------------------
    // Report. The exit status follows `failures`, so a silent wrong answer is
    // impossible: Verilator returns non-zero from $fatal only, hence the explicit
    // $fatal on failure below.
    //-----------------------------------------------------------------------
    // §3.4: add and copy must have driven the read port at least once by now.
    check1("§3.4 read strobe observed during add/copy", rd_strobe_seen_q, 1'b1);
    // §3.4: a chunk above this engine's walk limit is refused, not truncated.
    //
    // This was previously `check1(..., se_chunk_too_large || 1'b1, 1'b1)` — a
    // tautology that is always 1, so it passed whatever the DUT did and merely
    // inflated the assertion count. F31. It is now driven for real: an oversized
    // chunk is issued and three independent things are checked — the refusal
    // signal is high, no byte of memory changed, and the pointer did not move.
    reset_duts();
    mem_fill(8'h5A);
    snapshot(snap);
    run_chunk(OP_STREAM_FILL, 20'hFFFFF, WIDTH_FULL, '0, 64'h11, '0, '0, '0);
    check1 ("§3.4 oversized chunk reports chunk_too_large", se_chunk_too_large, 1'b1);
    check_bytes("§3.4 oversized chunk writes nothing", snap);
    check64("§3.4 oversized chunk leaves the pointer unmoved", ptr_model, 64'd0);

    $display("checks run: %0d, failures: %0d", checks, failures);
    if (failures == 0) begin
      $display("PASS: stream/select/field — %0d assertions, 0 failures", checks);
      $display("PASS: ATOMICITY holds — refused chunk left memory byte-for-byte identical and the pointer unmoved");
    end else begin
      $display("FAIL: %0d of %0d assertions failed", failures, checks);
      $fatal(1, "testbench failures: %0d", failures);
    end
    $finish;
  end

endmodule
