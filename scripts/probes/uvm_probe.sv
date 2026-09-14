`timescale 1ns/1ps
package uvm_probe_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  class uvm_probe_test extends uvm_test;
    `uvm_component_utils(uvm_probe_test)
    function new(string name = "uvm_probe_test", uvm_component parent = null);
      super.new(name, parent);
    endfunction
    task run_phase(uvm_phase phase);
      phase.raise_objection(this);
      #10;
      `uvm_info("PROBE", "uvm_probe PASSED", UVM_LOW)
      phase.drop_objection(this);
    endtask
  endclass
endpackage
module uvm_probe;
  import uvm_pkg::*;
  import uvm_probe_pkg::*;
  initial run_test("uvm_probe_test");
endmodule
