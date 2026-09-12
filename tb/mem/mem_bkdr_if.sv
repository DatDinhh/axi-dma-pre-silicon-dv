//==============================================================================
// tb/mem/mem_bkdr_if.sv
//------------------------------------------------------------------------------
// Backdoor memory interface so UVM tests can initialize/compare memory without
// hierarchical access from a package (ModelSim-Intel restriction).
//==============================================================================

`ifndef MEM_BKDR_IF_SV
`define MEM_BKDR_IF_SV

interface mem_bkdr_if;

  // Keep consistent with tb_top localparam MEM_SIZE_BYTES (64KB)
  localparam int unsigned MEM_SIZE_BYTES = 64 * 1024;

  // Byte-addressed storage
  byte unsigned mem [0:MEM_SIZE_BYTES-1];

  // ---- Backdoor helper tasks (callable via virtual interface) ----

  task automatic init_zero();
    int unsigned i;
    for (i = 0; i < MEM_SIZE_BYTES; i++) mem[i] = 8'h00;
  endtask

  task automatic write_byte(input int unsigned addr, input byte unsigned data);
    if (addr >= MEM_SIZE_BYTES) begin
      $fatal(1, "[MEM_BKDR] write_byte OOR addr=0x%0h", addr);
    end
    mem[addr] = data;
  endtask

  task automatic read_byte(input int unsigned addr, output byte unsigned data);
    if (addr >= MEM_SIZE_BYTES) begin
      $fatal(1, "[MEM_BKDR] read_byte OOR addr=0x%0h", addr);
    end
    data = mem[addr];
  endtask

  task automatic fill_const(input int unsigned base, input int unsigned len, input byte unsigned value);
    int unsigned i;
    if ((base + len) > MEM_SIZE_BYTES) begin
      $fatal(1, "[MEM_BKDR] fill_const OOR base=0x%0h len=%0d", base, len);
    end
    for (i = 0; i < len; i++) mem[base + i] = value;
  endtask

  task automatic fill_inc(input int unsigned base, input int unsigned len, input byte unsigned seed);
    int unsigned i;
    if ((base + len) > MEM_SIZE_BYTES) begin
      $fatal(1, "[MEM_BKDR] fill_inc OOR base=0x%0h len=%0d", base, len);
    end
    for (i = 0; i < len; i++) mem[base + i] = seed + byte'(i);
  endtask

endinterface

`endif // MEM_BKDR_IF_SV
