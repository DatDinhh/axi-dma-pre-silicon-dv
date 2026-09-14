// Standalone engine regression: no UVM or memory-model dependency.
// AW_MODE=0: W before AW, and AWREADY waits for observed WVALID.
// AW_MODE=1: AW before W. AW_MODE=2: simultaneous AW/W handshakes.
`timescale 1ns/1ps
module engine_aw_w_test;
  logic clk = 0;
  always #5 clk = ~clk;
  logic rst_n = 0;
  logic start = 0;
  logic busy, accept, done, err;
  logic [31:0] remain;
  logic [7:0] err_code;
  axi_if axi(clk, rst_n);
  dma_engine_axi dut (
    .clk(clk), .rst_n(rst_n), .cfg_src_addr(32'h100),
    .cfg_dst_addr(32'h200), .cfg_len_bytes(32'd4), .start_req_pulse(start),
    .engine_busy(busy), .engine_bytes_remain(remain),
    .start_accept_pulse(accept), .set_done_pulse(done),
    .set_err_pulse(err), .err_code_value(err_code),
    .m_axi_awid(axi.awid), .m_axi_awaddr(axi.awaddr), .m_axi_awlen(axi.awlen),
    .m_axi_awsize(axi.awsize), .m_axi_awburst(axi.awburst), .m_axi_awlock(axi.awlock),
    .m_axi_awcache(axi.awcache), .m_axi_awprot(axi.awprot), .m_axi_awqos(axi.awqos),
    .m_axi_awvalid(axi.awvalid), .m_axi_awready(axi.awready),
    .m_axi_wdata(axi.wdata), .m_axi_wstrb(axi.wstrb), .m_axi_wlast(axi.wlast),
    .m_axi_wvalid(axi.wvalid), .m_axi_wready(axi.wready),
    .m_axi_bid(axi.bid), .m_axi_bresp(axi.bresp), .m_axi_bvalid(axi.bvalid),
    .m_axi_bready(axi.bready), .m_axi_arid(axi.arid), .m_axi_araddr(axi.araddr),
    .m_axi_arlen(axi.arlen), .m_axi_arsize(axi.arsize), .m_axi_arburst(axi.arburst),
    .m_axi_arlock(axi.arlock), .m_axi_arcache(axi.arcache), .m_axi_arprot(axi.arprot),
    .m_axi_arqos(axi.arqos), .m_axi_arvalid(axi.arvalid), .m_axi_arready(axi.arready),
    .m_axi_rid(axi.rid), .m_axi_rdata(axi.rdata), .m_axi_rresp(axi.rresp),
    .m_axi_rlast(axi.rlast), .m_axi_rvalid(axi.rvalid), .m_axi_rready(axi.rready)
  );
  integer mode = 0;
  integer read_response = 0;
  integer write_response = 0;
  integer bad_rlast = 0;
  integer write_age = 0;
  integer aw_cycle = -1, w_cycle = -1, cycles = 0;
  logic aw_seen = 0, w_seen = 0;
  assign axi.arready = rst_n;
  assign axi.awready = rst_n && !aw_seen &&
    ((mode != 0) || ((axi.wvalid || w_seen) && write_age >= 4));
  assign axi.wready = rst_n && !w_seen && ((mode != 1) || write_age >= 4);
  assign axi.bvalid = aw_seen && w_seen;
  assign axi.bresp = write_response[1:0];
  assign axi.bid = 0;
  assign axi.rresp = read_response[1:0];
  assign axi.rdata = 32'hcafe1234;
  assign axi.rid = 0;
  assign axi.rlast = !bad_rlast;
  always @(posedge clk) begin
    cycles <= cycles + 1;
    if (!rst_n) axi.rvalid <= 0;
    else begin
      if (axi.arvalid && axi.arready) axi.rvalid <= 1;
      if (axi.rvalid && axi.rready) axi.rvalid <= 0;
      if (axi.awvalid || axi.wvalid || aw_seen || w_seen) write_age <= write_age + 1;
      if (axi.awvalid && axi.awready) begin
        aw_seen <= 1;
        aw_cycle <= cycles;
        if (axi.awaddr !== 32'h200 || axi.awlen !== 0) $fatal(1, "Bad AW payload");
      end
      if (axi.wvalid && axi.wready) begin
        w_seen <= 1;
        w_cycle <= cycles;
        if (axi.wdata !== 32'hcafe1234 || axi.wstrb !== 4'hf || axi.wlast !== 1)
          $fatal(1, "Bad W payload");
      end
      if (axi.bvalid && axi.bready) begin aw_seen <= 0; w_seen <= 0; end
    end
  end
  initial begin
    void'($value$plusargs("AW_MODE=%d", mode));
    void'($value$plusargs("RRESP=%d", read_response));
    void'($value$plusargs("BRESP=%d", write_response));
    void'($value$plusargs("BAD_RLAST=%d", bad_rlast));
    repeat (4) @(negedge clk);
    rst_n = 1;
    @(negedge clk); start = 1;
    @(negedge clk); start = 0;
    repeat (100) begin
      @(negedge clk);
      if (err) begin
        if ((bad_rlast && err_code == 8) ||
            (!bad_rlast && read_response != 0 && err_code == 5) ||
            (!bad_rlast && read_response == 0 && write_response != 0 && err_code == 6)) begin
          $display("UNIT_PASS error=%0d", err_code); $finish;
        end
        $fatal(1, "Unexpected error code %0d", err_code);
      end
      if (done) begin
        if (read_response || write_response || bad_rlast) $fatal(1, "Expected error, got DONE");
        if ((mode == 0 && !(w_cycle < aw_cycle)) ||
            (mode == 1 && !(aw_cycle < w_cycle)) ||
            (mode == 2 && aw_cycle != w_cycle)) $fatal(1, "Wrong handshake ordering");
        if (remain !== 0) $fatal(1, "Nonzero remaining bytes on DONE");
        $display("UNIT_PASS mode=%0d AW_cycle=%0d W_cycle=%0d", mode, aw_cycle, w_cycle);
        $finish;
      end
    end
    $fatal(1, "ENGINE_TIMEOUT mode=%0d AWVALID=%b AWREADY=%b WVALID=%b WREADY=%b", mode,
           axi.awvalid, axi.awready, axi.wvalid, axi.wready);
  end
endmodule
