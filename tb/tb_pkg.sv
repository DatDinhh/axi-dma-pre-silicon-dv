//==============================================================================
// tb/tb_pkg.sv
//------------------------------------------------------------------------------
// UVM tests for AXI DMA pre-silicon DV (ModelSim-Intel friendly)
//
// Supports:
//   - smoke_test        : sanity (regs + start + done)
//   - copy_test         : functional copy (SRC pattern -> DST compare)
//   - len_zero_test     : negative (LEN=0)      expect ERR_LEN_ZERO
//   - unaligned_addr_test: negative (SRC misaligned) expect ERR_ALIGN
//   - out_of_range_test : negative (SRC out-of-range) expect ERR_RANGE
//
// Tool notes (Intel ModelSim Starter Edition):
//   - Compile with +define+UVM_NO_DPI
//   - Use +UVM_TESTNAME=<test> to select test (works under UVM_NO_DPI)
//
// Memory backdoor:
//   - Uses virtual mem_bkdr_if (mem_vif) provided by tb_top via uvm_config_db.
//   - NO hierarchical $root / tb_top accesses inside this package.
//==============================================================================

`ifndef TB_PKG_SV
`define TB_PKG_SV

package tb_pkg;

  timeunit 1ns;
  timeprecision 1ps;

  //--------------------------------------------------------------------------
  // Imports
  //--------------------------------------------------------------------------
  import uvm_pkg::*;
  `include "uvm_macros.svh"

  import dma_pkg::*;

  //--------------------------------------------------------------------------
  // Localparams (match tb_top.sv)
  //--------------------------------------------------------------------------
  localparam int unsigned ADDR_WIDTH      = 32;
  localparam int unsigned AXIL_DATA_WIDTH = 32;
  localparam int unsigned AXI_DATA_WIDTH  = 32;
  localparam int unsigned AXI_ID_WIDTH    = 1;

  localparam int unsigned AXIL_STRB_WIDTH = (AXIL_DATA_WIDTH/8);
  localparam int unsigned MEM_SIZE_BYTES  = 64 * 1024;

  //--------------------------------------------------------------------------
  // VIF typedefs
  //--------------------------------------------------------------------------
  typedef virtual axil_if #(ADDR_WIDTH, AXIL_DATA_WIDTH)              axil_vif_t;
  typedef virtual axi_if  #(ADDR_WIDTH, AXI_DATA_WIDTH, AXI_ID_WIDTH) axi_vif_t;
  typedef virtual irq_if                                              irq_vif_t;
  typedef virtual mem_bkdr_if                                         mem_vif_t;

  //--------------------------------------------------------------------------
  // AXI-Lite: drive master to idle
  //--------------------------------------------------------------------------
  task automatic axil_master_idle(axil_vif_t vif);
    @(vif.cb_master);
    vif.cb_master.awaddr  <= '0;
    vif.cb_master.awprot  <= 3'b000;
    vif.cb_master.awvalid <= 1'b0;

    vif.cb_master.wdata   <= '0;
    vif.cb_master.wstrb   <= '0;
    vif.cb_master.wvalid  <= 1'b0;

    vif.cb_master.bready  <= 1'b0;

    vif.cb_master.araddr  <= '0;
    vif.cb_master.arprot  <= 3'b000;
    vif.cb_master.arvalid <= 1'b0;

    vif.cb_master.rready  <= 1'b0;
  endtask

  //--------------------------------------------------------------------------
  // AXI-Lite write32 (ModelSim friendly: do NOT read cb_master outputs)
  //--------------------------------------------------------------------------
  task automatic axil_write32(
    axil_vif_t                    vif,
    input  logic [ADDR_WIDTH-1:0] addr,
    input  logic [31:0]           data,
    output logic [1:0]            bresp,
    input  int unsigned           timeout_cycles = 2000
  );
    bit aw_pending;
    bit w_pending;
    int unsigned cyc;

    bresp      = 2'bxx;
    aw_pending = 1'b1;
    w_pending  = 1'b1;

    @(vif.cb_master);
    vif.cb_master.awaddr  <= addr;
    vif.cb_master.awprot  <= 3'b000;
    vif.cb_master.awvalid <= 1'b1;

    vif.cb_master.wdata   <= data;
    vif.cb_master.wstrb   <= {AXIL_STRB_WIDTH{1'b1}};
    vif.cb_master.wvalid  <= 1'b1;

    vif.cb_master.bready  <= 1'b1;

    for (cyc = 0; cyc < timeout_cycles; cyc++) begin
      @(vif.cb_master);

      if (aw_pending && vif.cb_master.awready) begin
        aw_pending = 1'b0;
        vif.cb_master.awvalid <= 1'b0;
      end

      if (w_pending && vif.cb_master.wready) begin
        w_pending = 1'b0;
        vif.cb_master.wvalid <= 1'b0;
      end

      if (!aw_pending && !w_pending && vif.cb_master.bvalid) begin
        bresp = vif.cb_master.bresp;

        @(vif.cb_master);
        vif.cb_master.bready <= 1'b0;
        return;
      end
    end

    @(vif.cb_master);
    vif.cb_master.awvalid <= 1'b0;
    vif.cb_master.wvalid  <= 1'b0;
    vif.cb_master.bready  <= 1'b0;

    `uvm_fatal("AXIL_WRITE_TO",
      $sformatf("AXI-Lite WRITE timeout after %0d cycles (addr=0x%08h data=0x%08h)",
                timeout_cycles, addr, data))
  endtask

  //--------------------------------------------------------------------------
  // AXI-Lite read32 (ModelSim friendly: do NOT read cb_master outputs)
  //--------------------------------------------------------------------------
  task automatic axil_read32(
    axil_vif_t                    vif,
    input  logic [ADDR_WIDTH-1:0] addr,
    output logic [31:0]           data,
    output logic [1:0]            rresp,
    input  int unsigned           timeout_cycles = 2000
  );
    bit ar_pending;
    int unsigned cyc;

    data       = 'x;
    rresp      = 2'bxx;
    ar_pending = 1'b1;

    @(vif.cb_master);
    vif.cb_master.araddr  <= addr;
    vif.cb_master.arprot  <= 3'b000;
    vif.cb_master.arvalid <= 1'b1;
    vif.cb_master.rready  <= 1'b1;

    for (cyc = 0; cyc < timeout_cycles; cyc++) begin
      @(vif.cb_master);

      if (ar_pending && vif.cb_master.arready) begin
        ar_pending = 1'b0;
        vif.cb_master.arvalid <= 1'b0;
      end

      if (!ar_pending && vif.cb_master.rvalid) begin
        data  = vif.cb_master.rdata;
        rresp = vif.cb_master.rresp;

        @(vif.cb_master);
        vif.cb_master.rready <= 1'b0;
        return;
      end
    end

    @(vif.cb_master);
    vif.cb_master.arvalid <= 1'b0;
    vif.cb_master.rready  <= 1'b0;

    `uvm_fatal("AXIL_READ_TO",
      $sformatf("AXI-Lite READ timeout after %0d cycles (addr=0x%08h)", timeout_cycles, addr))
  endtask

  //--------------------------------------------------------------------------
  // base_test
  //--------------------------------------------------------------------------
  class base_test extends uvm_test;
    `uvm_component_utils(base_test)

    axil_vif_t axil_vif;
    axi_vif_t  axi_vif;
    irq_vif_t  irq_vif;
    mem_vif_t  mem_vif;

    function new(string name="base_test", uvm_component parent=null);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);

      if (!uvm_config_db#(axil_vif_t)::get(this, "", "axil_vif", axil_vif))
        `uvm_fatal("NOVIF", "axil_vif not found in uvm_config_db")

      if (!uvm_config_db#(irq_vif_t)::get(this, "", "irq_vif", irq_vif))
        `uvm_fatal("NOVIF", "irq_vif not found in uvm_config_db")

      if (!uvm_config_db#(axi_vif_t)::get(this, "", "axi_vif", axi_vif))
        `uvm_warning("NOVIF", "axi_vif not found (OK for now)")

      if (!uvm_config_db#(mem_vif_t)::get(this, "", "mem_vif", mem_vif))
        `uvm_warning("NOVIF", "mem_vif not found (copy/data tests will fail)")
    endfunction

    // ---- Common helpers ----

    task automatic wait_for_reset_release();
      if (axil_vif.rst_n !== 1'b1) begin
        `uvm_info("RESET", "Waiting for reset deassertion...", UVM_LOW)
        wait (axil_vif.rst_n === 1'b1);
      end
      @(posedge axil_vif.clk);
      `uvm_info("RESET", "Reset deasserted.", UVM_LOW)
    endtask

    task automatic wait_irq_level(input bit level, input int unsigned timeout_cycles = 400000);
      int unsigned i;
      for (i = 0; i < timeout_cycles; i++) begin
        @(posedge axil_vif.clk);
        if (irq_vif.irq === level) return;
      end
      `uvm_fatal("IRQ_TO", $sformatf("Timeout waiting for irq=%0d after %0d cycles", level, timeout_cycles))
    endtask

    task automatic write_reg_okay(input logic [ADDR_WIDTH-1:0] off, input logic [31:0] data);
      logic [1:0] bresp;
      axil_write32(axil_vif, off, data, bresp);
      if (bresp !== 2'b00)
        `uvm_fatal("AXIL_BRESP", $sformatf("Write 0x%08h got BRESP=%b (expected OKAY)", off, bresp))
    endtask

    task automatic read_reg_okay(input logic [ADDR_WIDTH-1:0] off, output logic [31:0] data);
      logic [1:0] rresp;
      axil_read32(axil_vif, off, data, rresp);
      if (rresp !== 2'b00)
        `uvm_fatal("AXIL_RRESP", $sformatf("Read 0x%08h got RRESP=%b (expected OKAY)", off, rresp))
    endtask

    task automatic start_dma_irq_en();
      // recommended: write IRQ_EN then write IRQ_EN|START (to guarantee start pulse)
      write_reg_okay(REG_OFF_CTRL, (32'd1 << CTRL_IRQ_EN_BIT));
      write_reg_okay(REG_OFF_CTRL, (32'd1 << CTRL_IRQ_EN_BIT) |
                               (32'd1 << CTRL_START_BIT));
    endtask

    task automatic clear_irqs_all();
      // RW1C bits
      write_reg_okay(REG_OFF_IRQ_STATUS,
                     (32'd1 << IRQSTAT_DONE_BIT) |
                     (32'd1 << IRQSTAT_ERR_BIT));
    endtask

    task automatic clear_irq_done();
      write_reg_okay(REG_OFF_IRQ_STATUS, (32'd1 << IRQSTAT_DONE_BIT));
    endtask

    task automatic clear_irq_err();
      write_reg_okay(REG_OFF_IRQ_STATUS, (32'd1 << IRQSTAT_ERR_BIT));
    endtask

    task automatic expect_error(
      input  logic [7:0] exp_err_code,
      input  bit         allow_done_bit = 0
    );
      logic [31:0] status;
      logic [31:0] irq_status;
      logic [31:0] err_code;

      read_reg_okay(REG_OFF_STATUS,     status);
      read_reg_okay(REG_OFF_IRQ_STATUS, irq_status);
      read_reg_okay(REG_OFF_ERR_CODE,   err_code);

      `uvm_info("NEG",
        $sformatf("STATUS=0x%08h IRQ_STATUS=0x%08h ERR_CODE=0x%08h",
                  status, irq_status, err_code),
        UVM_LOW)

      if (status[STATUS_ERR_BIT] !== 1'b1)
        `uvm_fatal("NEG_CHK", "Expected STATUS.ERR=1 for negative test")

      if (!allow_done_bit && (status[STATUS_DONE_BIT] === 1'b1))
        `uvm_fatal("NEG_CHK", "Expected STATUS.DONE=0 for error case")

      if (irq_status[IRQSTAT_ERR_BIT] !== 1'b1)
        `uvm_fatal("NEG_CHK", "Expected IRQ_STATUS.ERR=1 (IRQ asserted due to error)")

      if (err_code[7:0] !== exp_err_code)
        `uvm_fatal("NEG_CHK",
          $sformatf("Expected ERR_CODE=0x%02h, got 0x%02h", exp_err_code, err_code[7:0]))
    endtask

  endclass : base_test

  //--------------------------------------------------------------------------
  // smoke_test (basic sanity)
  //--------------------------------------------------------------------------
  class smoke_test extends base_test;
    `uvm_component_utils(smoke_test)

    function new(string name="smoke_test", uvm_component parent=null);
      super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
      logic [31:0] status, err_code;

      logic [31:0] src = 32'h0000_0000;
      logic [31:0] dst = 32'h0000_0100;
      logic [31:0] len = 32'h0000_0040; // 64B

      phase.raise_objection(this);

      wait_for_reset_release();
      axil_master_idle(axil_vif);
      clear_irqs_all();

      `uvm_info("SMOKE", "Programming regs + starting DMA...", UVM_LOW)
      write_reg_okay(REG_OFF_SRC_ADDR, src);
      write_reg_okay(REG_OFF_DST_ADDR, dst);
      write_reg_okay(REG_OFF_LEN,      len);

      start_dma_irq_en();

      `uvm_info("SMOKE", "Waiting for DONE irq...", UVM_LOW)
      wait_irq_level(1'b1);

      read_reg_okay(REG_OFF_STATUS,   status);
      read_reg_okay(REG_OFF_ERR_CODE, err_code);

      if (status[STATUS_DONE_BIT] !== 1'b1)
        `uvm_fatal("SMOKE_CHK", "Expected STATUS.DONE=1")
      if (status[STATUS_ERR_BIT] !== 1'b0)
        `uvm_fatal("SMOKE_CHK", "Expected STATUS.ERR=0")
      if (err_code[7:0] !== ERR_NONE)
        `uvm_fatal("SMOKE_CHK", $sformatf("Expected ERR_NONE, got 0x%0h", err_code[7:0]))

      clear_irq_done();
      wait_irq_level(1'b0);

      `uvm_info("SMOKE", "smoke_test PASSED.", UVM_LOW)
      phase.drop_objection(this);
    endtask
  endclass : smoke_test

  //--------------------------------------------------------------------------
  // copy_test (functional data movement)
  //--------------------------------------------------------------------------
  class copy_test extends base_test;
    `uvm_component_utils(copy_test)

    function new(string name="copy_test", uvm_component parent=null);
      super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
      logic [31:0] src = 32'h0000_0000;
      logic [31:0] dst = 32'h0000_0200;
      logic [31:0] len = 32'h0000_0080; // 128B (multiple of 4)

      int unsigned  src_base, dst_base, len_bytes;
      int unsigned  i;
      byte unsigned seed;
      byte unsigned s, d;

      logic [31:0] err_code;
      logic [31:0] status;

      phase.raise_objection(this);

      wait_for_reset_release();
      axil_master_idle(axil_vif);
      clear_irqs_all();

      if (mem_vif == null)
        `uvm_fatal("COPY", "mem_vif is null (tb_top must set mem_vif in config_db)")

      src_base  = src;
      dst_base  = dst;
      len_bytes = len;
      seed      = 8'h3C;

      `uvm_info("COPY",
        $sformatf("Init mem + run DMA: SRC=0x%08h DST=0x%08h LEN=%0d", src, dst, len_bytes),
        UVM_LOW)

      mem_vif.fill_inc(src_base, len_bytes, seed);
      mem_vif.fill_const(dst_base, len_bytes, 8'h00);

      write_reg_okay(REG_OFF_SRC_ADDR, src);
      write_reg_okay(REG_OFF_DST_ADDR, dst);
      write_reg_okay(REG_OFF_LEN,      len);

      start_dma_irq_en();

      wait_irq_level(1'b1, 800000);

      read_reg_okay(REG_OFF_STATUS, status);
      read_reg_okay(REG_OFF_ERR_CODE, err_code);
      if (status[STATUS_ERR_BIT] !== 1'b0)
        `uvm_fatal("COPY_CHK", "Unexpected STATUS.ERR=1")
      if (err_code[7:0] !== ERR_NONE)
        `uvm_fatal("COPY_CHK", $sformatf("Expected ERR_NONE, got 0x%0h", err_code[7:0]))

      clear_irq_done();
      wait_irq_level(1'b0, 400000);

      for (i = 0; i < len_bytes; i++) begin
        mem_vif.read_byte(src_base + i, s);
        mem_vif.read_byte(dst_base + i, d);
        if (d !== s) begin
          `uvm_fatal("COPY_MISMATCH",
            $sformatf("Mismatch +0x%0h: SRC[0x%08h]=0x%02h DST[0x%08h]=0x%02h",
                      i, (src_base+i), s, (dst_base+i), d))
        end
      end

      `uvm_info("COPY", "copy_test PASSED (data moved correctly).", UVM_LOW)
      phase.drop_objection(this);
    endtask
  endclass : copy_test

  //--------------------------------------------------------------------------
  // NEGATIVE TEST 1: len_zero_test -> expect ERR_LEN_ZERO
  //--------------------------------------------------------------------------
  class len_zero_test extends base_test;
    `uvm_component_utils(len_zero_test)

    function new(string name="len_zero_test", uvm_component parent=null);
      super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
      logic [31:0] src = 32'h0000_0000;
      logic [31:0] dst = 32'h0000_0200;
      logic [31:0] len = 32'h0000_0000; // invalid

      phase.raise_objection(this);

      wait_for_reset_release();
      axil_master_idle(axil_vif);
      clear_irqs_all();

      `uvm_info("LEN0", "Starting negative test: LEN=0 (expect ERR_LEN_ZERO)", UVM_LOW)

      write_reg_okay(REG_OFF_SRC_ADDR, src);
      write_reg_okay(REG_OFF_DST_ADDR, dst);
      write_reg_okay(REG_OFF_LEN,      len);

      start_dma_irq_en();

      wait_irq_level(1'b1, 200000);

      expect_error(ERR_LEN_ZERO);

      clear_irq_err();
      wait_irq_level(1'b0, 200000);

      `uvm_info("LEN0", "len_zero_test PASSED.", UVM_LOW)
      phase.drop_objection(this);
    endtask
  endclass : len_zero_test

  //--------------------------------------------------------------------------
  // NEGATIVE TEST 2: unaligned_addr_test -> expect ERR_ALIGN
  //--------------------------------------------------------------------------
  class unaligned_addr_test extends base_test;
    `uvm_component_utils(unaligned_addr_test)

    function new(string name="unaligned_addr_test", uvm_component parent=null);
      super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
      logic [31:0] src = 32'h0000_0002; // misaligned to 4B
      logic [31:0] dst = 32'h0000_0200;
      logic [31:0] len = 32'h0000_0040; // 64B

      phase.raise_objection(this);

      wait_for_reset_release();
      axil_master_idle(axil_vif);
      clear_irqs_all();

      `uvm_info("UNAL", "Starting negative test: SRC misaligned (expect ERR_ALIGN)", UVM_LOW)

      write_reg_okay(REG_OFF_SRC_ADDR, src);
      write_reg_okay(REG_OFF_DST_ADDR, dst);
      write_reg_okay(REG_OFF_LEN,      len);

      start_dma_irq_en();

      wait_irq_level(1'b1, 200000);

      expect_error(ERR_ALIGN);

      clear_irq_err();
      wait_irq_level(1'b0, 200000);

      `uvm_info("UNAL", "unaligned_addr_test PASSED.", UVM_LOW)
      phase.drop_objection(this);
    endtask
  endclass : unaligned_addr_test

  //--------------------------------------------------------------------------
  // NEGATIVE TEST 3: out_of_range_test -> expect ERR_RANGE
  //--------------------------------------------------------------------------
  class out_of_range_test extends base_test;
    `uvm_component_utils(out_of_range_test)

    function new(string name="out_of_range_test", uvm_component parent=null);
      super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
      // Force base address out of memory immediately (avoids 4KB-cross corner)
      logic [31:0] src = MEM_SIZE_BYTES;  // 0x00010000 for 64KB memory -> out of range
      logic [31:0] dst = 32'h0000_0200;
      logic [31:0] len = 32'h0000_0040;  // 64B

      phase.raise_objection(this);

      wait_for_reset_release();
      axil_master_idle(axil_vif);
      clear_irqs_all();

      `uvm_info("RANGE", $sformatf("Starting negative test: SRC=0x%08h out-of-range (expect ERR_RANGE)", src), UVM_LOW)

      write_reg_okay(REG_OFF_SRC_ADDR, src);
      write_reg_okay(REG_OFF_DST_ADDR, dst);
      write_reg_okay(REG_OFF_LEN,      len);

      start_dma_irq_en();

      wait_irq_level(1'b1, 200000);

      expect_error(ERR_RANGE);

      clear_irq_err();
      wait_irq_level(1'b0, 200000);

      `uvm_info("RANGE", "out_of_range_test PASSED.", UVM_LOW)
      phase.drop_objection(this);
    endtask
  endclass : out_of_range_test

endpackage : tb_pkg

`endif // TB_PKG_SV
