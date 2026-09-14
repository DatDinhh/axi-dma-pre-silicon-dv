// Checker self-test. +INJECT_STALL_ERROR=1 intentionally produces exactly
// one UVM_ERROR; run separately from DUT regressions and require UNIT_PASS.
`timescale 1ns/1ps
module rv_stability_test;
  import uvm_pkg::*;
  logic clk = 0;
  always #5 clk = ~clk;
  logic rst_n = 0, valid = 0, ready = 0;
  logic [31:0] payload = 0;
  integer inject_error = 0;
  uvm_report_server server;
  rv_stability_check #(.WIDTH(32), .LABEL("selftest")) dut(clk, rst_n, valid, ready, payload);
  initial begin
    void'($value$plusargs("INJECT_STALL_ERROR=%d", inject_error));
    repeat (3) @(negedge clk);
    rst_n = 1;
    @(negedge clk); valid = 1; ready = 0; payload = 32'h12345678;
    repeat (3) @(negedge clk);
    if (inject_error) payload = 32'hbad00001;
    @(negedge clk); ready = 1;
    @(negedge clk); valid = 0;
    @(negedge clk);
    server = uvm_report_server::get_server();
    if (server.get_severity_count(UVM_ERROR) != (inject_error ? 1 : 0) ||
        server.get_severity_count(UVM_FATAL) != 0)
      $fatal(1, "Checker self-test unexpected report count: errors=%0d", server.get_severity_count(UVM_ERROR));
    if (inject_error && server.get_id_count("PROTOCOL_STABILITY") != 1)
      $fatal(1, "Expected precisely one PROTOCOL_STABILITY report");
    if (dut.handshakes != 1 || dut.stall_samples != 4)
      $fatal(1, "Checker activity counters wrong: handshakes=%0d stalls=%0d", dut.handshakes, dut.stall_samples);
    server.report_summarize();
    $display("UNIT_PASS rv_stability expected_errors=%0d observed_errors=%0d", inject_error ? 1 : 0,
      server.get_severity_count(UVM_ERROR));
    $finish;
  end
endmodule
