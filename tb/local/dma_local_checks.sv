// Concurrent assertions for the portable, two-state local simulation path.
// These check sampled protocol behavior; they do not claim X/Z detection or
// formal proof. Native cover properties record each assertion's activity.
`timescale 1ns/1ps
module dma_local_rv_check #(
  parameter int WIDTH = 32,
  parameter string LABEL = "channel"
)(input logic clk, rst_n, valid, ready,
  input logic [WIDTH-1:0] payload);
  bit history_valid = 0;
  always @(posedge clk) begin
    if (!rst_n) history_valid <= 0;
    else history_valid <= 1;
  end

  a_hold: assert property (@(posedge clk) disable iff (!rst_n)
    valid && !ready |=> valid && $stable(payload))
    else $error("LOCAL_SVA_HOLD %s changed VALID/payload after a stalled cycle", LABEL);

  c_handshake: cover property (@(posedge clk) disable iff (!rst_n)
    valid && ready);
  c_stall: cover property (@(posedge clk) disable iff (!rst_n)
    valid && !ready);
  // $past form avoids unsupported sequence concatenation in Verilator 5.020.
  // history_valid excludes the first sampled edge after reset.
  c_stall_release: cover property (@(posedge clk) disable iff (!rst_n)
    history_valid && $past(valid && !ready) && valid && ready);
endmodule

module dma_local_checks(axi_if axi, axil_if axil);
  dma_local_rv_check #(.WIDTH(58), .LABEL("AXI.AW")) aw(
    axi.clk, axi.rst_n, axi.awvalid, axi.awready,
    {axi.awid,axi.awaddr,axi.awlen,axi.awsize,axi.awburst,
     axi.awlock,axi.awcache,axi.awprot,axi.awqos});
  dma_local_rv_check #(.WIDTH(37), .LABEL("AXI.W")) w(
    axi.clk, axi.rst_n, axi.wvalid, axi.wready,
    {axi.wdata,axi.wstrb,axi.wlast});
  dma_local_rv_check #(.WIDTH(3), .LABEL("AXI.B")) b(
    axi.clk, axi.rst_n, axi.bvalid, axi.bready,{axi.bid,axi.bresp});
  dma_local_rv_check #(.WIDTH(58), .LABEL("AXI.AR")) ar(
    axi.clk, axi.rst_n, axi.arvalid, axi.arready,
    {axi.arid,axi.araddr,axi.arlen,axi.arsize,axi.arburst,
     axi.arlock,axi.arcache,axi.arprot,axi.arqos});
  dma_local_rv_check #(.WIDTH(36), .LABEL("AXI.R")) r(
    axi.clk, axi.rst_n, axi.rvalid, axi.rready,
    {axi.rid,axi.rdata,axi.rresp,axi.rlast});
  dma_local_rv_check #(.WIDTH(35), .LABEL("AXIL.AW")) law(
    axil.clk, axil.rst_n, axil.awvalid, axil.awready,{axil.awaddr,axil.awprot});
  dma_local_rv_check #(.WIDTH(36), .LABEL("AXIL.W")) lw(
    axil.clk, axil.rst_n, axil.wvalid, axil.wready,{axil.wdata,axil.wstrb});
  dma_local_rv_check #(.WIDTH(2), .LABEL("AXIL.B")) lb(
    axil.clk, axil.rst_n, axil.bvalid, axil.bready,axil.bresp);
  dma_local_rv_check #(.WIDTH(35), .LABEL("AXIL.AR")) lar(
    axil.clk, axil.rst_n, axil.arvalid, axil.arready,{axil.araddr,axil.arprot});
  dma_local_rv_check #(.WIDTH(34), .LABEL("AXIL.R")) lr(
    axil.clk, axil.rst_n, axil.rvalid, axil.rready,{axil.rdata,axil.rresp});

  // Counts contain handshakes from previous sampled edges. A response must
  // refer to an already accepted request, even when it is being stalled.
  // Add and subtract together to handle retirement/new requests on one edge.
  int axi_aw_pending = 0, axi_w_pending = 0, axi_ar_pending = 0;
  int axil_aw_pending = 0, axil_w_pending = 0, axil_ar_pending = 0;
  always @(posedge axi.clk) begin
    if (!axi.rst_n) begin
      axi_aw_pending <= 0;
      axi_w_pending <= 0;
      axi_ar_pending <= 0;
    end else begin
      axi_aw_pending <= axi_aw_pending + int'(axi.awvalid && axi.awready)
                                      - int'(axi.bvalid && axi.bready);
      axi_w_pending <= axi_w_pending + int'(axi.wvalid && axi.wready)
                                    - int'(axi.bvalid && axi.bready);
      axi_ar_pending <= axi_ar_pending + int'(axi.arvalid && axi.arready)
                                      - int'(axi.rvalid && axi.rready);
    end
  end
  always @(posedge axil.clk) begin
    if (!axil.rst_n) begin
      axil_aw_pending <= 0;
      axil_w_pending <= 0;
      axil_ar_pending <= 0;
    end else begin
      axil_aw_pending <= axil_aw_pending + int'(axil.awvalid && axil.awready)
                                        - int'(axil.bvalid && axil.bready);
      axil_w_pending <= axil_w_pending + int'(axil.wvalid && axil.wready)
                                      - int'(axil.bvalid && axil.bready);
      axil_ar_pending <= axil_ar_pending + int'(axil.arvalid && axil.arready)
                                        - int'(axil.rvalid && axil.rready);
    end
  end

  a_axi_b_request: assert property (@(posedge axi.clk) disable iff (!axi.rst_n)
    axi.bvalid |-> (axi_aw_pending == 1 && axi_w_pending == 1))
    else $error("LOCAL_SVA_AXI_B_REQUEST BVALID without one accepted AW and W");
  a_axi_r_request: assert property (@(posedge axi.clk) disable iff (!axi.rst_n)
    axi.rvalid |-> axi_ar_pending == 1)
    else $error("LOCAL_SVA_AXI_R_REQUEST RVALID without one accepted AR");
  a_axi_capacity: assert property (@(posedge axi.clk) disable iff (!axi.rst_n)
    axi_aw_pending inside {[0:1]} && axi_w_pending inside {[0:1]} &&
    axi_ar_pending inside {[0:1]})
    else $error("LOCAL_SVA_AXI_CAPACITY outstanding count outside baseline range");

  a_axil_b_request: assert property (@(posedge axil.clk) disable iff (!axil.rst_n)
    axil.bvalid |-> (axil_aw_pending == 1 && axil_w_pending == 1))
    else $error("LOCAL_SVA_AXIL_B_REQUEST BVALID without one accepted AW and W");
  a_axil_r_request: assert property (@(posedge axil.clk) disable iff (!axil.rst_n)
    axil.rvalid |-> axil_ar_pending == 1)
    else $error("LOCAL_SVA_AXIL_R_REQUEST RVALID without one accepted AR");
  a_axil_capacity: assert property (@(posedge axil.clk) disable iff (!axil.rst_n)
    axil_aw_pending inside {[0:1]} && axil_w_pending inside {[0:1]} &&
    axil_ar_pending inside {[0:1]})
    else $error("LOCAL_SVA_AXIL_CAPACITY outstanding count outside baseline range");

  a_aw_shape: assert property (@(posedge axi.clk) disable iff (!axi.rst_n)
    axi.awvalid |-> (axi.awid == 0 && axi.awlen == 0 && axi.awsize == 2 &&
                    axi.awburst == 1 && axi.awaddr[1:0] == 0))
    else $error("LOCAL_SVA_AW_SHAPE unsupported DMA write address shape");
  a_ar_shape: assert property (@(posedge axi.clk) disable iff (!axi.rst_n)
    axi.arvalid |-> (axi.arid == 0 && axi.arlen == 0 && axi.arsize == 2 &&
                    axi.arburst == 1 && axi.araddr[1:0] == 0))
    else $error("LOCAL_SVA_AR_SHAPE unsupported DMA read address shape");
  a_w_shape: assert property (@(posedge axi.clk) disable iff (!axi.rst_n)
    axi.wvalid |-> (axi.wlast && axi.wstrb == 4'hf))
    else $error("LOCAL_SVA_W_SHAPE DMA write requires WLAST and all byte strobes");
  a_r_shape: assert property (@(posedge axi.clk) disable iff (!axi.rst_n)
    axi.rvalid |-> (axi.rid == 0 && axi.rlast))
    else $error("LOCAL_SVA_R_SHAPE baseline read response requires ID zero and RLAST");
  a_b_shape: assert property (@(posedge axi.clk) disable iff (!axi.rst_n)
    axi.bvalid |-> axi.bid == 0)
    else $error("LOCAL_SVA_B_SHAPE baseline write response requires ID zero");

  // Antecedent coverage for the shape and lifecycle assertions.
  c_axi_aw_valid: cover property (@(posedge axi.clk) disable iff (!axi.rst_n) axi.awvalid);
  c_axi_w_valid: cover property (@(posedge axi.clk) disable iff (!axi.rst_n) axi.wvalid);
  c_axi_b_valid: cover property (@(posedge axi.clk) disable iff (!axi.rst_n) axi.bvalid);
  c_axi_ar_valid: cover property (@(posedge axi.clk) disable iff (!axi.rst_n) axi.arvalid);
  c_axi_r_valid: cover property (@(posedge axi.clk) disable iff (!axi.rst_n) axi.rvalid);
  c_axil_b_valid: cover property (@(posedge axil.clk) disable iff (!axil.rst_n) axil.bvalid);
  c_axil_r_valid: cover property (@(posedge axil.clk) disable iff (!axil.rst_n) axil.rvalid);
endmodule
