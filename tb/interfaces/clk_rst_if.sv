//==============================================================================
// tb/interfaces/clk_rst_if.sv
//------------------------------------------------------------------------------
// Clock/Reset interface for TB <-> DUT hookup.
// - Holds clk and rst_n signals
// - Provides helper tasks for common TB operations
//
// Usage (typical in tb_top):
//   clk_rst_if clkif();
//
//   initial fork
//     clkif.drive_clock();     // free-running clock
//   join_none
//
//   initial begin
//     clkif.apply_reset();     // synchronous reset sequence
//   end
//
// Notes:
// - drive_clock() is intentionally a blocking forever task; run it in a fork.
//==============================================================================

`ifndef CLK_RST_IF_SV
`define CLK_RST_IF_SV

interface clk_rst_if #(
  parameter time         CLK_PERIOD   = 10ns,  // default 100 MHz
  parameter int unsigned RESET_CYCLES  = 5      // number of clk cycles reset is held low
) ();

  timeunit 1ns;
  timeprecision 1ps;

  // ---------------------------------------------------------------------------
  // Signals
  // ---------------------------------------------------------------------------
  logic clk;
  logic rst_n;

  // ---------------------------------------------------------------------------
  // Safe defaults at time 0 (avoids Xs during early bring-up)
  // ---------------------------------------------------------------------------
  initial begin
    clk   = 1'b0;
    rst_n = 1'b0;
  end

  // ---------------------------------------------------------------------------
  // Helper tasks
  // ---------------------------------------------------------------------------

  // Free-running clock generator.
  // Run in a forked process from tb_top.
  task automatic drive_clock(input time period = CLK_PERIOD);
    // Ensure defined start state
    clk = 1'b0;
    forever #(period/2) clk = ~clk;
  endtask

  // Apply a synchronous active-low reset for N cycles.
  // Reset is asserted/deasserted on falling edges, away from sampling edges.
  task automatic apply_reset(input int unsigned cycles = RESET_CYCLES, input bit at_negedge = 0);
    if (!at_negedge) @(negedge clk);
    rst_n = 1'b0;
    // Hold reset for a deterministic number of rising edges
    repeat (cycles) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;
    // Optional: allow one cycle for downstream stabilization
    @(posedge clk);
  endtask

  // Wait for a number of rising edges.
  task automatic wait_cycles(input int unsigned cycles);
    repeat (cycles) @(posedge clk);
  endtask

  // Wait for a number of falling edges.
  task automatic wait_negedges(input int unsigned cycles);
    repeat (cycles) @(negedge clk);
  endtask

  // Wait until reset is deasserted (rst_n==1).
  task automatic wait_reset_deassert();
    @(posedge rst_n);
  endtask

  // Quick helper: true when in reset
  function automatic bit in_reset();
    return (rst_n !== 1'b1);
  endfunction

  // ---------------------------------------------------------------------------
  // Modports
  // ---------------------------------------------------------------------------
  // TB drives clk/rst_n.
  modport tb (
    output clk,
    output rst_n,
    import drive_clock,
    import apply_reset,
    import wait_cycles,
    import wait_negedges,
    import wait_reset_deassert,
    import in_reset
  );

  // DUT consumes clk/rst_n.
  modport dut (
    input clk,
    input rst_n
  );

endinterface : clk_rst_if

`endif // CLK_RST_IF_SV
