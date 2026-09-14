`timescale 1ns/1ps
module assertion_probe;
  bit clk = 0;
  bit enabled = 0;
  bit signal_ok = 1;
  int detected = 0;
  always #5 clk = ~clk;
  check_signal: assert property (@(posedge clk) disable iff (!enabled) signal_ok)
    else detected++;
  initial begin
    @(negedge clk); enabled = 1;
    @(negedge clk); signal_ok = 0;
    @(negedge clk); signal_ok = 1;
    @(negedge clk);
    if (detected == 0) begin
      $display("PROBE_FEATURE_INACTIVE: concurrent assertions were not executed");
    end else if (detected != 1) begin
      $fatal(1, "Expected exactly one assertion detection, saw %0d", detected);
    end else begin
      $display("assertion_probe PASSED: intentional violation detected once");
    end
    $finish;
  end
endmodule
