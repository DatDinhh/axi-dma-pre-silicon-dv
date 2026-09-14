// Directed and seeded scenario tests using the reusable dma_env.
// Seeded tests use an explicit PRNG; they do not claim solver-based randomization.
`ifndef TB_PKG_SV
`define TB_PKG_SV
package tb_pkg;
  timeunit 1ns;
  timeprecision 1ps;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import dma_pkg::*;

  typedef virtual axil_if #(32,32) axil_vif_t;
  typedef virtual axi_if #(32,32,1) axi_vif_t;
  typedef virtual irq_if irq_vif_t;
  typedef virtual mem_bkdr_if mem_vif_t;
  typedef virtual clk_rst_if #(10ns,5) reset_vif_t;

  class base_test extends uvm_test;
    `uvm_component_utils(base_test)
    dma_uvm_pkg::dma_env env;
    axil_vif_t axil_vif;
    axi_vif_t axi_vif;
    irq_vif_t irq_vif;
    mem_vif_t mem_vif;
    reset_vif_t reset_vif;
    int unsigned stimulus_state = 1;

    function new(string name="base_test", uvm_component parent=null);
      super.new(name,parent);
    endfunction
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      env = dma_uvm_pkg::dma_env::type_id::create("env",this);
      if (!uvm_config_db#(axil_vif_t)::get(this,"","axil_vif",axil_vif))
        `uvm_fatal("NOVIF","Missing AXI-Lite interface")
      if (!uvm_config_db#(axi_vif_t)::get(this,"","axi_vif",axi_vif))
        `uvm_fatal("NOVIF","Missing AXI interface")
      if (!uvm_config_db#(irq_vif_t)::get(this,"","irq_vif",irq_vif))
        `uvm_fatal("NOVIF","Missing IRQ interface")
      if (!uvm_config_db#(mem_vif_t)::get(this,"","mem_vif",mem_vif))
        `uvm_fatal("NOVIF","Missing memory interface")
      if (!uvm_config_db#(reset_vif_t)::get(this,"","reset_vif",reset_vif))
        `uvm_fatal("NOVIF","Missing reset interface")
      if ($value$plusargs("TEST_SEED=%d",stimulus_state)) begin end
      if (stimulus_state==0) stimulus_state=1;
    endfunction
    function int unsigned next_value();
      stimulus_state ^= stimulus_state << 13;
      stimulus_state ^= stimulus_state >> 17;
      stimulus_state ^= stimulus_state << 5;
      return stimulus_state;
    endfunction
    virtual task scenario();
      `uvm_fatal("BASE_TEST","Select a concrete test")
    endtask
    task run_phase(uvm_phase phase);
      phase.raise_objection(this);
      wait(axil_vif.rst_n===1'b1);
      repeat(3) @(axil_vif.cb_mon);
      `uvm_info("TEST_SEED",$sformatf("stimulus seed=%0d",stimulus_state),UVM_LOW)
      scenario();
      repeat(8) @(axil_vif.cb_mon);
      // check_phase still runs after this marker; runner also requires zero errors.
      `uvm_info("TEST_PASS",$sformatf("%s PASSED",get_type_name()),UVM_LOW)
      phase.drop_objection(this);
    endtask
    task write_reg(input logic[31:0] addr,data);
      logic[1:0] resp;
      env.write32(addr,data,resp);
      if(resp!==0) `uvm_fatal("CSR_WRITE",$sformatf("addr=%h response=%b",addr,resp))
    endtask
    task read_reg(input logic[31:0] addr,output logic[31:0] data);
      logic[1:0] resp;
      env.read32(addr,data,resp);
      if(resp!==0) `uvm_fatal("CSR_READ",$sformatf("addr=%h response=%b",addr,resp))
    endtask
    task expect_reg(input logic[31:0] addr,expected);
      logic[31:0] data;
      read_reg(addr,data);
      if(data!==expected)
        `uvm_fatal("CSR_VALUE",$sformatf("addr=%h expected=%h actual=%h",addr,expected,data))
    endtask
    task program_dma(input logic[31:0] src,dst,len);
      write_reg(REG_OFF_SRC_ADDR,src);
      write_reg(REG_OFF_DST_ADDR,dst);
      write_reg(REG_OFF_LEN,len);
    endtask
    task start_dma(input bit irq_enable=1);
      write_reg(REG_OFF_CTRL,irq_enable ? 3 : 1);
    endtask
    task wait_irq(input bit level);
      for(int i=0;i<60000;i++) begin
        @(axil_vif.cb_mon);
        if(irq_vif.irq===level) return;
      end
      `uvm_fatal("IRQ_TIMEOUT",$sformatf("irq did not reach %b",level))
    endtask
    task wait_terminal(output logic[31:0] status);
      for(int i=0;i<10000;i++) begin
        read_reg(REG_OFF_STATUS,status);
        if(!status[0] && (status[1] || status[2])) return;
      end
      `uvm_fatal("DMA_TIMEOUT","No terminal status under bounded responder")
    endtask
    task finish_success(input bit irq_enable=1,input bit clear_event=1);
      logic[31:0] status;
      wait_terminal(status);
      if(status[2:0]!==3'b010)
        `uvm_fatal("DMA_STATUS",$sformatf("Expected DONE only, actual=%h",status))
      expect_reg(REG_OFF_ERR_CODE,0);
      expect_reg(REG_OFF_BYTES_REMAIN,0);
      expect_reg(REG_OFF_IRQ_STATUS,1);
      if(irq_enable) wait_irq(1);
      else if(irq_vif.irq!==0) `uvm_fatal("IRQ_MASK","Masked IRQ asserted")
      if(clear_event) begin
        write_reg(REG_OFF_IRQ_STATUS,1);
        wait_irq(0);
        expect_reg(REG_OFF_STATUS,0);
      end
    endtask
    task prepare_memory(input int unsigned src,dst,len,input byte unsigned seed=8'h3c);
      mem_vif.fill_inc(src,len,seed);
      mem_vif.fill_const(dst,len,8'ha5);
      // Guard bytes are captured independently by the scoreboard before START.
      if(dst>=4) mem_vif.fill_const(dst-4,4,8'hd3);
      if(dst+len+4<=65536) mem_vif.fill_const(dst+len,4,8'h7e);
    endtask
    task run_copy(input int unsigned src,dst,len,input byte unsigned seed=8'h3c,
                  input bit irq_enable=1);
      `uvm_info("COPY_CASE",$sformatf("src=%08h dst=%08h len=%0d irq=%0b pattern=%02h",src,dst,len,irq_enable,seed),UVM_LOW)
      prepare_memory(src,dst,len,seed);
      program_dma(src,dst,len);
      start_dma(irq_enable);
      finish_success(irq_enable);
    endtask
    task expect_error(input int unsigned error_code,input bit allow_done=0);
      logic[31:0] status;
      wait_terminal(status);
      if(status[0] || !status[2] || (!allow_done && status[1]))
        `uvm_fatal("DMA_ERROR_STATUS",$sformatf("actual=%h",status))
      expect_reg(REG_OFF_ERR_CODE,error_code);
      expect_reg(REG_OFF_IRQ_STATUS,allow_done ? 3 : 2);
      wait_irq(1);
    endtask
    task bad_descriptor(input logic[31:0] src,dst,len,input int unsigned error_code);
      write_reg(REG_OFF_IRQ_STATUS,3);
      program_dma(src,dst,len);
      start_dma();
      expect_error(error_code);
      write_reg(REG_OFF_IRQ_STATUS,2);
      wait_irq(0);
      // W1C preserves the last error; CTRL.CLR_ERR clears it.
      expect_reg(REG_OFF_ERR_CODE,error_code);
      write_reg(REG_OFF_CTRL,10);
      expect_reg(REG_OFF_ERR_CODE,0);
    endtask
  endclass

  class smoke_test extends base_test;
    `uvm_component_utils(smoke_test)
    function new(string name="smoke_test",uvm_component parent=null); super.new(name,parent); endfunction
    task scenario(); run_copy('h100,'h8000,64); endtask
  endclass
  class copy_test extends base_test;
    `uvm_component_utils(copy_test)
    function new(string name="copy_test",uvm_component parent=null); super.new(name,parent); endfunction
    task scenario(); run_copy('h100,'h8000,128); endtask
  endclass
  class len_zero_test extends base_test;
    `uvm_component_utils(len_zero_test)
    function new(string name="len_zero_test",uvm_component parent=null); super.new(name,parent); endfunction
    task scenario(); bad_descriptor('h100,'h8000,0,1); endtask
  endclass
  class unaligned_addr_test extends base_test;
    `uvm_component_utils(unaligned_addr_test)
    function new(string name="unaligned_addr_test",uvm_component parent=null); super.new(name,parent); endfunction
    task scenario(); bad_descriptor('h102,'h8000,64,2); endtask
  endclass
  class out_of_range_test extends base_test;
    `uvm_component_utils(out_of_range_test)
    function new(string name="out_of_range_test",uvm_component parent=null); super.new(name,parent); endfunction
    task scenario(); bad_descriptor('h10000,'h8000,64,3); endtask
  endclass

  class csr_access_test extends base_test;
    `uvm_component_utils(csr_access_test)
    function new(string name="csr_access_test",uvm_component parent=null); super.new(name,parent); endfunction
    task scenario();
      logic[1:0] resp;
      logic[31:0] data;
      for(int i=0;i<8;i++) expect_reg(i*4,0);
      // AW before W, W before AW, same-cycle; stall B/R consumption.
      for(int i=0;i<3;i++) begin
        env.write32(REG_OFF_SRC_ADDR,'h100+i*4,resp,4'hf,
                    i==1 ? 4 : 0,i==0 ? 4 : 0,5);
        if(resp!==0) `uvm_fatal("CSR_ORDER","Write failed")
        env.read32(REG_OFF_SRC_ADDR,data,resp,5);
        if(resp!==0 || data!==('h100+i*4)) `uvm_fatal("CSR_ORDER","Readback mismatch")
      end
      env.write32(REG_OFF_SRC_ADDR,'hdeadbeef,resp,4'h3);
      if(resp!==2) `uvm_fatal("CSR_STROBE","Partial strobe must fail")
      env.write32(REG_OFF_SRC_ADDR,0,resp,4'h0);
      if(resp!==2) `uvm_fatal("CSR_STROBE","Zero strobe must fail")
      expect_reg(REG_OFF_SRC_ADDR,'h108);
      env.write32('h20,0,resp);
      if(resp!==2) `uvm_fatal("CSR_BAD_ADDR","Unknown write must fail")
      env.write32('h2,0,resp);
      if(resp!==2) `uvm_fatal("CSR_BAD_ADDR","Unaligned write must fail")
      env.read32('h20,data,resp);
      if(resp!==2 || data!==0) `uvm_fatal("CSR_BAD_ADDR","Unknown read must fail and return zero")
      env.read32('h2,data,resp);
      if(resp!==2 || data!==0) `uvm_fatal("CSR_BAD_ADDR","Unaligned read must fail and return zero")
      write_reg(REG_OFF_STATUS,'hffffffff);
      expect_reg(REG_OFF_STATUS,0);
      write_reg(REG_OFF_ERR_CODE,'hffffffff);
      expect_reg(REG_OFF_ERR_CODE,0);
      write_reg(REG_OFF_CTRL,2);
      expect_reg(REG_OFF_CTRL,2);
      write_reg(REG_OFF_CTRL,0);
      expect_reg(REG_OFF_CTRL,0);
    endtask
  endclass

  class descriptor_corner_test extends base_test;
    `uvm_component_utils(descriptor_corner_test)
    function new(string name="descriptor_corner_test",uvm_component parent=null); super.new(name,parent); endfunction
    task scenario();
      bad_descriptor('h100,'h8001,16,2);
      bad_descriptor('h100,'h8000,1,2);
      bad_descriptor('h100,'h8000,3,2);
      bad_descriptor('h100,'h8000,6,2);
      bad_descriptor('hfffc,'h8000,8,3);
      bad_descriptor('h100,'hfffc,8,3);
      bad_descriptor('hfffffffc,'h8000,8,3);
      bad_descriptor('h100,'h8000,'hfffffffc,3);
      run_copy('h100,'h8000,4);
      run_copy('h100,'h8000,16);
      run_copy('hfffc,'h8000,4);
      run_copy('h100,'hfffc,4);
      run_copy('hffc,'h8ffc,32); // descriptor crosses page; each beat is legal
    endtask
  endclass

  class irq_test extends base_test;
    `uvm_component_utils(irq_test)
    function new(string name="irq_test",uvm_component parent=null); super.new(name,parent); endfunction
    task scenario();
      prepare_memory('h100,'h8000,16);
      program_dma('h100,'h8000,16);
      start_dma(0);
      finish_success(0,0);
      write_reg(REG_OFF_CTRL,2);
      wait_irq(1);
      // Invalid next command preserves old DONE while adding ERR.
      program_dma('h100,'h8000,0);
      start_dma(1);
      expect_error(1,1);
      write_reg(REG_OFF_IRQ_STATUS,1);
      expect_reg(REG_OFF_IRQ_STATUS,2);
      wait_irq(1);
      write_reg(REG_OFF_CTRL,0);
      wait_irq(0);
      expect_reg(REG_OFF_IRQ_STATUS,2);
      write_reg(REG_OFF_CTRL,2);
      wait_irq(1);
      write_reg(REG_OFF_IRQ_STATUS,2);
      wait_irq(0);
      expect_reg(REG_OFF_ERR_CODE,1);
      write_reg(REG_OFF_CTRL,10);
      expect_reg(REG_OFF_ERR_CODE,0);
      run_copy('h100,'h8000,4);
    endtask
  endclass

  class busy_start_test extends base_test;
    `uvm_component_utils(busy_start_test)
    function new(string name="busy_start_test",uvm_component parent=null); super.new(name,parent); endfunction
    task scenario();
      logic[31:0] status;
      prepare_memory('h100,'h8000,512);
      prepare_memory('h3000,'ha000,16,8'h67);
      program_dma('h100,'h8000,512);
      start_dma();
      read_reg(REG_OFF_STATUS,status);
      if(!status[0]) `uvm_fatal("BUSY_SETUP","Expected transfer active")
      program_dma('h3000,'ha000,16);
      start_dma(); // must not affect active descriptor
      finish_success();
      start_dma(); // new descriptor becomes effective only now
      finish_success();
    endtask
  endclass

  class reset_mid_transfer_test extends base_test;
    `uvm_component_utils(reset_mid_transfer_test)
    function new(string name="reset_mid_transfer_test",uvm_component parent=null); super.new(name,parent); endfunction
    task scenario();
      bit reached;
      for(int channel=0;channel<5;channel++) begin
        prepare_memory('h100,'h8000,256,8'h23+channel);
        program_dma('h100,'h8000,256);
        start_dma();
        reached=0;
        // Observe at negedge so shared reset is asserted away from sampling edge.
        for(int cycle=0;cycle<10000;cycle++) begin
          @(negedge axil_vif.clk);
          case(channel)
            0: reached=axi_vif.arvalid;
            1: reached=axi_vif.rready;
            2: reached=axi_vif.awvalid;
            3: reached=axi_vif.wvalid;
            4: reached=axi_vif.bready;
          endcase
          if(reached) break;
        end
        if(!reached) `uvm_fatal("RESET_SETUP",$sformatf("Channel %0d not reached",channel))
        reset_vif.apply_reset(5,1); // already at negedge: cancel the selected phase now
        repeat(3) @(axil_vif.cb_mon);
        for(int i=0;i<8;i++) expect_reg(i*4,0);
        wait_irq(0);
        run_copy('h3000,'ha000,16,8'h92);
      end
    endtask
  endclass

  class seeded_copy_test extends base_test;
    `uvm_component_utils(seeded_copy_test)
    function new(string name="seeded_copy_test",uvm_component parent=null); super.new(name,parent); endfunction
    task scenario();
      int unsigned src,dst,len,count;
      byte unsigned pattern;
      count=32;
      if($value$plusargs("TRANSFER_COUNT=%d",count)) begin end
      if(count==0 || count>10000) `uvm_fatal("COUNT","TRANSFER_COUNT must be 1..10000")
      for(int i=0;i<count;i++) begin
        len=4*(1+(next_value()%128));
        src=4*(next_value()%3500);
        dst='h8000+4*(next_value()%3500);
        pattern=byte'(next_value());
        run_copy(src,dst,len,pattern,next_value()%2);
      end
    endtask
  endclass

  class read_error_test extends base_test;
    `uvm_component_utils(read_error_test)
    function new(string name="read_error_test",uvm_component parent=null); super.new(name,parent); endfunction
    task scenario();
      int unsigned fault_addr;
      if(!$value$plusargs("AXI_RERR_ADDR=%h",fault_addr) || fault_addr!='h100)
        `uvm_fatal("FAULT_CONFIG","Run with +AXI_RERR_ADDR=100")
      for(int position=0;position<3;position++) begin
        int unsigned offset;
        offset=(position==0) ? 0 : ((position==1) ? 28 : 60);
        `uvm_info("FAULT_CASE",$sformatf("READ error position=%0d byte_offset=%0d",position,offset),UVM_LOW)
        prepare_memory(fault_addr-offset,'h8000,64);
        program_dma(fault_addr-offset,'h8000,64);
        start_dma();
        expect_error(5);
        write_reg(REG_OFF_IRQ_STATUS,2);
        run_copy('h200,'h9000,16);
      end
    endtask
  endclass
  class write_error_test extends base_test;
    `uvm_component_utils(write_error_test)
    function new(string name="write_error_test",uvm_component parent=null); super.new(name,parent); endfunction
    task scenario();
      int unsigned fault_addr;
      if(!$value$plusargs("AXI_BERR_ADDR=%h",fault_addr) || fault_addr!='h8000)
        `uvm_fatal("FAULT_CONFIG","Run with +AXI_BERR_ADDR=8000")
      for(int position=0;position<3;position++) begin
        int unsigned offset;
        offset=(position==0) ? 0 : ((position==1) ? 28 : 60);
        `uvm_info("FAULT_CASE",$sformatf("WRITE error position=%0d byte_offset=%0d",position,offset),UVM_LOW)
        prepare_memory('h100,fault_addr-offset,64);
        program_dma('h100,fault_addr-offset,64);
        start_dma();
        expect_error(6);
        write_reg(REG_OFF_IRQ_STATUS,2);
        run_copy('h200,'h9000,16);
      end
    endtask
  endclass

  // Deliberately corrupt a guard byte to prove the independent checker detects it.
  // Expected-failure test: run separately; SB_MEMORY and nonzero regression exit
  // are the successful outcome of this checker self-test.
  class scoreboard_negative_test extends base_test;
    `uvm_component_utils(scoreboard_negative_test)
    function new(string name="scoreboard_negative_test",uvm_component parent=null); super.new(name,parent); endfunction
    task scenario();
      prepare_memory('h100,'h8000,128);
      program_dma('h100,'h8000,128);
      start_dma();
      mem_vif.write_byte('h7ffc,8'h00);
      finish_success();
    endtask
  endclass

endpackage
`endif
