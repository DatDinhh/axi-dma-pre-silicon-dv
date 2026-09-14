`timescale 1ns/1ps
module constrained_random_probe;
  class transaction;
    rand int unsigned value;
    constraint legal { value inside {[10:20]}; value % 2 == 0; }
  endclass
  transaction item;
  initial begin
    item = new();
    repeat (64) begin
      if (!item.randomize()) $fatal(1, "Randomization failed");
      if (item.value < 10 || item.value > 20 || item.value % 2 != 0)
        $fatal(1, "Constraint was not enforced");
    end
    $display("constrained_random_probe PASSED");
    $finish;
  end
endmodule
