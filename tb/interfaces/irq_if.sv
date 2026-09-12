//==============================================================================
// tb/interfaces/irq_if.sv
//------------------------------------------------------------------------------
// Simple interrupt interface for DUT -> TB observation.
// - DUT drives irq (level)
// - TB monitors irq and can use the included clocking block for sampling
//==============================================================================

`ifndef IRQ_IF_SV
`define IRQ_IF_SV

interface irq_if (
  input logic clk,
  input logic rst_n
);

  timeunit 1ns;
  timeprecision 1ps;

  //--------------------------------------------------------------------------
  // Signal
  //--------------------------------------------------------------------------
  logic irq;

  //--------------------------------------------------------------------------
  // Clocking blocks
  //--------------------------------------------------------------------------
  // Monitor clocking block: sample irq synchronously
  clocking cb_mon @(posedge clk);
    default input #1step output #1step;
    input irq;
  endclocking

  //--------------------------------------------------------------------------
  // Modports
  //--------------------------------------------------------------------------

  // DUT drives irq
  modport dut (
    input  clk,
    input  rst_n,
    output irq
  );

  // TB monitors irq
  modport monitor (
    input  clk,
    input  rst_n,
    clocking cb_mon
  );

endinterface : irq_if

`endif // IRQ_IF_SV
