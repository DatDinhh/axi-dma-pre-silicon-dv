//==============================================================================
// tb/interfaces/axil_if.sv
//------------------------------------------------------------------------------
// AXI4-Lite Interface (Register Bus) for DMA programming
//
// TB Side:  AXI-Lite Master (driver)
// DUT Side: AXI-Lite Slave  (register block)
//
// Signals implemented (AXI4-Lite subset):
//  - AW: AWADDR, AWPROT, AWVALID, AWREADY
//  - W : WDATA, WSTRB,  WVALID,  WREADY
//  - B : BRESP, BVALID, BREADY
//  - AR: ARADDR, ARPROT, ARVALID, ARREADY
//  - R : RDATA, RRESP,  RVALID,  RREADY
//
// Notes:
// - Data width defaults to 32 (per spec).
// - This interface includes clocking blocks for clean drive/sample timing.
//==============================================================================

`ifndef AXIL_IF_SV
`define AXIL_IF_SV

interface axil_if #(
  parameter int unsigned ADDR_WIDTH = 32,
  parameter int unsigned DATA_WIDTH = 32
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
  // AXI4-Lite channel signals
  //--------------------------------------------------------------------------

  // Write Address Channel
  logic [ADDR_WIDTH-1:0] awaddr;
  logic [2:0]            awprot;
  logic                  awvalid;
  logic                  awready;

  // Write Data Channel
  logic [DATA_WIDTH-1:0] wdata;
  logic [STRB_WIDTH-1:0] wstrb;
  logic                  wvalid;
  logic                  wready;

  // Write Response Channel
  logic [1:0]            bresp;
  logic                  bvalid;
  logic                  bready;

  // Read Address Channel
  logic [ADDR_WIDTH-1:0] araddr;
  logic [2:0]            arprot;
  logic                  arvalid;
  logic                  arready;

  // Read Data Channel
  logic [DATA_WIDTH-1:0] rdata;
  logic [1:0]            rresp;
  logic                  rvalid;
  logic                  rready;

  //--------------------------------------------------------------------------
  // Clocking blocks (recommended for UVM drivers/monitors)
  //--------------------------------------------------------------------------
  // Master clocking block: TB drives address/data/control, samples ready/resp/data
  clocking cb_master @(posedge clk);
    default input #1step output #1step;

    // Outputs driven by AXI-Lite master (TB)
    output awaddr, awprot, awvalid;
    output wdata,  wstrb,  wvalid;
    output bready;
    output araddr, arprot, arvalid;
    output rready;

    // Inputs observed from AXI-Lite slave (DUT)
    input  awready;
    input  wready;
    input  bresp, bvalid;
    input  arready;
    input  rdata, rresp, rvalid;
  endclocking

  // Monitor clocking block: passive observation of all signals
  clocking cb_mon @(posedge clk);
    default input #1step output #1step;

    input awaddr, awprot, awvalid, awready;
    input wdata,  wstrb,  wvalid,  wready;
    input bresp,  bvalid, bready;
    input araddr, arprot, arvalid, arready;
    input rdata,  rresp,  rvalid,  rready;
  endclocking

  //--------------------------------------------------------------------------
  // Modports
  //--------------------------------------------------------------------------
  // TB Master Driver uses cb_master (preferred)
  modport master (
    input  clk,
    input  rst_n,
    clocking cb_master
  );

  // DUT Slave connects to raw signals (synthesizable-style hookup)
  modport slave (
    input  clk,
    input  rst_n,

    // Slave receives these from master
    input  awaddr,
    input  awprot,
    input  awvalid,
    input  wdata,
    input  wstrb,
    input  wvalid,
    input  bready,
    input  araddr,
    input  arprot,
    input  arvalid,
    input  rready,

    // Slave drives these back to master
    output awready,
    output wready,
    output bresp,
    output bvalid,
    output arready,
    output rdata,
    output rresp,
    output rvalid
  );

  // Passive monitor uses cb_mon (preferred)
  modport monitor (
    input  clk,
    input  rst_n,
    clocking cb_mon
  );

endinterface : axil_if

`endif // AXIL_IF_SV
