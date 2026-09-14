`timescale 1ns/1ps
`ifndef TB_TOP_SV
`define TB_TOP_SV

module tb_top;

  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import tb_pkg::*;

  localparam int unsigned ADDR_WIDTH      = 32;
  localparam int unsigned AXIL_DATA_WIDTH = 32;

  localparam int unsigned AXI_DATA_WIDTH  = 32;
  localparam int unsigned AXI_ID_WIDTH    = 1;

  localparam int unsigned MAX_BURST_BEATS = 16;
  localparam int unsigned MEM_SIZE_BYTES  = 64 * 1024;

  localparam bit ENABLE_4KB_RULE          = 1'b1;
  localparam bit ENABLE_BYTES_REMAIN      = 1'b1;

  // Interfaces
  clk_rst_if #(
    .CLK_PERIOD (10ns),
    .RESET_CYCLES(5)
  ) clkif();

  axil_if #(
    .ADDR_WIDTH (ADDR_WIDTH),
    .DATA_WIDTH (AXIL_DATA_WIDTH)
  ) axil (
    .clk  (clkif.clk),
    .rst_n(clkif.rst_n)
  );

  axi_if #(
    .ADDR_WIDTH (ADDR_WIDTH),
    .DATA_WIDTH (AXI_DATA_WIDTH),
    .ID_WIDTH   (AXI_ID_WIDTH)
  ) axi (
    .clk  (clkif.clk),
    .rst_n(clkif.rst_n)
  );

  irq_if irqif (
    .clk  (clkif.clk),
    .rst_n(clkif.rst_n)
  );

  // Backdoor memory interface (shared storage)
  mem_bkdr_if memif();

  // AXI memory model (slave)
  axi_mem_model #(
    .ADDR_WIDTH     (ADDR_WIDTH),
    .DATA_WIDTH     (AXI_DATA_WIDTH),
    .ID_WIDTH       (AXI_ID_WIDTH),
    .MEM_SIZE_BYTES (MEM_SIZE_BYTES),
    .INIT_MEM_ZERO  (1'b1),
    .INIT_MEM_RANDOM(1'b0),
    .VERBOSE        (1'b0)
  ) u_mem (
    .axi (axi),
    .bkdr(memif)
  );

  dma_protocol_checks u_protocol_checks (.axi(axi), .axil(axil));

  // DUT
  top_soc_dut #(
    .ADDR_WIDTH          (ADDR_WIDTH),
    .AXIL_DATA_WIDTH     (AXIL_DATA_WIDTH),
    .AXI_DATA_WIDTH      (AXI_DATA_WIDTH),
    .AXI_ID_WIDTH        (AXI_ID_WIDTH),
    .MAX_BURST_BEATS     (MAX_BURST_BEATS),
    .MEM_SIZE_BYTES      (MEM_SIZE_BYTES),
    .ENABLE_4KB_RULE     (ENABLE_4KB_RULE),
    .ENABLE_BYTES_REMAIN (ENABLE_BYTES_REMAIN)
  ) dut (
    .clk            (clkif.clk),
    .rst_n          (clkif.rst_n),

    .s_axil_awaddr  (axil.awaddr),
    .s_axil_awprot  (axil.awprot),
    .s_axil_awvalid (axil.awvalid),
    .s_axil_awready (axil.awready),

    .s_axil_wdata   (axil.wdata),
    .s_axil_wstrb   (axil.wstrb),
    .s_axil_wvalid  (axil.wvalid),
    .s_axil_wready  (axil.wready),

    .s_axil_bresp   (axil.bresp),
    .s_axil_bvalid  (axil.bvalid),
    .s_axil_bready  (axil.bready),

    .s_axil_araddr  (axil.araddr),
    .s_axil_arprot  (axil.arprot),
    .s_axil_arvalid (axil.arvalid),
    .s_axil_arready (axil.arready),

    .s_axil_rdata   (axil.rdata),
    .s_axil_rresp   (axil.rresp),
    .s_axil_rvalid  (axil.rvalid),
    .s_axil_rready  (axil.rready),

    .m_axi_awid     (axi.awid),
    .m_axi_awaddr   (axi.awaddr),
    .m_axi_awlen    (axi.awlen),
    .m_axi_awsize   (axi.awsize),
    .m_axi_awburst  (axi.awburst),
    .m_axi_awlock   (axi.awlock),
    .m_axi_awcache  (axi.awcache),
    .m_axi_awprot   (axi.awprot),
    .m_axi_awqos    (axi.awqos),
    .m_axi_awvalid  (axi.awvalid),
    .m_axi_awready  (axi.awready),

    .m_axi_wdata    (axi.wdata),
    .m_axi_wstrb    (axi.wstrb),
    .m_axi_wlast    (axi.wlast),
    .m_axi_wvalid   (axi.wvalid),
    .m_axi_wready   (axi.wready),

    .m_axi_bid      (axi.bid),
    .m_axi_bresp    (axi.bresp),
    .m_axi_bvalid   (axi.bvalid),
    .m_axi_bready   (axi.bready),

    .m_axi_arid     (axi.arid),
    .m_axi_araddr   (axi.araddr),
    .m_axi_arlen    (axi.arlen),
    .m_axi_arsize   (axi.arsize),
    .m_axi_arburst  (axi.arburst),
    .m_axi_arlock   (axi.arlock),
    .m_axi_arcache  (axi.arcache),
    .m_axi_arprot   (axi.arprot),
    .m_axi_arqos    (axi.arqos),
    .m_axi_arvalid  (axi.arvalid),
    .m_axi_arready  (axi.arready),

    .m_axi_rid      (axi.rid),
    .m_axi_rdata    (axi.rdata),
    .m_axi_rresp    (axi.rresp),
    .m_axi_rlast    (axi.rlast),
    .m_axi_rvalid   (axi.rvalid),
    .m_axi_rready   (axi.rready),

    .irq            (irqif.irq)
  );

  // AXI-Lite defaults (TB drives AXI-Lite only)
  initial begin
    axil.awaddr  = '0; axil.awprot  = 3'b000; axil.awvalid = 1'b0;
    axil.wdata   = '0; axil.wstrb   = '0;     axil.wvalid  = 1'b0;
    axil.bready  = 1'b0;
    axil.araddr  = '0; axil.arprot  = 3'b000; axil.arvalid = 1'b0;
    axil.rready  = 1'b0;
  end

  // Clock + reset
  initial fork
    clkif.drive_clock();
  join_none

  initial begin
    clkif.apply_reset();
  end

  // Config DB: pass VIFs to UVM
  initial begin
    uvm_config_db#(virtual axil_if #(ADDR_WIDTH, AXIL_DATA_WIDTH))::set(null, "*", "axil_vif", axil);
    uvm_config_db#(virtual axi_if  #(ADDR_WIDTH, AXI_DATA_WIDTH, AXI_ID_WIDTH))::set(null, "*", "axi_vif", axi);
    uvm_config_db#(virtual irq_if)::set(null, "*", "irq_vif", irqif);

    uvm_config_db#(virtual clk_rst_if #(10ns,5))::set(null, "*", "reset_vif", clkif);

    // Backdoor memory VIF
    uvm_config_db#(virtual mem_bkdr_if)::set(null, "*", "mem_vif", memif);
  end

  // Run UVM (select via +UVM_TESTNAME=smoke_test / copy_test)
  initial begin
    run_test();
  end

endmodule

`endif // TB_TOP_SV
