//==============================================================================
// tb/mem/axi_mem_model.sv  (Intel ModelSim friendly)
//------------------------------------------------------------------------------
// AXI4 memory SLAVE model for DUT AXI master.
// Storage is provided by mem_bkdr_if so UVM tests can backdoor-init/compare.
//==============================================================================

`ifndef AXI_MEM_MODEL_SV
`define AXI_MEM_MODEL_SV

module axi_mem_model #(
  parameter int unsigned ADDR_WIDTH     = 32,
  parameter int unsigned DATA_WIDTH     = 32,
  parameter int unsigned ID_WIDTH       = 1,
  parameter int unsigned MEM_SIZE_BYTES = 64 * 1024,

  parameter bit INIT_MEM_ZERO           = 1'b1,
  parameter bit INIT_MEM_RANDOM         = 1'b0,
  parameter bit VERBOSE                 = 1'b0
)(
  axi_if      axi,
  mem_bkdr_if bkdr
);

  localparam int unsigned DATA_BYTES = (DATA_WIDTH/8);

  localparam logic [1:0] RESP_OKAY   = 2'b00;
  localparam logic [1:0] RESP_SLVERR = 2'b10;

  localparam logic [1:0] BURST_FIXED = 2'b00;
  localparam logic [1:0] BURST_INCR  = 2'b01;
  localparam logic [1:0] BURST_WRAP  = 2'b10;

  function automatic bit in_range_byte(input longint unsigned a);
    return (a < longint'(MEM_SIZE_BYTES));
  endfunction

  function automatic bit in_range_span(input longint unsigned base, input longint unsigned span_bytes);
    if (span_bytes == 0) return 1'b1;
    return (base < longint'(MEM_SIZE_BYTES)) &&
           ((base + span_bytes) <= longint'(MEM_SIZE_BYTES));
  endfunction

  function automatic logic [DATA_WIDTH-1:0] pack_word(input logic [ADDR_WIDTH-1:0] addr);
    logic [DATA_WIDTH-1:0] tmp;
    int unsigned i;
    longint unsigned a;
    begin
      tmp = '0;
      a = longint'(addr);
      for (i = 0; i < DATA_BYTES; i++) begin
        tmp[8*i +: 8] = (in_range_byte(a + i)) ? bkdr.mem[a + i] : 8'h00;
      end
      return tmp;
    end
  endfunction

  task automatic write_word_with_strb(
    input  logic [ADDR_WIDTH-1:0] addr,
    input  logic [DATA_WIDTH-1:0] data,
    input  logic [DATA_BYTES-1:0] strb,
    inout bit                     err
  );
    int unsigned i;
    longint unsigned a;
    begin
      a = longint'(addr);
      for (i = 0; i < DATA_BYTES; i++) begin
        if (strb[i]) begin
          if (in_range_byte(a + i)) bkdr.mem[a + i] = data[8*i +: 8];
          else err = 1'b1;
        end
      end
    end
  endtask

  int unsigned seed;
  initial begin : init_mem
    int unsigned i;
    if (INIT_MEM_ZERO) begin
      for (i = 0; i < MEM_SIZE_BYTES; i++) bkdr.mem[i] = 8'h00;
    end
    if (INIT_MEM_RANDOM) begin
      seed = 32'h1234_5678;
      void'($value$plusargs("MEM_RAND_SEED=%d", seed));
      for (i = 0; i < MEM_SIZE_BYTES; i++) bkdr.mem[i] = $urandom(seed);
    end
  end

  // Runtime stress controls. Error injection is address-matched on every
  // transaction, returns SLVERR, and does not suppress memory write effects.
  integer aw_wait_w = 0;
  integer stall_max = 0;
  integer stall_seed = 1;
  logic [ADDR_WIDTH-1:0] rerr_addr = '0, berr_addr = '0;
  bit rerr_enable = 0, berr_enable = 0;
  initial begin : configure_stress
    void'($value$plusargs("AXI_AW_WAIT_W=%d", aw_wait_w));
    void'($value$plusargs("AXI_STALL_MAX=%d", stall_max));
    void'($value$plusargs("AXI_STALL_SEED=%d", stall_seed));
    rerr_enable = $value$plusargs("AXI_RERR_ADDR=%h", rerr_addr);
    berr_enable = $value$plusargs("AXI_BERR_ADDR=%h", berr_addr);
    if (stall_max < 0 || stall_max > 1024)
      $fatal(1, "AXI_STALL_MAX must be in 0..1024");
    $display("AXI_MEM_CONFIG aw_wait_w=%0d stall_max=%0d stall_seed=%0d rerr=%0b@%h berr=%0b@%h",
      aw_wait_w, stall_max, stall_seed, rerr_enable, rerr_addr, berr_enable, berr_addr);
  end

  logic [31:0] stall_rng;
  integer aw_wait, w_wait, ar_wait, r_wait, b_wait;
  // A local LCG keeps memory timing independent of the UVM random stream.
  function automatic integer delay_cycles(input logic [31:0] entropy);
    return int'(entropy % (stall_max + 1));
  endfunction

  logic wr_active, rd_active, b_pending;
  always_comb begin
    axi.awready = axi.rst_n && !wr_active && !axi.bvalid && !b_pending &&
                  (aw_wait == 0) && (!aw_wait_w || axi.wvalid);
    axi.wready  = axi.rst_n && wr_active && !axi.bvalid && (w_wait == 0);
    axi.arready = axi.rst_n && !rd_active && (ar_wait == 0);
  end

  logic [ID_WIDTH-1:0]    wr_id;
  logic [ADDR_WIDTH-1:0]  wr_addr_cur;
  logic [2:0]             wr_size;
  logic [1:0]             wr_burst;
  int unsigned            wr_beats_left;
  bit                     wr_err;
  logic [ID_WIDTH-1:0]    rd_id;
  logic [ADDR_WIDTH-1:0]  rd_addr_cur;
  logic [2:0]             rd_size;
  logic [1:0]             rd_burst;
  int unsigned            rd_beats_left;
  bit                     rd_err;

  always_ff @(posedge axi.clk) begin
    if (!axi.rst_n) begin
      stall_rng     <= stall_seed;
      aw_wait       <= delay_cycles(stall_seed ^ 32'h13579bdf);
      ar_wait       <= delay_cycles(stall_seed ^ 32'h2468ace0);
      w_wait        <= 0;
      r_wait        <= 0;
      b_wait        <= 0;
      b_pending     <= 0;
      wr_active     <= 0;
      wr_id         <= '0;
      wr_addr_cur   <= '0;
      wr_size       <= 0;
      wr_burst      <= 0;
      wr_beats_left <= 0;
      wr_err        <= 0;
      axi.bvalid    <= 0;
      axi.bresp     <= RESP_OKAY;
      axi.bid       <= '0;
      rd_active     <= 0;
      rd_id         <= '0;
      rd_addr_cur   <= '0;
      rd_size       <= 0;
      rd_burst      <= 0;
      rd_beats_left <= 0;
      rd_err        <= 0;
      axi.rvalid    <= 0;
      axi.rresp     <= RESP_OKAY;
      axi.rid       <= '0;
      axi.rdata     <= '0;
      axi.rlast     <= 0;
    end else begin
      stall_rng <= (stall_rng * 32'd1664525) + 32'd1013904223;
      // Count only while a channel can make progress. Once zero, READY
      // remains available until handshake (subject to channel dependencies).
      if (!wr_active && !axi.bvalid && !b_pending && axi.awvalid && aw_wait > 0)
        aw_wait <= aw_wait - 1;
      if (wr_active && axi.wvalid && w_wait > 0) w_wait <= w_wait - 1;
      if (!rd_active && axi.arvalid && ar_wait > 0) ar_wait <= ar_wait - 1;

      if (axi.bvalid && axi.bready) axi.bvalid <= 0;
      if (b_pending && !axi.bvalid) begin
        if (b_wait > 0) b_wait <= b_wait - 1;
        else begin
          axi.bvalid <= 1;
          b_pending <= 0;
        end
      end

      if (axi.awvalid && axi.awready) begin
        wr_active     <= 1;
        wr_id         <= axi.awid;
        wr_addr_cur   <= axi.awaddr;
        wr_size       <= axi.awsize;
        wr_burst      <= axi.awburst;
        wr_beats_left <= int'(axi.awlen) + 1;
        aw_wait       <= delay_cycles(stall_rng ^ 32'h13579bdf);
        w_wait        <= delay_cycles(stall_rng ^ 32'hcafef00d);
        wr_err <= (axi.awburst == BURST_WRAP) ||
                  ((1 << axi.awsize) > DATA_BYTES) ||
                  !in_range_span(longint'(axi.awaddr),
                    longint'(int'(axi.awlen) + 1) * longint'(1 << axi.awsize)) ||
                  (berr_enable && axi.awaddr == berr_addr);
      end

      if (wr_active && axi.wvalid && axi.wready) begin
        bit last_beat;
        bit beat_err;
        int unsigned beat_bytes;
        beat_bytes = (1 << wr_size);
        last_beat = (wr_beats_left == 1);
        // Calculate the complete error before scheduling BRESP. Reading the
        // old wr_err after an NBA assignment hid an invalid final WLAST.
        beat_err = wr_err;
        write_word_with_strb(wr_addr_cur, axi.wdata, axi.wstrb, beat_err);
        if (axi.wlast !== last_beat) beat_err = 1;
        wr_err <= beat_err;
        if (last_beat) begin
          wr_active     <= 0;
          wr_beats_left <= 0;
          b_pending     <= 1;
          b_wait        <= delay_cycles(stall_rng ^ 32'h01234567);
          axi.bid       <= wr_id;
          axi.bresp     <= beat_err ? RESP_SLVERR : RESP_OKAY;
        end else begin
          wr_beats_left <= wr_beats_left - 1;
          w_wait        <= delay_cycles(stall_rng ^ 32'hcafef00d);
          if (wr_burst == BURST_INCR)
            wr_addr_cur <= wr_addr_cur + beat_bytes[ADDR_WIDTH-1:0];
        end
      end

      if (axi.rvalid && axi.rready) begin
        axi.rvalid <= 0;
        axi.rlast  <= 0;
        if (rd_beats_left == 1) begin
          rd_active <= 0;
          rd_beats_left <= 0;
        end else begin
          int unsigned beat_bytes;
          beat_bytes = (1 << rd_size);
          rd_beats_left <= rd_beats_left - 1;
          r_wait <= delay_cycles(stall_rng ^ 32'h76543210);
          if (rd_burst == BURST_INCR)
            rd_addr_cur <= rd_addr_cur + beat_bytes[ADDR_WIDTH-1:0];
        end
      end

      if (axi.arvalid && axi.arready) begin
        rd_active     <= 1;
        rd_id         <= axi.arid;
        rd_addr_cur   <= axi.araddr;
        rd_size       <= axi.arsize;
        rd_burst      <= axi.arburst;
        rd_beats_left <= int'(axi.arlen) + 1;
        ar_wait       <= delay_cycles(stall_rng ^ 32'h2468ace0);
        r_wait        <= delay_cycles(stall_rng ^ 32'h76543210);
        rd_err <= (axi.arburst == BURST_WRAP) ||
                  ((1 << axi.arsize) > DATA_BYTES) ||
                  !in_range_span(longint'(axi.araddr),
                    longint'(int'(axi.arlen) + 1) * longint'(1 << axi.arsize)) ||
                  (rerr_enable && axi.araddr == rerr_addr);
        axi.rvalid <= 0;
      end

      // Issue each beat only after its configured delay. Once VALID is high,
      // all payload is held unchanged until READY, even with backpressure.
      if (rd_active && !axi.rvalid) begin
        if (r_wait > 0) r_wait <= r_wait - 1;
        else begin
          bit beat_err;
          beat_err = rd_err ||
            !in_range_span(longint'(rd_addr_cur), longint'(DATA_BYTES));
          rd_err     <= beat_err;
          axi.rvalid <= 1;
          axi.rid    <= rd_id;
          axi.rdata  <= pack_word(rd_addr_cur);
          axi.rresp  <= beat_err ? RESP_SLVERR : RESP_OKAY;
          axi.rlast  <= (rd_beats_left == 1);
        end
      end
    end
  end
endmodule
`endif // AXI_MEM_MODEL_SV
