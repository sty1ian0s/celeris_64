//=============================================================================
// stream_engine.sv — CLS64 stream engine: stream.add / stream.copy / stream.fill
//
// Normative contract: docs/isa-encoding.md VERSION 1.14.
//   §3.4 Stream engine (high nibble 0x4), opcodes 0x40-0x42:
//        0x40 stream.add  — fused load / add / store over a chunk
//        0x41 stream.copy — fused load / store over a chunk
//        0x42 stream.fill — fused store of a scalar over a chunk
//   §3.4 operand layout for those three:
//        rs2[47:44] | chunk[43:24] | element width[23:20] | reserved[19:0]
//   §3.4 rules 1-4, normative:
//        1. applies to `chunk` consecutive elements starting at the pointer
//        2. the pointer register advances by chunk * elementSize afterwards
//        3. BOUNDS ARE CHECKED BEFORE ANY ELEMENT IS WRITTEN. If the whole chunk
//           does not fit, NO element is modified. Partial application is forbidden.
//        4. element order is ascending address and deterministic.
//   §5 Width Suffix Encoding reused as the element width selector (§3.4 defers to
//      it): 0 = 64-bit, 1 = .l 32-bit, 2 = .w 16-bit, 3 = .b 8-bit, 4-15 reserved.
//
// THE POINT OF THIS MODULE (spec §3.1, AGENTS.md §3.1):
//   The auto-incrementing pointer is HARDWARE STATE. Software does not maintain an
//   index, does not compute addresses and does not bound-check per element. If the
//   bounds check were per element, a refused chunk would leave a partially-updated
//   array and the caller could not tell how far the batch got — the exact failure
//   mode the primitive exists to remove. It is therefore expressed structurally:
//   ONE comparison drives ONE gate that enables ALL write strobes, and a refused
//   chunk never becomes active at all.
//
// FIDELITY (docs/isa-encoding.md §8): lint-verified specification + simulation.
// NEVER synthesized, never timing-closed, never on silicon. No frequency claimed.
//=============================================================================

module stream_engine
  import celeris64_pkg::*;
(
  input  logic                  clk_i,
  input  logic                  rst_ni,          // synchronous, active-low

  // ---- §3.4 operation issue -------------------------------------------------
  input  logic                  issue_i,         // one-cycle strobe: start this chunk
  input  logic [OP_W-1:0]       opcode_i,        // §3.4 0x40 add / 0x41 copy / 0x42 fill
  input  logic [RS2_W-1:0]      rs2_idx_i,       // §3.4 rs2[47:44]: second operand index
  input  logic [19:0]           chunk_i,         // §3.4 chunk[43:24]: element count, >= 1
  input  logic [ALUWIDTH_W-1:0] elem_width_raw_i,// §3.4 operand[23:20] -> §5 selector
  input  logic [19:0]           reserved_i,      // §3.4 reserved[19:0]: must be zero

  // ---- operands -------------------------------------------------------------
  input  logic [XLEN-1:0]       ptr_val_i,       // §3.4 rs1: current stream address
  input  logic [XLEN-1:0]       scalar_val_i,    // §3.4 rd: the scalar for fill
  input  logic [XLEN-1:0]       src_addr_i,      // §3.4 rs2 for copy: source address
  input  logic [XLEN-1:0]       offset_val_i,    // §3.4 rs2 for add: per-element addend

  // ---- §6 accessible region (capability base/length, enforced here) ---------
  input  logic [XLEN-1:0]       region_base_i,   // §6 capability base
  input  logic [XLEN-1:0]       region_len_i,    // §6 accessible byte count

  // ---- flat memory port (strobe is high only for a committed, in-bounds chunk)
  //
  // Interface decision, stated because it was previously ambiguous: this is a
  // full-width data port with per-byte lane enables — the standard memory-port
  // pattern. `mem_wr_addr_o` is the ADDRESS OF THE ELEMENT and `mem_wr_data_o` is
  // the XLEN-wide element value; `mem_byte_sel_o[b]` says whether byte `b` of that
  // element is written, at `mem_wr_addr_o + b`. Lane b is byte b of the
  // little-endian element (AGENTS.md §2.2).
  //
  // An earlier revision exposed a single BYTE plus the same 8-bit lane mask. That is
  // genuinely ambiguous — one byte cannot express a 64-bit element, so a consumer
  // must guess whether the mask is lane-enables or an address stride, and one guess
  // replicates a byte across eight addresses. The wide port removes the guess: the
  // mask is byte enables, full stop.
  output logic                  mem_wr_en_o,     // write strobe, byte enables in mem_byte_sel_o
  output logic [XLEN-1:0]       mem_wr_addr_o,   // element address (lane b lands at +b)
  output logic [XLEN-1:0]       mem_wr_data_o,   // XLEN-wide element value
  output logic [7:0]            mem_byte_sel_o,  // per-byte write enables (§1 / AGENTS.md §2.2)
  output logic                  mem_rd_en_o,     // read strobe
  output logic [XLEN-1:0]       mem_rd_addr_o,   // element address
  input  logic [XLEN-1:0]       mem_rd_data_i,   // XLEN-wide element read back

  // ---- pointer (HARDWARE STATE, §3.4 rule 2) --------------------------------
  // `ptr_val_i` is the pointer register's CURRENT value and is the single source of
  // the stream address. There is deliberately no second pointer input: §3.4 rule 2
  // says the pointer advances by chunk*elementSize, and a module with two pointer
  // ports could disagree with itself about which one the advance is relative to.
  output logic [XLEN-1:0]       ptr_d_o,         // next pointer value
  output logic                  ptr_we_o,        // commit the advance

  // ---- status / diagnostics (§7: each gets its own name, never a bare code) --
  output logic                  busy_o,          // chunk in flight; issue_i ignored
  output logic                  chunk_err_o,     // §3.4: chunk == 0 is a mistake
  output logic                  width_err_o,     // §5: element width 4-15 reserved
  output logic                  reserved_err_o,  // §3.4: reserved[19:0] != 0
  output logic                  bounds_err_o,    // §3.4 rule 3: refused whole
  output logic                  chunk_too_large_o,// §3.4: chunk exceeds this engine's walk
  output logic [RS2_W-1:0]      rs2_idx_o        // §3.4 rs2[47:44], passed through to the core
);

  //---------------------------------------------------------------------------
  // Widths. localparams only — no magic numbers scattered through the file.
  //---------------------------------------------------------------------------
  localparam int unsigned ELEM_IDX_W  = 3;    // element counter within one chunk
  localparam int unsigned CHUNK_W     = 20;   // §3.4 chunk[43:24]
  localparam int unsigned BYTE_LANES  = 8;    // §1: 64-bit data word = 8 byte lanes
  localparam int unsigned SPAN_W      = XLEN + CHUNK_W + 3; // 20-bit chunk * 8-byte elem

  // Elements this engine walks in one pass: 2^ELEM_IDX_W. See the limit note below.
  localparam logic [CHUNK_W-1:0] WALK_LIMIT =
      CHUNK_W'({{(CHUNK_W-ELEM_IDX_W-1){1'b0}}, {ELEM_IDX_W{1'b1}}} + CHUNK_W'(1));

  //---------------------------------------------------------------------------
  // §3.4 element-width decode, reusing the §5 selector verbatim. A reserved value
  // (4-15) is a diagnostic error, not a silently-guessed width — the same refusal
  // src/stream.zig `ElemWidth.fromEncoded` implements.
  //---------------------------------------------------------------------------
  // The byte-lane view is all this engine needs of the §5 element mask: a sub-word
  // element occupies its low lanes and a 64-bit element uses all eight. The mask is
  // narrowed to BYTE_LANES here rather than carried at full XLEN, because the wider
  // form has no use in a byte-lane write path.
  logic [BYTE_LANES-1:0] lane_msk_q;  // byte-enable mask of one element
  logic [6:0]      width_bits_q;   // element size in BITS (64 needs 7 bits)
  logic            width_legal_q;
  width_e          elem_width_q;


  //---------------------------------------------------------------------------
  // §3.4 rule 3 — THE ATOMICITY GATE.
  //
  // This is the SINGLE comparison that decides whether the whole chunk is applied.
  // It is computed once, from the chunk size and the pointer, before any element is
  // touched, and it gates ALL write strobes below. There is deliberately no
  // per-element bounds test anywhere in this file.
  //
  // Saturation is applied on every address addition: §6 says an access that runs
  // past the region must FAIL, never wrap. A wrapping adder would turn an enormous
  // chunk into a small in-bounds span and admit a write past the end of memory.
  // src/memory.zig `inBounds` uses a saturating add for exactly the same reason.
  //
  // The saturation is written out explicitly rather than using SystemVerilog's `+|`
  // operator. FINDING: Verilator 5.49 (this repo's toolchain) MIS-SIMULATES `+|` —
  // `64'd0 +| 64'd32` evaluates to 1, not 32 — so a design written with the operator
  // is silently wrong under the only simulator available here. The explicit
  // widen-and-clamp below is equivalent and measured correct.
  //---------------------------------------------------------------------------
  logic [SPAN_W-1:0] chunk_span_q;      // chunk * elementSize, in bytes
  logic [XLEN-1:0]   span_bytes_q;      // that span reduced to 64 bits
  logic              span_overflow_q;   // span does not fit in 64 bits
  logic [XLEN-1:0]   chunk_end_q;       // ptr + span, saturating
  logic [XLEN-1:0]   region_end_q;      // base + len,  saturating
  logic              fits_q;            // whole chunk lies inside the region
  logic [XLEN-1:0]   ptr_commit_q;      // pointer value once the chunk commits
  logic              chunk_ok_q;        // legal, walkable, in-bounds — accept predicate

  /// §6 saturating add: `a + b`, clamped to all-ones instead of wrapping.
  /// Written explicitly because Verilator 5.49 mis-simulates the `+|` operator
  /// (measured: 0 +| 32 == 1). A wrap here would admit an out-of-bounds write, so
  /// the clamp is not optional.
  function automatic logic [XLEN-1:0] sat_add(input logic [XLEN-1:0] a,
                                              input logic [XLEN-1:0] b);
    logic [XLEN:0] wide;
    wide = {1'b0, a} + {1'b0, b};
    return wide[XLEN] ? {XLEN{1'b1}} : wide[XLEN-1:0];
  endfunction

  always_comb begin
    // §5: the low 2 bits select the width; 0 = 64-bit, 1 = .l, 2 = .w, 3 = .b.
    elem_width_q  = width_e'(elem_width_raw_i[1:0]);
    width_legal_q = width_enc_is_legal(elem_width_raw_i);        // §5: 0..3 legal
    width_bits_q  = width_bits(elem_width_q);
    lane_msk_q    = width_mask(elem_width_q)[BYTE_LANES-1:0];  // §5 byte lanes

    // chunk * elementSize. The element size in bytes is width_bits >> 3 (§5 sizes
    // are 64/32/16/8 bits, so the divide is exact). Multiplied at SPAN_W so a 20-bit
    // chunk times an 8-byte element cannot wrap the multiplication itself.
    chunk_span_q = {1'b0, chunk_i} * SPAN_W'({4'd0, width_bits_q} >> 3);

    span_overflow_q = |chunk_span_q[SPAN_W-1:XLEN];
    span_bytes_q    = chunk_span_q[XLEN-1:0];

    // §3.4 rule 3 + §6: the whole chunk must lie inside [base, base+len).
    chunk_end_q  = sat_add(ptr_val_i,     span_bytes_q);
    region_end_q = sat_add(region_base_i, region_len_i);

    fits_q = !span_overflow_q                        // the span itself fits in 64 bits
          && (chunk_i != {CHUNK_W{1'b0}})            // §3.4: chunk must be >= 1
          && (ptr_val_i >= region_base_i)            // not below the region base
          && (chunk_end_q <= region_end_q)           // last byte is inside the region
          && (sat_add(ptr_val_i, span_bytes_q) > ptr_val_i); // no address wrap (§6)

    // §3.4 rule 2: the ONLY pointer arithmetic in the architecture's batch path.
    ptr_commit_q = sat_add(ptr_val_i, span_bytes_q);

    // Accept only a fully-valid chunk. A refused chunk never becomes active, so it
    // can never emit a strobe and never advances the pointer (§3.4 rule 3).
    chunk_ok_q = fits_q && width_legal_q
              && (reserved_i == {CHUNK_W{1'b0}})     // §3.4 reserved[19:0] must be zero
              && (chunk_i <= WALK_LIMIT);            // see the limit note below
  end

  //---------------------------------------------------------------------------
  // LIMIT (reported as a finding, not hidden): §3.4's chunk field is 20 bits — up
  // to 1,048,575 elements — but this engine walks ONE ELEMENT PER CYCLE and its
  // counter is ELEM_IDX_W bits, so it can walk at most WALK_LIMIT elements in a
  // pass. A larger chunk is REFUSED on chunk_too_large_o rather than silently
  // truncated: truncating would write the wrong range of memory and still report
  // success, which is precisely the class of bug §3.4 exists to eliminate.
  // Nothing in §3.4 requires a cycle count, so widening the counter is a resource
  // decision for the implementer, not a contract ambiguity.
  //---------------------------------------------------------------------------
  assign chunk_too_large_o = (chunk_i > WALK_LIMIT);

  //---------------------------------------------------------------------------
  // Address generation, §3.4 rule 4: elements are processed in ASCENDING ADDRESS
  // order and the engine walks one element per cycle, so the element offset is the
  // counter times the element size — a multiplier, not a comparator tree.
  //---------------------------------------------------------------------------
  logic                active_q;       // a committed chunk is streaming
  logic [ELEM_IDX_W-1:0] elem_idx_q;   // element currently being addressed
  logic                last_elem_q;    // this is the final element of the chunk
  logic [XLEN-1:0]     elem_off_q;     // byte offset of the current element
  logic [XLEN-1:0]     elem_addr_q;    // address of the current element

  always_comb begin
    // Element size in bytes = width_bits >> 3 (§5 sizes are exactly 8/16/32/64 bits).
    elem_off_q  = {58'd0, elem_idx_q} * ({57'd0, width_bits_q} >> 3);
    elem_addr_q = sat_add(ptr_val_i, elem_off_q);
    // WALK_LIMIT <= 8, so the chunk fits the 3-bit counter exactly and the final
    // element is reached when the counter equals chunk-1.
    last_elem_q = active_q && (elem_idx_q == ELEM_IDX_W'(chunk_i[ELEM_IDX_W-1:0] - 1'b1));
  end

  assign busy_o   = active_q;
  assign ptr_d_o  = ptr_commit_q;
  // §3.4 rule 2: the advance commits once, on the final element, and only ever for
  // a chunk that was accepted — so a refused chunk leaves the pointer untouched.
  assign ptr_we_o = last_elem_q;

  //---------------------------------------------------------------------------
  // §1 / AGENTS.md §2.2: strict little-endian. A sub-word element occupies its low
  // byte lanes; a 64-bit element uses all eight. The byte lanes are the LSB-first
  // view of the §5 width mask, so lane i is byte i of the little-endian element.
  //---------------------------------------------------------------------------
  logic [BYTE_LANES-1:0] byte_sel_q;
  assign byte_sel_q = lane_msk_q;

  //---------------------------------------------------------------------------
  // Per-element write data, now full XLEN width (§3.4 + the interface note above).
  //
  // fill writes the scalar; add writes (loaded element + addend); copy writes the
  // loaded element. The §5 width is applied by `lane_msk_q` as byte enables, so a
  // .w element writes only its low two lanes and the upper bytes are untouched —
  // which is the correct sub-width semantics and the same zero-extend-free partial
  // store a byte-enabled memory performs.
  //
  // The addend is applied at element width, truncated to the element's byte count,
  // matching src/stream.zig `add`, which adds `@truncate(offset)` at the element's
  // own width (u8/u16/u32/u64) rather than at 64 bits.
  //---------------------------------------------------------------------------
  logic [XLEN-1:0] wr_data_q;
  logic [XLEN-1:0] addend_masked_q;

  assign addend_masked_q = offset_val_i & width_mask(elem_width_q);

  assign wr_data_q = (opcode_i == OP_STREAM_FILL)          // 0x42
                       ? scalar_val_i
                   : (opcode_i == OP_STREAM_ADD)           // 0x40 fused load/add/store
                       ? (mem_rd_data_i + addend_masked_q)
                       : mem_rd_data_i;                    // 0x41 fused load/store

  //===========================================================================
  // THE WRITE PATH. Every write strobe is ANDed with `active_q`, and `active_q`
  // can only be set for a chunk that passed the single atomicity gate above. There
  // is no path in this file that raises a strobe for a refused chunk, and no path
  // that stops part-way through an accepted one.
  //===========================================================================
  assign mem_wr_en_o    = active_q;
  assign mem_wr_addr_o  = elem_addr_q;
  assign mem_wr_data_o  = wr_data_q;
  assign mem_byte_sel_o = byte_sel_q;

  //---------------------------------------------------------------------------
  // Read port. fill has no source load; add and copy do.
  //---------------------------------------------------------------------------
  logic needs_load_q;
  assign needs_load_q = active_q
                     && ((opcode_i == OP_STREAM_ADD) || (opcode_i == OP_STREAM_COPY));
  assign mem_rd_en_o   = needs_load_q;
  assign mem_rd_addr_o = (opcode_i == OP_STREAM_COPY) ? sat_add(src_addr_i, elem_off_q)
                                                      : elem_addr_q;

  //---------------------------------------------------------------------------
  // Diagnostics, each with its own name so the core can render a sentence naming
  // the instruction and the operand (contract §7 — no bare hexadecimal code).
  //---------------------------------------------------------------------------
  assign chunk_err_o    = (chunk_i == {CHUNK_W{1'b0}});  // §3.4: chunk must be >= 1
  assign width_err_o    = !width_legal_q;                // §5: 4-15 reserved
  assign reserved_err_o = (reserved_i != {CHUNK_W{1'b0}}); // §3.4 reserved[19:0]
  assign bounds_err_o   = (chunk_i != {CHUNK_W{1'b0}}) && !fits_q; // §3.4 rule 3

  //---------------------------------------------------------------------------
  // Issue / walk state machine.
  //---------------------------------------------------------------------------
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      active_q   <= 1'b0;
      elem_idx_q <= '0;
    end else if (!active_q) begin
      if (issue_i && chunk_ok_q) begin
        active_q   <= 1'b1;    // accepted: the whole chunk will be applied
        elem_idx_q <= '0;
      end
    end else begin
      elem_idx_q <= elem_idx_q + ELEM_IDX_W'(1'b1);
      if (last_elem_q) active_q <= 1'b0;
    end
  end

  // §3.4: rs2[47:44] names the second operand register. The core resolves it to
  // `src_addr_i` (copy) or `offset_val_i` (add) before issuing; it is surfaced on
  // rs2_idx_o so the §3.4 operand wiring is visible at the module boundary instead
  // of resting on an unstated assumption about the caller.
  assign rs2_idx_o = rs2_idx_i;

endmodule
