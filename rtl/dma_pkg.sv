//==============================================================================
// rtl/dma_pkg.sv  (ModelSim-Intel + Verilator friendly: NON-parameterized)
//------------------------------------------------------------------------------
// Shared constants, offsets, bit definitions, helper utilities for AXI DMA.
// NOTE: Parameterized packages are NOT supported in Verilator and ModelSim-Intel
// 2020.1. Keep this package non-parameterized.
//==============================================================================

`ifndef DMA_PKG_SV
`define DMA_PKG_SV

package dma_pkg;

  timeunit 1ns;
  timeprecision 1ps;

  //----------------------------------------------------------------------------
  // Locked configuration for this repo (walking skeleton + baseline DV)
  //----------------------------------------------------------------------------
  localparam int unsigned ADDR_WIDTH          = 32;
  localparam int unsigned DATA_WIDTH          = 32;         // AXI data width
  localparam int unsigned REG_DATA_WIDTH      = 32;         // AXI-Lite reg width
  localparam int unsigned MAX_BURST_BEATS     = 16;
  localparam int unsigned MEM_SIZE_BYTES      = 64 * 1024;
  localparam bit          ENABLE_4KB_RULE     = 1'b1;
  localparam bit          ENABLE_BYTES_REMAIN = 1'b1;

  localparam int unsigned DATA_BYTES  = (DATA_WIDTH/8);
  localparam int unsigned REG_BYTES   = (REG_DATA_WIDTH/8);

  localparam int unsigned AXI_SIZE_CODE  = $clog2(DATA_BYTES);
  localparam int unsigned AXIL_SIZE_CODE = $clog2(REG_BYTES);

  typedef logic [ADDR_WIDTH-1:0] addr_t;
  typedef logic [DATA_WIDTH-1:0] data_t;

  typedef logic [DATA_BYTES-1:0] axi_strb_t;
  typedef logic [REG_BYTES-1:0]  axil_strb_t;

  //----------------------------------------------------------------------------
  // AXI encodings
  //----------------------------------------------------------------------------
  typedef enum logic [1:0] {
    AXI_RESP_OKAY   = 2'b00,
    AXI_RESP_EXOKAY = 2'b01,
    AXI_RESP_SLVERR = 2'b10,
    AXI_RESP_DECERR = 2'b11
  } axi_resp_t;

  typedef enum logic [1:0] {
    AXI_BURST_FIXED = 2'b00,
    AXI_BURST_INCR  = 2'b01,
    AXI_BURST_WRAP  = 2'b10
  } axi_burst_t;

  //----------------------------------------------------------------------------
  // Register offsets (base = 0x0000)
  //----------------------------------------------------------------------------
  localparam int unsigned REG_OFF_CTRL         = 32'h0000;
  localparam int unsigned REG_OFF_SRC_ADDR     = 32'h0004;
  localparam int unsigned REG_OFF_DST_ADDR     = 32'h0008;
  localparam int unsigned REG_OFF_LEN          = 32'h000C;
  localparam int unsigned REG_OFF_STATUS       = 32'h0010;
  localparam int unsigned REG_OFF_IRQ_STATUS   = 32'h0014;
  localparam int unsigned REG_OFF_ERR_CODE     = 32'h0018;
  localparam int unsigned REG_OFF_BYTES_REMAIN = 32'h001C;

  // CTRL bits
  localparam int unsigned CTRL_START_BIT     = 0;
  localparam int unsigned CTRL_IRQ_EN_BIT    = 1;
  localparam int unsigned CTRL_CLR_DONE_BIT  = 2;
  localparam int unsigned CTRL_CLR_ERR_BIT   = 3;

  // STATUS bits
  localparam int unsigned STATUS_BUSY_BIT    = 0;
  localparam int unsigned STATUS_DONE_BIT    = 1;
  localparam int unsigned STATUS_ERR_BIT     = 2;

  // IRQ_STATUS bits (RW1C)
  localparam int unsigned IRQSTAT_DONE_BIT   = 0;
  localparam int unsigned IRQSTAT_ERR_BIT    = 1;

  // AXI-Lite full strobe expectation for 32-bit regs
  localparam axil_strb_t AXIL_FULL_WSTRB = {REG_BYTES{1'b1}};

  //----------------------------------------------------------------------------
  // Error codes
  //----------------------------------------------------------------------------
  typedef enum logic [7:0] {
    ERR_NONE         = 8'd0,
    ERR_LEN_ZERO     = 8'd1,
    ERR_ALIGN        = 8'd2,
    ERR_RANGE        = 8'd3,
    ERR_BUSY_START   = 8'd4, // Reserved: this engine ignores START while busy.
    ERR_AXI_RRESP    = 8'd5,
    ERR_AXI_BRESP    = 8'd6,
    ERR_TIMEOUT      = 8'd7, // Reserved: no hardware timeout in this baseline.
    ERR_AXI_PROTO    = 8'd8
  } err_code_t;

  //----------------------------------------------------------------------------
  // Helpers (used by engine)
  //----------------------------------------------------------------------------
  function automatic bit is_data_aligned(input addr_t a);
    return (AXI_SIZE_CODE == 0) ? 1'b1 : (a[AXI_SIZE_CODE-1:0] == '0);
  endfunction

  function automatic bit is_in_range(input addr_t addr, input int unsigned len_bytes);
    longint unsigned a;
    longint unsigned l;
    a = longint'(addr);
    l = longint'(len_bytes);
    return ((a + l) <= longint'(MEM_SIZE_BYTES));
  endfunction

  function automatic err_code_t start_validation_errcode(
    input bit          busy,
    input addr_t       src_addr,
    input addr_t       dst_addr,
    input int unsigned len_bytes
  );
    // Busy START is ignored and must not generate a software-visible error.
    // The caller must separately gate acceptance with !busy.
    if (busy)                          return ERR_NONE;
    if (len_bytes == 0)                return ERR_LEN_ZERO;
    if (!is_data_aligned(src_addr))    return ERR_ALIGN;
    if (!is_data_aligned(dst_addr))    return ERR_ALIGN;
    if ((len_bytes % DATA_BYTES) != 0) return ERR_ALIGN;
    if (!is_in_range(src_addr, len_bytes)) return ERR_RANGE;
    if (!is_in_range(dst_addr, len_bytes)) return ERR_RANGE;
    return ERR_NONE;
  endfunction

endpackage : dma_pkg

`endif // DMA_PKG_SV
