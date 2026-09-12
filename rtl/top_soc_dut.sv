//==============================================================================
// rtl/top_soc_dut.sv
//------------------------------------------------------------------------------
// Top-level DUT wrapper: AXI-Lite regs + AXI DMA engine + IRQ aggregation
//
// Fix included:
// - Adds parameter ENABLE_BYTES_REMAIN so tb_top.sv can override it.
// - Passes ENABLE_BYTES_REMAIN down to dma_regs_axil.
//==============================================================================

`ifndef TOP_SOC_DUT_SV
`define TOP_SOC_DUT_SV

module top_soc_dut #(
  parameter int unsigned ADDR_WIDTH          = 32,
  parameter int unsigned AXIL_DATA_WIDTH     = 32,
  parameter int unsigned AXI_DATA_WIDTH      = 32,
  parameter int unsigned AXI_ID_WIDTH        = 1,
  parameter int unsigned MAX_BURST_BEATS     = 16,
  parameter int unsigned MEM_SIZE_BYTES      = 64 * 1024,
  parameter bit          ENABLE_4KB_RULE     = 1'b1,
  parameter bit          ENABLE_BYTES_REMAIN = 1'b1
)(
  input  logic                         clk,
  input  logic                         rst_n,

  // AXI4-Lite slave (registers)
  input  logic [ADDR_WIDTH-1:0]        s_axil_awaddr,
  input  logic [2:0]                   s_axil_awprot,
  input  logic                         s_axil_awvalid,
  output logic                         s_axil_awready,

  input  logic [AXIL_DATA_WIDTH-1:0]   s_axil_wdata,
  input  logic [(AXIL_DATA_WIDTH/8)-1:0] s_axil_wstrb,
  input  logic                         s_axil_wvalid,
  output logic                         s_axil_wready,

  output logic [1:0]                   s_axil_bresp,
  output logic                         s_axil_bvalid,
  input  logic                         s_axil_bready,

  input  logic [ADDR_WIDTH-1:0]        s_axil_araddr,
  input  logic [2:0]                   s_axil_arprot,
  input  logic                         s_axil_arvalid,
  output logic                         s_axil_arready,

  output logic [AXIL_DATA_WIDTH-1:0]   s_axil_rdata,
  output logic [1:0]                   s_axil_rresp,
  output logic                         s_axil_rvalid,
  input  logic                         s_axil_rready,

  // AXI4 master (DMA)
  output logic [AXI_ID_WIDTH-1:0]      m_axi_awid,
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

  output logic [AXI_DATA_WIDTH-1:0]    m_axi_wdata,
  output logic [(AXI_DATA_WIDTH/8)-1:0] m_axi_wstrb,
  output logic                         m_axi_wlast,
  output logic                         m_axi_wvalid,
  input  logic                         m_axi_wready,

  input  logic [AXI_ID_WIDTH-1:0]      m_axi_bid,
  input  logic [1:0]                   m_axi_bresp,
  input  logic                         m_axi_bvalid,
  output logic                         m_axi_bready,

  output logic [AXI_ID_WIDTH-1:0]      m_axi_arid,
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

  input  logic [AXI_ID_WIDTH-1:0]      m_axi_rid,
  input  logic [AXI_DATA_WIDTH-1:0]    m_axi_rdata,
  input  logic [1:0]                   m_axi_rresp,
  input  logic                         m_axi_rlast,
  input  logic                         m_axi_rvalid,
  output logic                         m_axi_rready,

  output logic                         irq
);

  import dma_pkg::*;

  // Reg-to-engine config
  logic [ADDR_WIDTH-1:0] cfg_src_addr;
  logic [ADDR_WIDTH-1:0] cfg_dst_addr;
  logic [31:0]           cfg_len_bytes;
  logic                  cfg_irq_en;
  logic                  start_req_pulse;

  // Engine status/events
  logic                  engine_busy;
  logic [31:0]           engine_bytes_remain;

  logic                  start_accept_pulse;
  logic                  set_done_pulse;
  logic                  set_err_pulse;
  logic [7:0]            err_code_value;

  // Sticky bits from regs
  logic                  sticky_done;
  logic                  sticky_err;

  //--------------------------------------------------------------------------
  // AXI-Lite regs block
  //--------------------------------------------------------------------------
  dma_regs_axil #(
    .ADDR_WIDTH          (ADDR_WIDTH),
    .DATA_WIDTH          (AXIL_DATA_WIDTH),
    .ENABLE_BYTES_REMAIN (ENABLE_BYTES_REMAIN)
  ) u_regs (
    .clk                 (clk),
    .rst_n               (rst_n),

    .s_axil_awaddr       (s_axil_awaddr),
    .s_axil_awprot       (s_axil_awprot),
    .s_axil_awvalid      (s_axil_awvalid),
    .s_axil_awready      (s_axil_awready),

    .s_axil_wdata        (s_axil_wdata),
    .s_axil_wstrb        (s_axil_wstrb),
    .s_axil_wvalid       (s_axil_wvalid),
    .s_axil_wready       (s_axil_wready),

    .s_axil_bresp        (s_axil_bresp),
    .s_axil_bvalid       (s_axil_bvalid),
    .s_axil_bready       (s_axil_bready),

    .s_axil_araddr       (s_axil_araddr),
    .s_axil_arprot       (s_axil_arprot),
    .s_axil_arvalid      (s_axil_arvalid),
    .s_axil_arready      (s_axil_arready),

    .s_axil_rdata        (s_axil_rdata),
    .s_axil_rresp        (s_axil_rresp),
    .s_axil_rvalid       (s_axil_rvalid),
    .s_axil_rready       (s_axil_rready),

    .cfg_src_addr        (cfg_src_addr),
    .cfg_dst_addr        (cfg_dst_addr),
    .cfg_len_bytes       (cfg_len_bytes),
    .cfg_irq_en          (cfg_irq_en),
    .start_req_pulse     (start_req_pulse),

    .engine_busy         (engine_busy),
    .engine_bytes_remain (engine_bytes_remain),
    .start_accept_pulse  (start_accept_pulse),
    .set_done_pulse      (set_done_pulse),
    .set_err_pulse       (set_err_pulse),
    .err_code_value      (err_code_value),

    .sticky_done         (sticky_done),
    .sticky_err          (sticky_err)
  );

  //--------------------------------------------------------------------------
  // DMA engine (AXI master)
  //--------------------------------------------------------------------------
  dma_engine_axi #(
    .ADDR_WIDTH      (ADDR_WIDTH),
    .DATA_WIDTH      (AXI_DATA_WIDTH),
    .ID_WIDTH        (AXI_ID_WIDTH),
    .MAX_BURST_BEATS (MAX_BURST_BEATS),
    .MEM_SIZE_BYTES  (MEM_SIZE_BYTES),
    .ENABLE_4KB_RULE (ENABLE_4KB_RULE)
  ) u_engine (
    .clk                 (clk),
    .rst_n               (rst_n),

    .cfg_src_addr        (cfg_src_addr),
    .cfg_dst_addr        (cfg_dst_addr),
    .cfg_len_bytes       (cfg_len_bytes),
    .start_req_pulse     (start_req_pulse),

    .engine_busy         (engine_busy),
    .engine_bytes_remain (engine_bytes_remain),

    .start_accept_pulse  (start_accept_pulse),
    .set_done_pulse      (set_done_pulse),
    .set_err_pulse       (set_err_pulse),
    .err_code_value      (err_code_value),

    .m_axi_awid          (m_axi_awid),
    .m_axi_awaddr        (m_axi_awaddr),
    .m_axi_awlen         (m_axi_awlen),
    .m_axi_awsize        (m_axi_awsize),
    .m_axi_awburst       (m_axi_awburst),
    .m_axi_awlock        (m_axi_awlock),
    .m_axi_awcache       (m_axi_awcache),
    .m_axi_awprot        (m_axi_awprot),
    .m_axi_awqos         (m_axi_awqos),
    .m_axi_awvalid       (m_axi_awvalid),
    .m_axi_awready       (m_axi_awready),

    .m_axi_wdata         (m_axi_wdata),
    .m_axi_wstrb         (m_axi_wstrb),
    .m_axi_wlast         (m_axi_wlast),
    .m_axi_wvalid        (m_axi_wvalid),
    .m_axi_wready        (m_axi_wready),

    .m_axi_bid           (m_axi_bid),
    .m_axi_bresp         (m_axi_bresp),
    .m_axi_bvalid        (m_axi_bvalid),
    .m_axi_bready        (m_axi_bready),

    .m_axi_arid          (m_axi_arid),
    .m_axi_araddr        (m_axi_araddr),
    .m_axi_arlen         (m_axi_arlen),
    .m_axi_arsize        (m_axi_arsize),
    .m_axi_arburst       (m_axi_arburst),
    .m_axi_arlock        (m_axi_arlock),
    .m_axi_arcache       (m_axi_arcache),
    .m_axi_arprot        (m_axi_arprot),
    .m_axi_arqos         (m_axi_arqos),
    .m_axi_arvalid       (m_axi_arvalid),
    .m_axi_arready       (m_axi_arready),

    .m_axi_rid           (m_axi_rid),
    .m_axi_rdata         (m_axi_rdata),
    .m_axi_rresp         (m_axi_rresp),
    .m_axi_rlast         (m_axi_rlast),
    .m_axi_rvalid        (m_axi_rvalid),
    .m_axi_rready        (m_axi_rready)
  );

  //--------------------------------------------------------------------------
  // IRQ (level): gated by IRQ enable
  //--------------------------------------------------------------------------
  assign irq = cfg_irq_en && (sticky_done || sticky_err);

endmodule

`endif // TOP_SOC_DUT_SV
