// Always-on sampled protocol checks. Optional SVA is enabled only after a
// simulator capability probe. Both modes observe signals before NBA updates.
`timescale 1ns/1ps
module rv_stability_check #(
  parameter int WIDTH=32,
  parameter string LABEL="channel"
)(input logic clk,rst_n,valid,ready,input logic[WIDTH-1:0] payload);
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  bit held=0;
  logic[WIDTH-1:0] saved;
  longint unsigned stall_samples=0,handshakes=0;
  always @(posedge clk) begin
    if(rst_n!==1'b1) held=0;
    else begin
      if(held && (valid!==1'b1 || payload!==saved))
        `uvm_error("PROTOCOL_STABILITY",$sformatf("%s changed VALID/payload while stalled",LABEL))
      if($isunknown({valid,ready}))
        `uvm_error("PROTOCOL_X",$sformatf("%s has unknown VALID/READY",LABEL))
      held=(valid===1'b1 && ready===1'b0);
      saved=payload;
      if(held) stall_samples++;
      if(valid && ready) handshakes++;
    end
  end
`ifdef ENABLE_SVA
  a_hold: assert property (@(posedge clk) disable iff(!rst_n)
    valid && !ready |=> valid && $stable(payload))
    else `uvm_error("SVA_HOLD",$sformatf("%s stability assertion failed",LABEL))
  c_stall_release: cover property (@(posedge clk) disable iff(!rst_n)
    valid && !ready ##1 valid && ready);
`endif
  final $display("PROTOCOL_ACTIVITY %s handshakes=%0d stalled_cycles=%0d",LABEL,handshakes,stall_samples);
endmodule

module dma_protocol_checks(axi_if axi,axil_if axil);
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  rv_stability_check #(.WIDTH(58),.LABEL("AXI.AW")) aw(
    axi.clk,axi.rst_n,axi.awvalid,axi.awready,
    {axi.awid,axi.awaddr,axi.awlen,axi.awsize,axi.awburst,axi.awlock,axi.awcache,axi.awprot,axi.awqos});
  rv_stability_check #(.WIDTH(37),.LABEL("AXI.W")) w(
    axi.clk,axi.rst_n,axi.wvalid,axi.wready,{axi.wdata,axi.wstrb,axi.wlast});
  rv_stability_check #(.WIDTH(3),.LABEL("AXI.B")) b(
    axi.clk,axi.rst_n,axi.bvalid,axi.bready,{axi.bid,axi.bresp});
  rv_stability_check #(.WIDTH(58),.LABEL("AXI.AR")) ar(
    axi.clk,axi.rst_n,axi.arvalid,axi.arready,
    {axi.arid,axi.araddr,axi.arlen,axi.arsize,axi.arburst,axi.arlock,axi.arcache,axi.arprot,axi.arqos});
  rv_stability_check #(.WIDTH(36),.LABEL("AXI.R")) r(
    axi.clk,axi.rst_n,axi.rvalid,axi.rready,{axi.rid,axi.rdata,axi.rresp,axi.rlast});
  rv_stability_check #(.WIDTH(35),.LABEL("AXIL.AW")) law(
    axil.clk,axil.rst_n,axil.awvalid,axil.awready,{axil.awaddr,axil.awprot});
  rv_stability_check #(.WIDTH(36),.LABEL("AXIL.W")) lw(
    axil.clk,axil.rst_n,axil.wvalid,axil.wready,{axil.wdata,axil.wstrb});
  rv_stability_check #(.WIDTH(2),.LABEL("AXIL.B")) lb(
    axil.clk,axil.rst_n,axil.bvalid,axil.bready,axil.bresp);
  rv_stability_check #(.WIDTH(35),.LABEL("AXIL.AR")) lar(
    axil.clk,axil.rst_n,axil.arvalid,axil.arready,{axil.araddr,axil.arprot});
  rv_stability_check #(.WIDTH(34),.LABEL("AXIL.R")) lr(
    axil.clk,axil.rst_n,axil.rvalid,axil.rready,{axil.rdata,axil.rresp});
  int aw_pending=0,w_pending=0,ar_pending=0;
  always @(posedge axi.clk) begin
    if(axi.rst_n!==1'b1) begin
      aw_pending=0; w_pending=0; ar_pending=0;
    end else begin
      if(axi.bvalid && (aw_pending!=1 || w_pending!=1))
        `uvm_error("AXI_RESPONSE","BVALID without exactly one accepted AW and W")
      if(axi.rvalid && ar_pending!=1)
        `uvm_error("AXI_RESPONSE","RVALID without exactly one accepted AR")
      if(axi.bvalid && axi.bready) begin aw_pending--; w_pending--; end
      if(axi.rvalid && axi.rready) ar_pending--;
      if(axi.awvalid && axi.awready) begin
        aw_pending++;
        if(axi.awid!==0 || axi.awlen!==0 || axi.awsize!==2 || axi.awburst!==1 || axi.awaddr[1:0]!==0)
          `uvm_error("AXI_WRITE_SHAPE","Write address violates supported aligned single-beat subset")
      end
      if(axi.wvalid && axi.wready) begin
        w_pending++;
        if(axi.wlast!==1 || axi.wstrb!==4'hf)
          `uvm_error("AXI_WRITE_SHAPE","Write requires WLAST and full strobe")
      end
      if(axi.arvalid && axi.arready) begin
        ar_pending++;
        if(axi.arid!==0 || axi.arlen!==0 || axi.arsize!==2 || axi.arburst!==1 || axi.araddr[1:0]!==0)
          `uvm_error("AXI_READ_SHAPE","Read address violates supported aligned single-beat subset")
      end
      if(axi.rvalid && (axi.rid!==0 || axi.rlast!==1))
        `uvm_error("AXI_READ_SHAPE","Read response ID/LAST mismatch")
      if(axi.bvalid && axi.bid!==0) `uvm_error("AXI_WRITE_SHAPE","Write response ID mismatch")
      if(aw_pending>1 || w_pending>1 || ar_pending>1)
        `uvm_error("AXI_OUTSTANDING","More than one outstanding beat in baseline")
    end
  end
endmodule
