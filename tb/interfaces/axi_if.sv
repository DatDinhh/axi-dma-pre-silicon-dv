//==============================================================================
// tb/interfaces/axi_if.sv
//------------------------------------------------------------------------------
// AXI4 Interface (Full AXI) for DMA data port
//
// DUT Side: AXI MASTER (DMA engine)
// TB Side : AXI SLAVE  (memory model/agent)
//
// Implemented signals (AXI4 subset):
//  - AW: AWID, AWADDR, AWLEN, AWSIZE, AWBURST, AWLOCK, AWCACHE, AWPROT, AWQOS,
//        AWVALID, AWREADY
//  - W : WDATA, WSTRB, WLAST, WVALID, WREADY
//  - B : BID, BRESP, BVALID, BREADY
//  - AR: ARID, ARADDR, ARLEN, ARSIZE, ARBURST, ARLOCK, ARCACHE, ARPROT, ARQOS,
//        ARVALID, ARREADY
//  - R : RID, RDATA, RRESP, RLAST, RVALID, RREADY
//
// Notes:
// - This is a verification-friendly interface: includes clocking blocks for UVM.
// - Not all optional AXI signals (USER, REGION) are included.
//==============================================================================

`ifndef AXI_IF_SV
`define AXI_IF_SV

interface axi_if #(
  parameter int unsigned ADDR_WIDTH = 32,
  parameter int unsigned DATA_WIDTH = 32,
  parameter int unsigned ID_WIDTH   = 1
)(
  input logic clk,
  input logic rst_n
);

  timeunit 1ns;
  timeprecision 1ps;

  //--------------------------------------------------------------------------
  // Local parameters
  //--------------------------------------------------------------------------
  localparam int unsigned STRB_WIDTH = (DATA_WIDTH / 8);

  //--------------------------------------------------------------------------
  // Write Address Channel (AW)
  //--------------------------------------------------------------------------
  logic [ID_WIDTH-1:0]    awid;
  logic [ADDR_WIDTH-1:0]  awaddr;
  logic [7:0]             awlen;     // beats-1
  logic [2:0]             awsize;    // log2(bytes per beat)
  logic [1:0]             awburst;   // INCR/FIXED/WRAP
  logic                   awlock;    // AXI4: 1-bit lock
  logic [3:0]             awcache;
  logic [2:0]             awprot;
  logic [3:0]             awqos;
  logic                   awvalid;
  logic                   awready;

  //--------------------------------------------------------------------------
  // Write Data Channel (W)
  //--------------------------------------------------------------------------
  logic [DATA_WIDTH-1:0]  wdata;
  logic [STRB_WIDTH-1:0]  wstrb;
  logic                   wlast;
  logic                   wvalid;
  logic                   wready;

  //--------------------------------------------------------------------------
  // Write Response Channel (B)
  //--------------------------------------------------------------------------
  logic [ID_WIDTH-1:0]    bid;
  logic [1:0]             bresp;
  logic                   bvalid;
  logic                   bready;

  //--------------------------------------------------------------------------
  // Read Address Channel (AR)
  //--------------------------------------------------------------------------
  logic [ID_WIDTH-1:0]    arid;
  logic [ADDR_WIDTH-1:0]  araddr;
  logic [7:0]             arlen;     // beats-1
  logic [2:0]             arsize;    // log2(bytes per beat)
  logic [1:0]             arburst;   // INCR/FIXED/WRAP
  logic                   arlock;    // AXI4: 1-bit lock
  logic [3:0]             arcache;
  logic [2:0]             arprot;
  logic [3:0]             arqos;
  logic                   arvalid;
  logic                   arready;

  //--------------------------------------------------------------------------
  // Read Data Channel (R)
  //--------------------------------------------------------------------------
  logic [ID_WIDTH-1:0]    rid;
  logic [DATA_WIDTH-1:0]  rdata;
  logic [1:0]             rresp;
  logic                   rlast;
  logic                   rvalid;
  logic                   rready;

  //--------------------------------------------------------------------------
  // Clocking blocks
  //--------------------------------------------------------------------------

  // Master clocking block: TB/driver view when controlling the AXI master
  // (Useful if you ever create a TB AXI master; for this project DUT is master.)
`ifndef DMA_RAW_INTERFACES
  clocking cb_master @(posedge clk);
    default input #1step output #1step;

    // Master-driven outputs
    output awid, awaddr, awlen, awsize, awburst, awlock, awcache, awprot, awqos, awvalid;
    output wdata, wstrb, wlast, wvalid;
    output bready;
    output arid, araddr, arlen, arsize, arburst, arlock, arcache, arprot, arqos, arvalid;
    output rready;

    // Slave-driven inputs
    input  awready;
    input  wready;
    input  bid, bresp, bvalid;
    input  arready;
    input  rid, rdata, rresp, rlast, rvalid;
  endclocking
`endif // DMA_RAW_INTERFACES

  // Slave clocking block: TB memory agent drives READY/RESP/DATA back to DUT
`ifndef DMA_RAW_INTERFACES
  clocking cb_slave @(posedge clk);
    default input #1step output #1step;

    // Slave-driven outputs
    output awready;
    output wready;
    output bid, bresp, bvalid;
    output arready;
    output rid, rdata, rresp, rlast, rvalid;

    // Master-driven inputs
    input  awid, awaddr, awlen, awsize, awburst, awlock, awcache, awprot, awqos, awvalid;
    input  wdata, wstrb, wlast, wvalid;
    input  bready;
    input  arid, araddr, arlen, arsize, arburst, arlock, arcache, arprot, arqos, arvalid;
    input  rready;
  endclocking
`endif // DMA_RAW_INTERFACES

  // Passive monitor clocking block
`ifndef DMA_RAW_INTERFACES
  clocking cb_mon @(posedge clk);
    default input #1step output #1step;

    input awid, awaddr, awlen, awsize, awburst, awlock, awcache, awprot, awqos, awvalid, awready;
    input wdata, wstrb, wlast, wvalid, wready;
    input bid, bresp, bvalid, bready;
    input arid, araddr, arlen, arsize, arburst, arlock, arcache, arprot, arqos, arvalid, arready;
    input rid, rdata, rresp, rlast, rvalid, rready;
  endclocking
`endif // DMA_RAW_INTERFACES

  //--------------------------------------------------------------------------
  // Modports
  //--------------------------------------------------------------------------

  // DUT as AXI master (synth-style connection)
  modport master (
    input  clk,
    input  rst_n,

    // Master drives:
    output awid, awaddr, awlen, awsize, awburst, awlock, awcache, awprot, awqos, awvalid,
    output wdata, wstrb, wlast, wvalid,
    output bready,
    output arid, araddr, arlen, arsize, arburst, arlock, arcache, arprot, arqos, arvalid,
    output rready,

    // Master receives:
    input  awready,
    input  wready,
    input  bid, bresp, bvalid,
    input  arready,
    input  rid, rdata, rresp, rlast, rvalid
  );

  // TB memory model as AXI slave (synth-style connection)
  modport slave (
    input  clk,
    input  rst_n,

    // Slave receives:
    input  awid, awaddr, awlen, awsize, awburst, awlock, awcache, awprot, awqos, awvalid,
    input  wdata, wstrb, wlast, wvalid,
    input  bready,
    input  arid, araddr, arlen, arsize, arburst, arlock, arcache, arprot, arqos, arvalid,
    input  rready,

    // Slave drives:
    output awready,
    output wready,
    output bid, bresp, bvalid,
    output arready,
    output rid, rdata, rresp, rlast, rvalid
  );

  // UVM drivers can use the clocking blocks directly (recommended)
`ifndef DMA_RAW_INTERFACES
  modport master_drv (
    input  clk,
    input  rst_n,
    clocking cb_master
  );
`endif // DMA_RAW_INTERFACES

`ifndef DMA_RAW_INTERFACES
  modport slave_drv (
    input  clk,
    input  rst_n,
    clocking cb_slave
  );
`endif // DMA_RAW_INTERFACES

  // Passive monitor
`ifndef DMA_RAW_INTERFACES
  modport monitor (
    input  clk,
    input  rst_n,
    clocking cb_mon
  );
`endif // DMA_RAW_INTERFACES

endinterface : axi_if

`endif // AXI_IF_SV
