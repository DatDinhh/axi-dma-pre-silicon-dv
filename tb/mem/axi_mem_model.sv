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

  // READY generation
  logic wr_active, rd_active;

  always_comb begin
    axi.awready = (axi.rst_n && !wr_active && !axi.bvalid);
    axi.wready  = (axi.rst_n &&  wr_active && !axi.bvalid);
    axi.arready = (axi.rst_n && !rd_active);
  end

  // WRITE state
  logic [ID_WIDTH-1:0]    wr_id;
  logic [ADDR_WIDTH-1:0]  wr_addr_cur;
  logic [7:0]             wr_len;
  logic [2:0]             wr_size;
  logic [1:0]             wr_burst;
  int unsigned            wr_beats_left;
  bit                     wr_err;

  // READ state
  logic [ID_WIDTH-1:0]    rd_id;
  logic [ADDR_WIDTH-1:0]  rd_addr_cur;
  logic [7:0]             rd_len;
  logic [2:0]             rd_size;
  logic [1:0]             rd_burst;
  int unsigned            rd_beats_left;
  bit                     rd_err;

  always_ff @(posedge axi.clk) begin
    if (!axi.rst_n) begin
      wr_active     <= 1'b0;
      wr_id         <= '0;
      wr_addr_cur   <= '0;
      wr_len        <= 8'd0;
      wr_size       <= 3'd0;
      wr_burst      <= 2'b00;
      wr_beats_left <= 0;
      wr_err        <= 1'b0;

      axi.bvalid    <= 1'b0;
      axi.bresp     <= RESP_OKAY;
      axi.bid       <= '0;

      rd_active     <= 1'b0;
      rd_id         <= '0;
      rd_addr_cur   <= '0;
      rd_len        <= 8'd0;
      rd_size       <= 3'd0;
      rd_burst      <= 2'b00;
      rd_beats_left <= 0;
      rd_err        <= 1'b0;

      axi.rvalid    <= 1'b0;
      axi.rresp     <= RESP_OKAY;
      axi.rid       <= '0;
      axi.rdata     <= '0;
      axi.rlast     <= 1'b0;

    end else begin
      // B handshake
      if (axi.bvalid && axi.bready) axi.bvalid <= 1'b0;

      // Accept AW
      if (axi.awvalid && axi.awready) begin
        wr_active     <= 1'b1;
        wr_id         <= axi.awid;
        wr_addr_cur   <= axi.awaddr;
        wr_len        <= axi.awlen;
        wr_size       <= axi.awsize;
        wr_burst      <= axi.awburst;
        wr_beats_left <= int'(axi.awlen) + 1;
        wr_err        <= 1'b0;

        if (axi.awburst == BURST_WRAP) wr_err <= 1'b1;
        if ((1 << axi.awsize) > DATA_BYTES) wr_err <= 1'b1;

        if (!in_range_span(longint'(axi.awaddr),
                           longint'(int'(axi.awlen) + 1) * longint'(1 << axi.awsize))) begin
          wr_err <= 1'b1;
        end
      end

      // Accept W
      if (wr_active && axi.wvalid && axi.wready) begin
        bit last_beat;
        int unsigned beat_bytes;
        logic [ADDR_WIDTH-1:0] next_addr;

        beat_bytes = (1 << wr_size);
        last_beat  = (wr_beats_left == 1);

        write_word_with_strb(wr_addr_cur, axi.wdata, axi.wstrb, wr_err);

        if (last_beat && (axi.wlast !== 1'b1)) wr_err <= 1'b1;
        if (!last_beat && (axi.wlast === 1'b1)) wr_err <= 1'b1;

        next_addr = wr_addr_cur;
        if (wr_burst == BURST_INCR) next_addr = wr_addr_cur + beat_bytes[ADDR_WIDTH-1:0];

        if (last_beat) begin
          wr_active     <= 1'b0;
          wr_beats_left <= 0;

          axi.bvalid <= 1'b1;
          axi.bid    <= wr_id;
          axi.bresp  <= (wr_err ? RESP_SLVERR : RESP_OKAY);
        end else begin
          wr_beats_left <= wr_beats_left - 1;
          wr_addr_cur   <= next_addr;
        end
      end

      // R advance
      if (axi.rvalid && axi.rready) begin
        if (axi.rlast) begin
          axi.rvalid    <= 1'b0;
          axi.rlast     <= 1'b0;
          rd_active     <= 1'b0;
          rd_beats_left <= 0;
        end else begin
          int unsigned beat_bytes;
          logic [ADDR_WIDTH-1:0] next_addr;
          int unsigned next_beats;

          beat_bytes = (1 << rd_size);
          next_addr  = rd_addr_cur;
          if (rd_burst == BURST_INCR) next_addr = rd_addr_cur + beat_bytes[ADDR_WIDTH-1:0];

          next_beats = rd_beats_left - 1;

          rd_addr_cur   <= next_addr;
          rd_beats_left <= next_beats;

          if (!in_range_span(longint'(next_addr), longint'(DATA_BYTES))) rd_err <= 1'b1;

          axi.rid   <= rd_id;
          axi.rdata <= pack_word(next_addr);
          axi.rresp <= (rd_err ? RESP_SLVERR : RESP_OKAY);
          axi.rlast <= (next_beats == 1);
        end
      end

      // Accept AR
      if (axi.arvalid && axi.arready) begin
        rd_active     <= 1'b1;
        rd_id         <= axi.arid;
        rd_addr_cur   <= axi.araddr;
        rd_len        <= axi.arlen;
        rd_size       <= axi.arsize;
        rd_burst      <= axi.arburst;
        rd_beats_left <= int'(axi.arlen) + 1;
        rd_err        <= 1'b0;

        if (axi.arburst == BURST_WRAP) rd_err <= 1'b1;
        if ((1 << axi.arsize) > DATA_BYTES) rd_err <= 1'b1;

        if (!in_range_span(longint'(axi.araddr),
                           longint'(int'(axi.arlen) + 1) * longint'(1 << axi.arsize))) begin
          rd_err <= 1'b1;
        end

        axi.rvalid <= 1'b0;
      end

      // Issue first R
      if (rd_active && !axi.rvalid) begin
        if (!in_range_span(longint'(rd_addr_cur), longint'(DATA_BYTES))) rd_err <= 1'b1;

        axi.rvalid <= 1'b1;
        axi.rid    <= rd_id;
        axi.rdata  <= pack_word(rd_addr_cur);
        axi.rresp  <= (rd_err ? RESP_SLVERR : RESP_OKAY);
        axi.rlast  <= (rd_beats_left == 1);
      end
    end
  end

endmodule

`endif // AXI_MEM_MODEL_SV
