`timescale 1ns/1ps
module covergroup_probe;
  bit sample_value;
  covergroup cg;
    option.per_instance = 1;
    cp: coverpoint sample_value { bins zero = {0}; bins one = {1}; }
  endgroup
  cg coverage_model;
  real measured;
  initial begin
    coverage_model = new();
    sample_value = 0; coverage_model.sample();
    sample_value = 1; coverage_model.sample();
    measured = coverage_model.get_inst_coverage();
    if (measured < 99.99) $fatal(1, "Covergroup sampling/query not active: %0f", measured);
    $display("covergroup_probe PASSED: two probe bins sampled, coverage=%0f", measured);
    $finish;
  end
endmodule
