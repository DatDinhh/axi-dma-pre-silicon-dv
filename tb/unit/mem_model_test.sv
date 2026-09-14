// Focused responder checks, including the final-WLAST NBA regression.
`timescale 1ns/1ps
module mem_model_test;
  logic clk = 0;
  always #5 clk = ~clk;
  logic rst_n = 0;
  axi_if axi(clk, rst_n);
  mem_bkdr_if memif();
  axi_mem_model mem(axi, memif);
  logic [31:0] configured_berr, configured_rerr;
  bit berr_on, rerr_on;
  integer cycle_count = 0;
  always @(posedge clk) cycle_count <= cycle_count + 1;

  task automatic write_tx(input logic [31:0] address,
                          input logic [31:0] data,
                          input logic [3:0] strb, input bit last);
    bit aw_done, w_done;
    logic [1:0] expected_response;
    expected_response = (!last || (berr_on && address == configured_berr)) ? 2'b10 : 2'b00;
    @(negedge clk);
    axi.awaddr = address; axi.awvalid = 1;
    axi.wdata = data; axi.wstrb = strb; axi.wlast = last; axi.wvalid = 1;
    aw_done = 0; w_done = 0;
    while (!aw_done || !w_done) begin
      @(posedge clk);
      if (axi.awvalid && axi.awready) aw_done = 1;
      if (axi.wvalid && axi.wready) w_done = 1;
      @(negedge clk);
      if (aw_done) axi.awvalid = 0;
      if (w_done) axi.wvalid = 0;
    end
    do @(negedge clk); while (!axi.bvalid);
    repeat (4) begin
      if (axi.bvalid !== 1 || axi.bresp !== expected_response || axi.bid !== 0)
        $fatal(1, "BRESP mismatch/instability addr=%h expected=%b got=%b", address, expected_response, axi.bresp);
      @(negedge clk);
    end
    axi.bready = 1;
    @(negedge clk); axi.bready = 0;
  endtask

  task automatic read_tx(input logic [31:0] address, input logic [31:0] expected_data);
    logic [1:0] expected_response;
    expected_response = (rerr_on && address == configured_rerr) ? 2'b10 : 2'b00;
    @(negedge clk); axi.araddr = address; axi.arvalid = 1;
    do @(posedge clk); while (!axi.arready);
    @(negedge clk); axi.arvalid = 0;
    do @(negedge clk); while (!axi.rvalid);
    repeat (4) begin
      if (axi.rvalid !== 1 || axi.rresp !== expected_response || axi.rdata !== expected_data ||
          axi.rid !== 0 || axi.rlast !== 1)
        $fatal(1, "R payload mismatch/instability addr=%h expected=%h got=%h resp=%b", address, expected_data, axi.rdata, axi.rresp);
      @(negedge clk);
    end
    axi.rready = 1;
    @(negedge clk); axi.rready = 0;
  endtask

  initial begin
    berr_on = $value$plusargs("AXI_BERR_ADDR=%h", configured_berr);
    rerr_on = $value$plusargs("AXI_RERR_ADDR=%h", configured_rerr);
    axi.awid = 0; axi.awaddr = 0; axi.awlen = 0; axi.awsize = 2; axi.awburst = 1;
    axi.awlock = 0; axi.awcache = 0; axi.awprot = 0; axi.awqos = 0; axi.awvalid = 0;
    axi.wdata = 0; axi.wstrb = 0; axi.wlast = 0; axi.wvalid = 0; axi.bready = 0;
    axi.arid = 0; axi.araddr = 0; axi.arlen = 0; axi.arsize = 2; axi.arburst = 1;
    axi.arlock = 0; axi.arcache = 0; axi.arprot = 0; axi.arqos = 0; axi.arvalid = 0; axi.rready = 0;
    repeat (4) @(negedge clk); rst_n = 1;
    write_tx(32'h200, 32'h12345678, 4'hf, 0); // Must return SLVERR on final missing WLAST.
    write_tx(32'h204, 32'habcdef01, 4'h5, 1); // Strobes write only byte lanes 0 and 2.
    read_tx(32'h200, 32'h12345678);
    read_tx(32'h204, 32'h00cd0001);
    // Repeat matching transactions to prove error injection is persistent.
    write_tx(32'h204, 32'habcdef01, 4'h5, 1);
    read_tx(32'h204, 32'h00cd0001);
    if (memif.mem[32'h1ff] !== 0 || memif.mem[32'h208] !== 0)
      $fatal(1, "Guard byte changed");
    $display("UNIT_PASS memory model WLAST/strobes/stability/error injection cycles=%0d", cycle_count);
    $finish;
  end
  initial begin
    repeat (1000) @(negedge clk);
    $fatal(1, "Memory unit test timed out");
  end
endmodule
