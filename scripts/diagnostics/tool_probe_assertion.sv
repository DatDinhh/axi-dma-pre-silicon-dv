`timescale 1ns/1ps
module tool_probe_assertion;
  bit clk = 0;
  bit rst_n = 0;
  bit valid = 0;
  bit ready = 0;
  logic [7:0] payload = 0;
  always #5 clk = ~clk;
  hold: assert property (@(posedge clk) disable iff (!rst_n)
    valid && !ready |=> valid && $stable(payload))
    else $error("TOOL_PROBE_SVA_DETECTED: payload changed while stalled");
  released: cover property (@(posedge clk) rst_n && valid && ready);
  stalled: cover property (@(posedge clk) rst_n && valid && !ready);
  initial begin
    @(negedge clk); rst_n = 1; valid = 1; payload = 8'h5a;
    @(negedge clk);
    if ($test$plusargs("VIOLATE")) payload = 8'hc3;
    @(negedge clk); ready = 1;
    @(negedge clk); valid = 0;
    @(negedge clk);
    $display("TOOL_PROBE_ASSERTION_PASS");
    $finish;
  end
endmodule
