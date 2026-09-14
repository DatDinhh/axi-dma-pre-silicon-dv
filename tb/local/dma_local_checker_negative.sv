// Real checker validation: +NEGATIVE=0 is a legal control; +NEGATIVE=1
// changes a held AXI AW payload and must terminate at LOCAL_SVA_HOLD.
`timescale 1ns/1ps
module dma_local_checker_negative;
  bit clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  axi_if axi(clk, rst_n);
  axil_if axil(clk, rst_n);
  dma_local_checks checks(axi, axil);
  int negative = 0;
  initial begin
    void'($value$plusargs("NEGATIVE=%d", negative));
    axi.awid=0; axi.awaddr=32'h100; axi.awlen=0; axi.awsize=2;
    axi.awburst=1; axi.awlock=0; axi.awcache=0; axi.awprot=0; axi.awqos=0;
    axi.awvalid=0; axi.awready=0;
    axi.wdata=32'h12345678; axi.wstrb=4'hf; axi.wlast=1; axi.wvalid=0; axi.wready=0;
    axi.bid=0; axi.bresp=0; axi.bvalid=0; axi.bready=0;
    axi.arid=0; axi.araddr=32'h200; axi.arlen=0; axi.arsize=2;
    axi.arburst=1; axi.arlock=0; axi.arcache=0; axi.arprot=0; axi.arqos=0;
    axi.arvalid=0; axi.arready=0;
    axi.rid=0; axi.rdata=0; axi.rresp=0; axi.rlast=1; axi.rvalid=0; axi.rready=0;
    axil.awaddr=0; axil.awprot=0; axil.awvalid=0; axil.awready=0;
    axil.wdata=0; axil.wstrb=4'hf; axil.wvalid=0; axil.wready=0;
    axil.bresp=0; axil.bvalid=0; axil.bready=0;
    axil.araddr=0; axil.arprot=0; axil.arvalid=0; axil.arready=0;
    axil.rdata=0; axil.rresp=0; axil.rvalid=0; axil.rready=0;
    repeat(3) @(negedge clk);
    rst_n=1;
    @(negedge clk);
    axi.awvalid=1;
    @(negedge clk); // At the intervening posedge AWVALID && !AWREADY.
    if (negative != 0) axi.awaddr=32'h104;
    @(negedge clk); // The changed payload must have failed the assertion.
    if (negative != 0) $fatal(1,"LOCAL_CHECKER_NEGATIVE_MISSED");
    axi.awready=1;
    axi.wvalid=1; axi.wready=1;
    @(negedge clk);
    axi.awvalid=0; axi.wvalid=0; axi.bvalid=1;
    repeat(2) @(negedge clk);
    axi.bready=1;
    @(negedge clk);
    axi.bvalid=0;
    repeat(2) @(negedge clk);
    $display("LOCAL_CHECKER_CONTROL_PASS");
    $finish;
  end
  initial begin
    #2000;
    $fatal(1,"LOCAL_CHECKER_WATCHDOG");
  end
endmodule
