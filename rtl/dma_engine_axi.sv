//==============================================================================
// rtl/dma_engine_axi.sv
//------------------------------------------------------------------------------
// Simple AXI DMA engine (real transfers) - single-beat copy loop
//
// Behavior:
// - On start_req_pulse (when not busy), latch cfg_*
// - Validate:
//     * len != 0
//     * src/dst aligned to DATA_BYTES
//     * len multiple of DATA_BYTES
//     * src+len and dst+len within MEM_SIZE_BYTES (byte addressing, base=0)
// - If valid: issue repeated single-beat AXI reads/writes until complete
// - DONE/ERR are indicated via one-cycle pulses to the regs block
//
// AXI:
// - ARLEN/AWLEN = 0 (1 beat)
// - ARBURST/AWBURST = INCR
// - ARSIZE/AWSIZE = log2(DATA_BYTES)
// - One outstanding read beat + one outstanding write beat at a time
//
// ModelSim/Intel friendly:
// - No fancy SV features; pure FSM
//==============================================================================

`ifndef DMA_ENGINE_AXI_SV
`define DMA_ENGINE_AXI_SV

module dma_engine_axi #(
  parameter int unsigned ADDR_WIDTH      = 32,
  parameter int unsigned DATA_WIDTH      = 32,
  parameter int unsigned ID_WIDTH        = 1,
  parameter int unsigned MAX_BURST_BEATS = 16,        // unused in single-beat mode
  parameter int unsigned MEM_SIZE_BYTES  = 64*1024,
  parameter bit          ENABLE_4KB_RULE = 1'b1       // single-beat never crosses 4KB
)(
  input  logic                         clk,
  input  logic                         rst_n,

  // Config from regs
  input  logic [ADDR_WIDTH-1:0]        cfg_src_addr,
  input  logic [ADDR_WIDTH-1:0]        cfg_dst_addr,
  input  logic [31:0]                  cfg_len_bytes,
  input  logic                         start_req_pulse,

  // Status back to regs
  output logic                         engine_busy,
  output logic [31:0]                  engine_bytes_remain,

  // Event pulses to regs
  output logic                         start_accept_pulse,
  output logic                         set_done_pulse,
  output logic                         set_err_pulse,
  output logic [7:0]                   err_code_value,

  // AXI master interface
  output logic [ID_WIDTH-1:0]          m_axi_awid,
  output logic [ADDR_WIDTH-1:0]        m_axi_awaddr,
  output logic [7:0]                   m_axi_awlen,
  output logic [2:0]                   m_axi_awsize,
  output logic [1:0]                   m_axi_awburst,
  output logic                         m_axi_awlock,
  output logic [3:0]                   m_axi_awcache,
  output logic [2:0]                   m_axi_awprot,
  output logic [3:0]                   m_axi_awqos,
  output logic                         m_axi_awvalid,
  input  logic                         m_axi_awready,

  output logic [DATA_WIDTH-1:0]        m_axi_wdata,
  output logic [(DATA_WIDTH/8)-1:0]    m_axi_wstrb,
  output logic                         m_axi_wlast,
  output logic                         m_axi_wvalid,
  input  logic                         m_axi_wready,

  input  logic [ID_WIDTH-1:0]          m_axi_bid,
  input  logic [1:0]                   m_axi_bresp,
  input  logic                         m_axi_bvalid,
  output logic                         m_axi_bready,

  output logic [ID_WIDTH-1:0]          m_axi_arid,
  output logic [ADDR_WIDTH-1:0]        m_axi_araddr,
  output logic [7:0]                   m_axi_arlen,
  output logic [2:0]                   m_axi_arsize,
  output logic [1:0]                   m_axi_arburst,
  output logic                         m_axi_arlock,
  output logic [3:0]                   m_axi_arcache,
  output logic [2:0]                   m_axi_arprot,
  output logic [3:0]                   m_axi_arqos,
  output logic                         m_axi_arvalid,
  input  logic                         m_axi_arready,

  input  logic [ID_WIDTH-1:0]          m_axi_rid,
  input  logic [DATA_WIDTH-1:0]        m_axi_rdata,
  input  logic [1:0]                   m_axi_rresp,
  input  logic                         m_axi_rlast,
  input  logic                         m_axi_rvalid,
  output logic                         m_axi_rready
);

  //--------------------------------------------------------------------------
  // Localparams
  //--------------------------------------------------------------------------
  localparam int unsigned DATA_BYTES = (DATA_WIDTH/8);
  localparam int unsigned ALIGN_LSB  = (DATA_BYTES <= 1) ? 0 : $clog2(DATA_BYTES);

  localparam logic [1:0] RESP_OKAY   = 2'b00;
  localparam logic [1:0] RESP_SLVERR = 2'b10;

  localparam logic [1:0] BURST_INCR  = 2'b01;

  localparam logic [2:0] AXI_SIZE    = (DATA_BYTES == 1) ? 3'd0 :
                                       (DATA_BYTES == 2) ? 3'd1 :
                                       (DATA_BYTES == 4) ? 3'd2 :
                                       (DATA_BYTES == 8) ? 3'd3 :
                                       (DATA_BYTES == 16)? 3'd4 : 3'd2;

  // Share the software-visible encoding with the register/testbench package.
  localparam logic [7:0] ERR_NONE      = dma_pkg::ERR_NONE;
  localparam logic [7:0] ERR_LEN_ZERO  = dma_pkg::ERR_LEN_ZERO;
  localparam logic [7:0] ERR_ALIGN     = dma_pkg::ERR_ALIGN;
  localparam logic [7:0] ERR_RANGE     = dma_pkg::ERR_RANGE;
  localparam logic [7:0] ERR_AXI_RRESP = dma_pkg::ERR_AXI_RRESP;
  localparam logic [7:0] ERR_AXI_BRESP = dma_pkg::ERR_AXI_BRESP;
  localparam logic [7:0] ERR_AXI_PROTO = dma_pkg::ERR_AXI_PROTO;

  //--------------------------------------------------------------------------
  // Helpers
  //--------------------------------------------------------------------------
  function automatic bit is_aligned_addr(input logic [ADDR_WIDTH-1:0] a);
    if (ALIGN_LSB == 0) return 1'b1;
    return (a[ALIGN_LSB-1:0] == '0);
  endfunction

  function automatic bit is_aligned_len(input logic [31:0] len);
    if (ALIGN_LSB == 0) return 1'b1;
    return (len[ALIGN_LSB-1:0] == '0);
  endfunction

  function automatic bit in_range(input logic [ADDR_WIDTH-1:0] base, input logic [31:0] len);
    longint unsigned b;
    longint unsigned l;
    longint unsigned endp;
    begin
      b    = longint'(base);
      l    = longint'(len);
      endp = b + l;
      // allow len==0 to be checked elsewhere; range check should pass for len==0
      if (l == 0) return 1'b1;
      return (b < longint'(MEM_SIZE_BYTES)) && (endp <= longint'(MEM_SIZE_BYTES));
    end
  endfunction

  //--------------------------------------------------------------------------
  // FSM
  //--------------------------------------------------------------------------
  typedef enum logic [2:0] {
    ST_IDLE   = 3'd0,
    ST_AR     = 3'd1,
    ST_R      = 3'd2,
    ST_WRITE  = 3'd3,
    ST_B      = 3'd5,
    ST_DONE   = 3'd6,
    ST_ERR    = 3'd7
  } state_t;

  state_t state;

  logic [ADDR_WIDTH-1:0] src_addr_q, dst_addr_q;
  logic [31:0]           remain_q;

  // pulses
  logic start_accept_pulse_r, set_done_pulse_r, set_err_pulse_r;
  logic [7:0] err_code_r;

  assign start_accept_pulse = start_accept_pulse_r;
  assign set_done_pulse     = set_done_pulse_r;
  assign set_err_pulse      = set_err_pulse_r;
  assign err_code_value     = err_code_r;

  // status
  assign engine_busy         = (state != ST_IDLE);
  assign engine_bytes_remain = remain_q;

  //--------------------------------------------------------------------------
  // Default AXI sideband constants
  //--------------------------------------------------------------------------
  always_comb begin
    m_axi_awid    = '0;
    m_axi_awlen   = 8'd0;
    m_axi_awsize  = AXI_SIZE;
    m_axi_awburst = BURST_INCR;
    m_axi_awlock  = 1'b0;
    m_axi_awcache = 4'b0000;
    m_axi_awprot  = 3'b000;
    m_axi_awqos   = 4'b0000;

    m_axi_arid    = '0;
    m_axi_arlen   = 8'd0;
    m_axi_arsize  = AXI_SIZE;
    m_axi_arburst = BURST_INCR;
    m_axi_arlock  = 1'b0;
    m_axi_arcache = 4'b0000;
    m_axi_arprot  = 3'b000;
    m_axi_arqos   = 4'b0000;

    // addresses driven from regs in seq (m_axi_awaddr/m_axi_araddr are regs below)
    // data driven from regs in seq (m_axi_wdata/wstrb/wlast are regs below)
  end

  //--------------------------------------------------------------------------
  // Sequential: FSM + AXI valids/readies
  //--------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state   <= ST_IDLE;

      src_addr_q <= '0;
      dst_addr_q <= '0;
      remain_q   <= 32'd0;

      start_accept_pulse_r <= 1'b0;
      set_done_pulse_r     <= 1'b0;
      set_err_pulse_r      <= 1'b0;
      err_code_r           <= ERR_NONE;

      // AXI outputs
      m_axi_araddr  <= '0;
      m_axi_arvalid <= 1'b0;
      m_axi_rready  <= 1'b0;

      m_axi_awaddr  <= '0;
      m_axi_awvalid <= 1'b0;

      m_axi_wdata   <= '0;
      m_axi_wstrb   <= '0;
      m_axi_wlast   <= 1'b0;
      m_axi_wvalid  <= 1'b0;

      m_axi_bready  <= 1'b0;

    end else begin
      // default pulses low each cycle
      start_accept_pulse_r <= 1'b0;
      set_done_pulse_r     <= 1'b0;
      set_err_pulse_r      <= 1'b0;

      case (state)
        //============================================================
        // IDLE: wait for start pulse, validate, then kick off AR
        //============================================================
        ST_IDLE: begin
          // ensure AXI is quiet
          m_axi_arvalid <= 1'b0;
          m_axi_rready  <= 1'b0;
          m_axi_awvalid <= 1'b0;
          m_axi_wvalid  <= 1'b0;
          m_axi_bready  <= 1'b0;
          m_axi_wlast   <= 1'b0;

          remain_q <= 32'd0;
          err_code_r <= ERR_NONE;

          if (start_req_pulse) begin
            // Validate config
            if (cfg_len_bytes == 32'd0) begin
              err_code_r       <= ERR_LEN_ZERO;
              set_err_pulse_r  <= 1'b1;
              state            <= ST_IDLE;
            end else if (!is_aligned_addr(cfg_src_addr) ||
                         !is_aligned_addr(cfg_dst_addr) ||
                         !is_aligned_len(cfg_len_bytes)) begin
              err_code_r       <= ERR_ALIGN;
              set_err_pulse_r  <= 1'b1;
              state            <= ST_IDLE;
            end else if (!in_range(cfg_src_addr, cfg_len_bytes) ||
                         !in_range(cfg_dst_addr, cfg_len_bytes)) begin
              err_code_r       <= ERR_RANGE;
              set_err_pulse_r  <= 1'b1;
              state            <= ST_IDLE;
            end else begin
              // Accept start
              src_addr_q <= cfg_src_addr;
              dst_addr_q <= cfg_dst_addr;
              remain_q   <= cfg_len_bytes;

              start_accept_pulse_r <= 1'b1;

              // Start first read address
              m_axi_araddr  <= cfg_src_addr;
              m_axi_arvalid <= 1'b1;
              m_axi_rready  <= 1'b0;

              state <= ST_AR;
            end
          end
        end

        //============================================================
        // ST_AR: drive ARVALID until handshake
        //============================================================
        ST_AR: begin
          // Hold ARVALID until accepted
          if (m_axi_arvalid && m_axi_arready) begin
            m_axi_arvalid <= 1'b0;
            m_axi_rready  <= 1'b1;   // now wait for R
            state         <= ST_R;
          end
        end

        //============================================================
        // ST_R: wait for read data
        //============================================================
        ST_R: begin
          if (m_axi_rvalid && m_axi_rready) begin
            // Protocol checks: single-beat expects RLAST=1
            if (m_axi_rlast !== 1'b1) begin
              m_axi_rready <= 1'b0;
              err_code_r      <= ERR_AXI_PROTO;
              set_err_pulse_r <= 1'b1;
              state           <= ST_ERR;
            end else if (m_axi_rresp != RESP_OKAY) begin
              m_axi_rready <= 1'b0;
              err_code_r      <= ERR_AXI_RRESP;
              set_err_pulse_r <= 1'b1;
              state           <= ST_ERR;
            end else begin
              m_axi_rready<= 1'b0;

              // AW and W are independent channels. Publish both without
              // waiting for either READY; each VALID is its pending flag.
              m_axi_awaddr  <= dst_addr_q;
              m_axi_awvalid <= 1'b1;
              m_axi_wdata   <= m_axi_rdata;
              m_axi_wstrb   <= {DATA_BYTES{1'b1}};
              m_axi_wlast   <= 1'b1;
              m_axi_wvalid  <= 1'b1;
              state         <= ST_WRITE;
            end
          end
        end

        //============================================================
        // ST_WRITE: retire AW and W independently, in either order.
        // Payload and VALID remain stable on each stalled channel.
        //============================================================
        ST_WRITE: begin
          if (m_axi_awvalid && m_axi_awready)
            m_axi_awvalid <= 1'b0;
          if (m_axi_wvalid && m_axi_wready) begin
            m_axi_wvalid <= 1'b0;
            m_axi_wlast  <= 1'b0;
          end
          // Include handshakes on this edge as well as previously accepted
          // channels. A legal B response can arrive once both were accepted.
          if ((!m_axi_awvalid || m_axi_awready) &&
              (!m_axi_wvalid || m_axi_wready)) begin
            m_axi_bready <= 1'b1;
            state        <= ST_B;
          end
        end

        //============================================================
        // ST_B: wait for write response
        //============================================================
        ST_B: begin
          if (m_axi_bvalid && m_axi_bready) begin
            m_axi_bready <= 1'b0;

            if (m_axi_bresp != RESP_OKAY) begin
              err_code_r      <= ERR_AXI_BRESP;
              set_err_pulse_r <= 1'b1;
              state           <= ST_ERR;
            end else begin
              // Successful beat: advance pointers
              if (remain_q <= DATA_BYTES[31:0]) begin
                remain_q <= 32'd0;
                state    <= ST_DONE;
              end else begin
                remain_q   <= remain_q - DATA_BYTES[31:0];
                src_addr_q <= src_addr_q + DATA_BYTES[ADDR_WIDTH-1:0];
                dst_addr_q <= dst_addr_q + DATA_BYTES[ADDR_WIDTH-1:0];

                // Next AR
                m_axi_araddr  <= src_addr_q + DATA_BYTES[ADDR_WIDTH-1:0];
                m_axi_arvalid <= 1'b1;
                state         <= ST_AR;
              end
            end
          end
        end

        //============================================================
        // ST_DONE: pulse done and return idle
        //============================================================
        ST_DONE: begin
          set_done_pulse_r <= 1'b1;
          state            <= ST_IDLE;
        end

        //============================================================
        // ST_ERR: cleanup AXI and return idle (err pulse already asserted)
        //============================================================
        ST_ERR: begin
          // Ensure AXI is quiet
          m_axi_arvalid <= 1'b0;
          m_axi_rready  <= 1'b0;
          m_axi_awvalid <= 1'b0;
          m_axi_wvalid  <= 1'b0;
          m_axi_bready  <= 1'b0;
          m_axi_wlast   <= 1'b0;

          // remain can be left as-is or cleared; clear for clarity
          remain_q <= 32'd0;

          state <= ST_IDLE;
        end

        default: state <= ST_IDLE;
      endcase
    end
  end

endmodule

`endif // DMA_ENGINE_AXI_SV
