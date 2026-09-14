// Reusable AXI-Lite agent, passive AXI monitor, and independent DMA checking.
// Baseline: 32-bit aligned single-beat DMA; one outstanding read/write.
package dma_uvm_pkg;
  timeunit 1ns; timeprecision 1ps;
  import uvm_pkg::*;
  import dma_pkg::*;
  import dma_cov_pkg::*;
  `include "uvm_macros.svh"
  typedef virtual axil_if #(32,32) dma_axil_vif_t;
  typedef virtual axi_if #(32,32,1) dma_axi_vif_t;
  typedef virtual mem_bkdr_if dma_mem_vif_t;
  typedef virtual irq_if dma_irq_vif_t;

  typedef enum {CSR_WRITE, CSR_B, CSR_AR, CSR_R, BUS_AW, BUS_W, BUS_B,
                BUS_AR, BUS_R, BUS_RESET, TRANSFER_START, TRANSFER_END,
                START_WHILE_BUSY, RESET_ABORT, BUS_STALL, AXIL_STALL, AW_WAIT_W, RESET_PHASE} dma_event_kind;
  class dma_bus_event extends uvm_sequence_item;
    `uvm_object_utils(dma_bus_event)
    dma_event_kind kind;
    logic [31:0] addr, data, src, dst, len;
    logic [3:0] strb;
    logic [1:0] resp, burst;
    logic [7:0] beats;
    logic [2:0] size;
    logic last, id, irq_sample;
    bit irq_enable;
    int unsigned code, channel, write_order;
    longint unsigned observed_cycle;
    function new(string name="dma_bus_event"); super.new(name); endfunction
  endclass

  class dma_axil_item extends uvm_sequence_item;
    `uvm_object_utils(dma_axil_item)
    bit is_write;
    logic [31:0] addr, data;
    logic [3:0] strb=4'hf;
    logic [1:0] resp;
    int unsigned aw_delay, w_delay, resp_delay;
    int unsigned timeout_cycles=2000;
    bit aborted;
    function new(string name="dma_axil_item"); super.new(name); endfunction
  endclass
  class dma_axil_sequence extends uvm_sequence #(dma_axil_item);
    `uvm_object_utils(dma_axil_sequence)
    dma_axil_item item;
    function new(string name="dma_axil_sequence"); super.new(name); endfunction
    task body(); start_item(item); finish_item(item); endtask
  endclass
  class dma_axil_sequencer extends uvm_sequencer #(dma_axil_item);
    `uvm_component_utils(dma_axil_sequencer)
    function new(string name, uvm_component parent); super.new(name,parent); endfunction
  endclass

  class dma_axil_driver extends uvm_driver #(dma_axil_item);
    `uvm_component_utils(dma_axil_driver)
    dma_axil_vif_t vif;
    function new(string name, uvm_component parent); super.new(name,parent); endfunction
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(dma_axil_vif_t)::get(this,"","axil_vif",vif))
        `uvm_fatal("NOVIF","AXI-Lite driver requires axil_vif")
    endfunction
    task idle();
      vif.cb_master.awaddr<=0; vif.cb_master.awprot<=0; vif.cb_master.awvalid<=0;
      vif.cb_master.wdata<=0; vif.cb_master.wstrb<=0; vif.cb_master.wvalid<=0;
      vif.cb_master.bready<=0; vif.cb_master.araddr<=0; vif.cb_master.arprot<=0;
      vif.cb_master.arvalid<=0; vif.cb_master.rready<=0;
    endtask
    task drive(dma_axil_item tr);
      bit aw_on,w_on,ar_on,b_on,r_on,aw_done,w_done,ar_done;
      int unsigned response_wait;
      aw_on=0; w_on=0; ar_on=0; b_on=0; r_on=0;
      aw_done=0; w_done=0; ar_done=0; response_wait=0;
      tr.aborted=0;
      @(vif.cb_master);
      for (int unsigned cycle=0; cycle<tr.timeout_cycles; cycle++) begin
        if (vif.rst_n !== 1'b1) begin tr.aborted=1; tr.resp=2'b10; idle(); return; end
        if (tr.is_write) begin
          if (aw_on && vif.cb_master.awready) begin aw_on=0; aw_done=1; vif.cb_master.awvalid<=0; end
          if (w_on && vif.cb_master.wready) begin w_on=0; w_done=1; vif.cb_master.wvalid<=0; end
          if (b_on && vif.cb_master.bvalid) begin
            tr.resp=vif.cb_master.bresp; vif.cb_master.bready<=0; return;
          end
          if (!aw_on && !aw_done && cycle>=tr.aw_delay) begin
            vif.cb_master.awaddr<=tr.addr; vif.cb_master.awprot<=0; vif.cb_master.awvalid<=1; aw_on=1;
          end
          if (!w_on && !w_done && cycle>=tr.w_delay) begin
            vif.cb_master.wdata<=tr.data; vif.cb_master.wstrb<=tr.strb; vif.cb_master.wvalid<=1; w_on=1;
          end
          if (aw_done && w_done && !b_on) begin
            if (response_wait>=tr.resp_delay) begin vif.cb_master.bready<=1; b_on=1; end
            else response_wait++;
          end
        end else begin
          if (ar_on && vif.cb_master.arready) begin ar_on=0; ar_done=1; vif.cb_master.arvalid<=0; end
          if (r_on && vif.cb_master.rvalid) begin
            tr.data=vif.cb_master.rdata; tr.resp=vif.cb_master.rresp; vif.cb_master.rready<=0; return;
          end
          if (!ar_on && !ar_done) begin
            vif.cb_master.araddr<=tr.addr; vif.cb_master.arprot<=0; vif.cb_master.arvalid<=1; ar_on=1;
          end
          if (ar_done && !r_on) begin
            if (response_wait>=tr.resp_delay) begin vif.cb_master.rready<=1; r_on=1; end
            else response_wait++;
          end
        end
        @(vif.cb_master);
      end
      idle();
      `uvm_fatal("AXIL_TIMEOUT",$sformatf("%s addr=%08h timed out after %0d cycles",tr.is_write?"WRITE":"READ",tr.addr,tr.timeout_cycles))
    endtask
    task run_phase(uvm_phase phase);
      idle();
      forever begin
        seq_item_port.get_next_item(req);
        wait(vif.rst_n===1'b1);
        drive(req);
        seq_item_port.item_done();
      end
    endtask
  endclass

  class dma_axil_monitor extends uvm_monitor;
    `uvm_component_utils(dma_axil_monitor)
    dma_axil_vif_t vif; dma_irq_vif_t irq_vif;
    uvm_analysis_port #(dma_bus_event) ap;
    dma_bus_event awq[$],wq[$],bq[$],rq[$];
    longint unsigned observed_cycle;
    function new(string name,uvm_component parent); super.new(name,parent); ap=new("ap",this); endfunction
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(dma_axil_vif_t)::get(this,"","axil_vif",vif)) `uvm_fatal("NOVIF","axil_vif missing")
      if (!uvm_config_db#(dma_irq_vif_t)::get(this,"","irq_vif",irq_vif)) `uvm_fatal("NOVIF","irq_vif missing")
    endfunction
    task run_phase(uvm_phase phase);
      dma_bus_event t,a,w; bit was_reset=0;
      forever begin
        @(vif.cb_mon);
        observed_cycle++;
        if (vif.rst_n !== 1'b1) begin
          awq.delete(); wq.delete(); bq.delete(); rq.delete();
          if (!was_reset) begin t=new(); t.kind=BUS_RESET; ap.write(t); end
          was_reset=1;
        end else begin
          was_reset=0;
          if (vif.cb_mon.awvalid && vif.cb_mon.awready) begin t=new(); t.addr=vif.cb_mon.awaddr; t.observed_cycle=observed_cycle; awq.push_back(t); end
          if (vif.cb_mon.wvalid && vif.cb_mon.wready) begin t=new(); t.data=vif.cb_mon.wdata; t.strb=vif.cb_mon.wstrb; t.observed_cycle=observed_cycle; wq.push_back(t); end
          if (awq.size()!=0 && wq.size()!=0) begin
            a=awq.pop_front(); w=wq.pop_front(); t=new(); t.kind=CSR_WRITE;
            t.addr=a.addr; t.data=w.data; t.strb=w.strb;
            t.write_order=(a.observed_cycle < w.observed_cycle) ? 0 :
                          ((w.observed_cycle < a.observed_cycle) ? 1 : 2);
            bq.push_back(t); ap.write(t); // Commit is observable before BREADY.
          end
          if (vif.cb_mon.bvalid && vif.cb_mon.bready) begin
            if (bq.size()==0) `uvm_error("AXIL_ORPHAN_B","B without paired AW/W")
            else begin a=bq.pop_front(); t=new(); t.kind=CSR_B; t.addr=a.addr; t.data=a.data; t.strb=a.strb; t.write_order=a.write_order; t.resp=vif.cb_mon.bresp; ap.write(t); end
          end
          for (int i=0;i<5;i++) begin
            bit stalled;
            case(i)
              0: stalled=vif.cb_mon.arvalid && !vif.cb_mon.arready;
              1: stalled=vif.cb_mon.rvalid && !vif.cb_mon.rready;
              2: stalled=vif.cb_mon.awvalid && !vif.cb_mon.awready;
              3: stalled=vif.cb_mon.wvalid && !vif.cb_mon.wready;
              4: stalled=vif.cb_mon.bvalid && !vif.cb_mon.bready;
            endcase
            if(stalled) begin t=new(); t.kind=AXIL_STALL; t.channel=i; ap.write(t); end
          end
          if (vif.cb_mon.arvalid && vif.cb_mon.arready) begin
            t=new(); t.kind=CSR_AR; t.addr=vif.cb_mon.araddr; t.irq_sample=irq_vif.cb_mon.irq;
            rq.push_back(t); ap.write(t);
          end
          if (vif.cb_mon.rvalid && vif.cb_mon.rready) begin
            if (rq.size()==0) `uvm_error("AXIL_ORPHAN_R","R without AR")
            else begin
              a=rq.pop_front(); t=new(); t.kind=CSR_R; t.addr=a.addr; t.data=vif.cb_mon.rdata;
              t.irq_sample=a.irq_sample; t.resp=vif.cb_mon.rresp; ap.write(t);
            end
          end
        end
      end
    endtask
    function void check_phase(uvm_phase phase);
      super.check_phase(phase);
      if (awq.size()+wq.size()+bq.size()+rq.size()!=0) `uvm_error("AXIL_PENDING","Unfinished AXI-Lite transaction at test end")
    endfunction
  endclass

  class dma_axil_agent extends uvm_agent;
    `uvm_component_utils(dma_axil_agent)
    dma_axil_sequencer sequencer; dma_axil_driver driver; dma_axil_monitor monitor;
    function new(string name,uvm_component parent); super.new(name,parent); endfunction
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      monitor=dma_axil_monitor::type_id::create("monitor",this);
      if (get_is_active()==UVM_ACTIVE) begin
        sequencer=dma_axil_sequencer::type_id::create("sequencer",this);
        driver=dma_axil_driver::type_id::create("driver",this);
      end
    endfunction
    function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);
      if (get_is_active()==UVM_ACTIVE) driver.seq_item_port.connect(sequencer.seq_item_export);
    endfunction
  endclass

  class dma_axi_monitor extends uvm_monitor;
    `uvm_component_utils(dma_axi_monitor)
    dma_axi_vif_t vif;
    uvm_analysis_port #(dma_bus_event) ap;
    function new(string name,uvm_component parent); super.new(name,parent); ap=new("ap",this); endfunction
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(dma_axi_vif_t)::get(this,"","axi_vif",vif)) `uvm_fatal("NOVIF","axi_vif missing")
    endfunction
    task run_phase(uvm_phase phase);
      fork
        observe_bus();
        observe_reset();
      join
    endtask
    task observe_reset();
      dma_bus_event t;
      forever begin
        @(negedge vif.rst_n);
        // Shared synchronous reset: capture actual master phase signals before
        // the next rising clock clears them. No test-intent labels are used.
        for (int i=0;i<5;i++) begin
          bit pending_phase;
          case(i)
            0: pending_phase=(vif.arvalid===1'b1);
            1: pending_phase=(vif.rready===1'b1);
            2: pending_phase=(vif.awvalid===1'b1);
            3: pending_phase=(vif.wvalid===1'b1);
            4: pending_phase=(vif.bready===1'b1);
          endcase
          if(pending_phase) begin t=new(); t.kind=RESET_PHASE; t.channel=i; ap.write(t); end
        end
      end
    endtask
    task observe_bus();
      dma_bus_event t;
      forever begin
        @(vif.cb_mon);
        if (vif.rst_n===1'b1) begin
          if (vif.cb_mon.arvalid && vif.cb_mon.arready) begin
            t=new(); t.kind=BUS_AR; t.addr=vif.cb_mon.araddr; t.beats=vif.cb_mon.arlen;
            t.size=vif.cb_mon.arsize; t.burst=vif.cb_mon.arburst; t.id=vif.cb_mon.arid; ap.write(t);
          end
          if (vif.cb_mon.rvalid && vif.cb_mon.rready) begin
            t=new(); t.kind=BUS_R; t.data=vif.cb_mon.rdata; t.resp=vif.cb_mon.rresp;
            t.last=vif.cb_mon.rlast; t.id=vif.cb_mon.rid; ap.write(t);
          end
          if (vif.cb_mon.awvalid && vif.cb_mon.awready) begin
            t=new(); t.kind=BUS_AW; t.addr=vif.cb_mon.awaddr; t.beats=vif.cb_mon.awlen;
            t.size=vif.cb_mon.awsize; t.burst=vif.cb_mon.awburst; t.id=vif.cb_mon.awid; ap.write(t);
          end
          if (vif.cb_mon.wvalid && vif.cb_mon.wready) begin
            t=new(); t.kind=BUS_W; t.data=vif.cb_mon.wdata; t.strb=vif.cb_mon.wstrb; t.last=vif.cb_mon.wlast; ap.write(t);
          end
          if (vif.cb_mon.bvalid && vif.cb_mon.bready) begin
            t=new(); t.kind=BUS_B; t.resp=vif.cb_mon.bresp; t.id=vif.cb_mon.bid; ap.write(t);
          end
          for (int i=0;i<5;i++) begin
            bit stalled;
            case(i)
              0: stalled=vif.cb_mon.arvalid && !vif.cb_mon.arready;
              1: stalled=vif.cb_mon.rvalid && !vif.cb_mon.rready;
              2: stalled=vif.cb_mon.awvalid && !vif.cb_mon.awready;
              3: stalled=vif.cb_mon.wvalid && !vif.cb_mon.wready;
              4: stalled=vif.cb_mon.bvalid && !vif.cb_mon.bready;
            endcase
            if(stalled) begin t=new(); t.kind=BUS_STALL; t.channel=i; ap.write(t); end
          end
          if(vif.cb_mon.wvalid && vif.cb_mon.awvalid && !vif.cb_mon.awready) begin
            t=new(); t.kind=AW_WAIT_W; ap.write(t);
          end
        end
      end
    endtask
  endclass

  class dma_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(dma_scoreboard)
    uvm_analysis_imp #(dma_bus_event,dma_scoreboard) analysis_export;
    uvm_analysis_port #(dma_bus_event) ap;
    dma_mem_vif_t mem_vif;
    logic [31:0] cfg_src,cfg_dst,cfg_len;
    bit cfg_irq,active,descriptor_valid;
    logic [31:0] transfer_src,transfer_dst,transfer_len;
    int unsigned expected_error,last_error;
    int unsigned reads,writes,read_responses,write_responses;
    int unsigned starts,completed,aborted,busy_starts,checked_bytes;
    byte unsigned initial_mem[65536], expected_mem[65536];
    dma_bus_event arq[$],awq[$],wq[$],bq[$];
    logic [31:0] csr_read_expected[$];
    logic [31:0] csr_read_masks[$];
    bit csr_read_irq_en[$];
    function new(string name,uvm_component parent);
      super.new(name,parent); analysis_export=new("analysis_export",this); ap=new("ap",this);
    endfunction
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(dma_mem_vif_t)::get(this,"","mem_vif",mem_vif)) `uvm_fatal("NOVIF","scoreboard requires mem_vif")
    endfunction
    // Independent oracle: deliberately does not call RTL validation helpers.
    function int unsigned validate_descriptor(logic [31:0] src,dst,len);
      longint unsigned src_end,dst_end;
      src_end={1'b0,src}+{1'b0,len}; dst_end={1'b0,dst}+{1'b0,len};
      if (len==0) return 1;
      if ((src%4)!=0 || (dst%4)!=0 || (len%4)!=0) return 2;
      if (src_end>65536 || dst_end>65536) return 3;
      return 0;
    endfunction
    function bit valid_csr(logic [31:0] addr);
      return !$isunknown(addr) && addr<=32'h1c && addr[1:0]==0;
    endfunction
    function void reset_model();
      dma_bus_event t;
      if(active) begin
        check_memory(); // Shared reset must preserve every committed byte.
        aborted++; t=new(); t.kind=RESET_ABORT; ap.write(t);
      end
      active=0; descriptor_valid=0; cfg_src=0; cfg_dst=0; cfg_len=0; cfg_irq=0;
      expected_error=0; last_error=0; reads=0; writes=0; read_responses=0; write_responses=0;
      arq.delete(); awq.delete(); wq.delete(); bq.delete();
      csr_read_expected.delete(); csr_read_masks.delete(); csr_read_irq_en.delete();
    endfunction
    function void begin_transfer();
      dma_bus_event t;
      if(active) begin
        busy_starts++; t=new(); t.kind=START_WHILE_BUSY; ap.write(t); return;
      end
      starts++; active=1; reads=0; writes=0; read_responses=0; write_responses=0;
      transfer_src=cfg_src; transfer_dst=cfg_dst; transfer_len=cfg_len;
      expected_error=validate_descriptor(cfg_src,cfg_dst,cfg_len);
      last_error=expected_error; descriptor_valid=(expected_error==0);
      if (descriptor_valid && cfg_src < (cfg_dst+cfg_len) && cfg_dst < (cfg_src+cfg_len))
        `uvm_fatal("SB_SCOPE","This baseline specifies disjoint source/destination ranges; overlapping descriptors are outside the verification contract")
      for(int i=0;i<65536;i++) begin initial_mem[i]=mem_vif.mem[i]; expected_mem[i]=mem_vif.mem[i]; end
      t=new(); t.kind=TRANSFER_START; t.src=cfg_src; t.dst=cfg_dst; t.len=cfg_len;
      t.irq_enable=cfg_irq; t.code=expected_error; ap.write(t);
    endfunction
    function void finish_transfer(logic [31:0] status);
      dma_bus_event t;
      if(!active) return;
      if(status[0]!==1'b0) `uvm_error("SB_STATUS","Terminal status still has BUSY set")
      if(expected_error==0) begin
        if(status[2:1]!==2'b01) `uvm_error("SB_STATUS",$sformatf("Expected DONE without ERR, observed %08h",status))
        if(reads!=transfer_len/4 || writes!=transfer_len/4 || read_responses!=reads || write_responses!=writes)
          `uvm_error("SB_COUNTS",$sformatf("LEN=%0d AR/R/AW+W/B=%0d/%0d/%0d/%0d",transfer_len,reads,read_responses,writes,write_responses))
      end else begin
        if(status[2]!==1'b1) `uvm_error("SB_STATUS","Expected ERR status")
        if(descriptor_valid && status[1]!==1'b0) `uvm_error("SB_FALSE_DONE","A bus-faulted transfer must not set DONE")
        if(!descriptor_valid && (reads!=0 || writes!=0)) `uvm_error("SB_REJECT","Invalid descriptor generated memory traffic")
      end
      if(arq.size()+awq.size()+wq.size()+bq.size()!=0) `uvm_error("SB_EARLY_END","DMA completed with outstanding AXI transactions")
      check_memory();
      active=0; completed++; t=new(); t.kind=TRANSFER_END; t.code=expected_error; ap.write(t);
    endfunction
    function void check_memory();
      int mismatch_count;
      mismatch_count=0;
      for(int i=0;i<65536;i++) begin
        if(mem_vif.mem[i] !== expected_mem[i]) begin
          if(mismatch_count<8) `uvm_error("SB_MEMORY",$sformatf("Memory[%08h] expected=%02h observed=%02h",i,expected_mem[i],mem_vif.mem[i]))
          mismatch_count++;
        end
      end
      checked_bytes+=65536;
      if(mismatch_count>8) `uvm_error("SB_MEMORY",$sformatf("%0d additional memory mismatches suppressed",mismatch_count-8))
    endfunction
    function void check_address(dma_bus_event t,bit is_write);
      logic [31:0] expected_addr;
      expected_addr=is_write ? transfer_dst+4*writes : transfer_src+4*reads;
      if(!active || !descriptor_valid || expected_error!=0)
        `uvm_error("SB_UNEXPECTED_AXI",$sformatf("Unexpected %s address %08h with active=%0d error=%0d",is_write?"AW":"AR",t.addr,active,expected_error))
      if(t.addr !== expected_addr) `uvm_error("SB_ADDRESS",$sformatf("%s expected=%08h observed=%08h",is_write?"AW":"AR",expected_addr,t.addr))
      if(t.beats!==0 || t.size!==3'd2 || t.burst!==2'b01 || t.id!==0)
        `uvm_error("SB_AXI_SHAPE","Expected single-beat 32-bit INCR access with ID zero")
    endfunction
    function void pair_write();
      dma_bus_event a,w; logic [31:0] expected_data; int unsigned offset;
      if(awq.size()==0 || wq.size()==0) return;
      a=awq.pop_front(); w=wq.pop_front();
      offset=4*writes;
      if(!active || !descriptor_valid || offset>=transfer_len) begin
        `uvm_error("SB_EXTRA_WRITE","Unexpected write beyond accepted descriptor")
      end else begin
        expected_data={initial_mem[transfer_src+offset+3],initial_mem[transfer_src+offset+2],initial_mem[transfer_src+offset+1],initial_mem[transfer_src+offset]};
        if(w.data!==expected_data || w.strb!==4'hf || w.last!==1'b1)
          `uvm_error("SB_WRITE_DATA",$sformatf("Write offset=%0d expected data=%08h strb=f last=1, observed=%08h/%h/%b",offset,expected_data,w.data,w.strb,w.last))
        // A failing BRESP does not imply a rollback of memory side effects.
        // This responder commits a W beat even when reporting a write error.
        for(int lane=0;lane<4;lane++) expected_mem[transfer_dst+offset+lane]=initial_mem[transfer_src+offset+lane];
      end
      writes++; bq.push_back(a);
    endfunction
    function void write(dma_bus_event tr);
      dma_bus_event a; logic [31:0] expected_data,mask,status;
      logic [1:0] expected_resp; bit sampled_irq_enable;
      int unsigned offset;
      case(tr.kind)
        BUS_RESET: reset_model();
        CSR_WRITE: begin
          if(valid_csr(tr.addr) && tr.strb===4'hf) begin
            case(tr.addr)
              32'h00: begin
                cfg_irq=tr.data[1];
                if(tr.data[3]) last_error=0;
                if(tr.data[0]) begin_transfer();
              end
              32'h04: cfg_src=tr.data;
              32'h08: cfg_dst=tr.data;
              32'h0c: cfg_len=tr.data;
              default: ; // Read-only writes and RW1C do not change descriptor.
            endcase
          end
        end
        CSR_B: begin
          expected_resp=(valid_csr(tr.addr) && tr.strb===4'hf)?2'b00:2'b10;
          if(tr.resp!==expected_resp) `uvm_error("SB_CSR_B",$sformatf("CSR write %08h expected response=%b observed=%b",tr.addr,expected_resp,tr.resp))
        end
        CSR_AR: begin
          expected_data=0; mask=0;
          if(valid_csr(tr.addr)) begin
            case(tr.addr)
              32'h00: begin expected_data={30'b0,cfg_irq,1'b0}; mask='1; end
              32'h04: begin expected_data=cfg_src; mask='1; end
              32'h08: begin expected_data=cfg_dst; mask='1; end
              32'h0c: begin expected_data=cfg_len; mask='1; end
              32'h18: begin expected_data=last_error; mask='1; end
              default: ;
            endcase
          end else mask='1; // Invalid reads return zero with SLVERR.
          csr_read_expected.push_back(expected_data); csr_read_masks.push_back(mask); csr_read_irq_en.push_back(cfg_irq);
        end
        CSR_R: begin
          expected_resp=valid_csr(tr.addr)?2'b00:2'b10;
          if(tr.resp!==expected_resp) `uvm_error("SB_CSR_R",$sformatf("CSR read %08h expected response=%b observed=%b",tr.addr,expected_resp,tr.resp))
          if(csr_read_expected.size()==0) `uvm_error("SB_CSR_QUEUE","CSR response without request")
          else begin
            expected_data=csr_read_expected.pop_front(); mask=csr_read_masks.pop_front(); sampled_irq_enable=csr_read_irq_en.pop_front();
            if((tr.data & mask)!==(expected_data & mask))
              `uvm_error("SB_CSR_DATA",$sformatf("CSR %08h expected=%08h mask=%08h observed=%08h",tr.addr,expected_data,mask,tr.data))
            if(tr.addr==32'h10 && tr.resp==0) begin
              if(tr.data[31:3]!==0) `uvm_error("SB_STATUS","Nonzero reserved status bits")
              if(active && tr.data[0]===0 && (tr.data[2]===1 || tr.data[1]===1)) finish_transfer(tr.data);
            end
            if(tr.addr==32'h14 && tr.resp==0) begin
              if(tr.data[31:2]!==0) `uvm_error("SB_IRQ_STATUS","Nonzero reserved IRQ_STATUS bits")
              if(tr.irq_sample !== (sampled_irq_enable && (|tr.data[1:0])))
                `uvm_error("SB_IRQ","IRQ does not match enable and observed sticky IRQ causes at CSR acceptance")
            end
          end
        end
        BUS_AR: begin check_address(tr,0); arq.push_back(tr); reads++; end
        BUS_R: begin
          if(arq.size()==0) `uvm_error("SB_ORPHAN_R","AXI R response without AR")
          else begin
            a=arq.pop_front(); offset=a.addr-transfer_src;
            if(tr.id!==a.id) `uvm_error("SB_RID","RID does not match ARID")
            // Protocol framing takes precedence when both faults are present.
            if(tr.last!==1'b1) begin expected_error=8; last_error=8; end
            else if(tr.resp!==2'b00) begin expected_error=5; last_error=5; end
            else if(active && descriptor_valid && offset<transfer_len) begin
              expected_data={initial_mem[transfer_src+offset+3],initial_mem[transfer_src+offset+2],initial_mem[transfer_src+offset+1],initial_mem[transfer_src+offset]};
              if(tr.data!==expected_data) `uvm_error("SB_READ_DATA",$sformatf("Read %08h expected=%08h observed=%08h",a.addr,expected_data,tr.data))
            end
            read_responses++;
          end
        end
        BUS_AW: begin check_address(tr,1); awq.push_back(tr); pair_write(); end
        BUS_W: begin
          if(!active || !descriptor_valid || expected_error!=0) `uvm_error("SB_UNEXPECTED_W","Unexpected AXI write data")
          wq.push_back(tr); pair_write();
        end
        BUS_B: begin
          if(bq.size()==0) `uvm_error("SB_ORPHAN_B","AXI B response without paired AW/W")
          else begin
            a=bq.pop_front();
            if(tr.id!==a.id) `uvm_error("SB_BID","BID does not match AWID")
            if(tr.resp!==2'b00) begin expected_error=6; last_error=6; end
            write_responses++;
          end
        end
        default: ;
      endcase
    endfunction
    function void check_phase(uvm_phase phase);
      super.check_phase(phase);
      if(active) `uvm_error("SB_PENDING_TRANSFER","Transfer did not reach an observed terminal STATUS read before test end")
      if(arq.size()+awq.size()+wq.size()+bq.size()+csr_read_expected.size()!=0)
        `uvm_error("SB_PENDING_AXI","Outstanding transaction remains at test end")
      if(starts!=completed+aborted) `uvm_error("SB_ACCOUNTING","Started transfers must be completed or explicitly canceled by reset")
    endfunction
    function void report_phase(uvm_phase phase);
      super.report_phase(phase);
      `uvm_info("SB_SUMMARY",$sformatf("starts=%0d completed=%0d reset_aborts=%0d busy_starts=%0d memory_bytes_checked=%0d",starts,completed,aborted,busy_starts,checked_bytes),UVM_NONE)
    endfunction
  endclass

  class dma_coverage extends uvm_subscriber #(dma_bus_event);
    `uvm_component_utils(dma_coverage)
    dma_cov model;
    function new(string name,uvm_component parent); super.new(name,parent); model=new(name); endfunction
    function void write(dma_bus_event t);
      case(t.kind)
        CSR_B: begin
          model.sample_csr_response(t.addr,1,t.data,t.strb,t.resp,t.irq_sample);
          model.sample_axil_order(t.write_order);
        end
        CSR_R: model.sample_csr_response(t.addr,0,t.data,0,t.resp,t.irq_sample);
        TRANSFER_START: model.sample_start(t.src,t.dst,t.len,t.irq_enable);
        TRANSFER_END: model.sample_result(t.code);
        START_WHILE_BUSY: model.sample_busy_start();
        RESET_ABORT: model.sample_reset_abort();
        RESET_PHASE: model.sample_reset_phase(t.channel);
        BUS_R: model.sample_bus_response(0,t.resp,t.last);
        BUS_B: model.sample_bus_response(1,t.resp,1);
        BUS_W: model.write_beats++;
        BUS_STALL: model.sample_bus_stall(t.channel);
        AXIL_STALL: model.sample_axil_stall(t.channel);
        AW_WAIT_W: model.sample_aw_wait_w();
        default: ;
      endcase
    endfunction
    function void report_phase(uvm_phase phase);
      super.report_phase(phase);
      if(!model.write_report()) `uvm_error("COV_EXPORT","Cannot write required coverage evidence")
      `uvm_info("COV_COUNTS",$sformatf("starts=%0d results=%0d success=%0d len0=%0d align=%0d range=%0d rresp=%0d bresp=%0d rlast=%0d busy_start=%0d reset_abort=%0d read_beats=%0d write_beats=%0d",model.starts,model.results,model.successes,model.errors[1],model.errors[2],model.errors[3],model.errors[5],model.errors[6],model.errors[8],model.busy_starts,model.reset_aborts,model.read_beats,model.write_beats),UVM_NONE)
      `uvm_info("COV_STALL",$sformatf("AR/R/AW/W/B stalled cycles=%0d/%0d/%0d/%0d/%0d",model.stall_cycles[0],model.stall_cycles[1],model.stall_cycles[2],model.stall_cycles[3],model.stall_cycles[4]),UVM_NONE)
      for(int i=0;i<9;i++) `uvm_info("COV_CSR",$sformatf("register_index=%0d reads=%0d writes=%0d (index 8 is invalid address)",i,model.reg_reads[i],model.reg_writes[i]),UVM_LOW)
`ifdef ENABLE_SV_COV
      `uvm_info("COV_MODE","Native covergroups enabled; use simulator coverage reports to assess bin closure",UVM_NONE)
`else
      `uvm_info("COV_MODE","Observed event counters enabled; native covergroups disabled. Counts are not a coverage percentage",UVM_NONE)
`endif
    endfunction
  endclass

  class dma_env extends uvm_env;
    `uvm_component_utils(dma_env)
    dma_axil_agent axil_agent;
    dma_axi_monitor axi_monitor;
    dma_scoreboard scoreboard;
    dma_coverage coverage;
    function new(string name,uvm_component parent); super.new(name,parent); endfunction
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      axil_agent=dma_axil_agent::type_id::create("axil_agent",this);
      axi_monitor=dma_axi_monitor::type_id::create("axi_monitor",this);
      scoreboard=dma_scoreboard::type_id::create("scoreboard",this);
      coverage=dma_coverage::type_id::create("coverage",this);
    endfunction
    function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);
      axil_agent.monitor.ap.connect(scoreboard.analysis_export);
      axil_agent.monitor.ap.connect(coverage.analysis_export);
      axi_monitor.ap.connect(scoreboard.analysis_export);
      axi_monitor.ap.connect(coverage.analysis_export);
      scoreboard.ap.connect(coverage.analysis_export);
    endfunction
    task write32(input logic [31:0] addr,data,output logic [1:0] resp,
                 input logic [3:0] strb=4'hf,input int aw_delay=0,w_delay=0,resp_delay=0);
      dma_axil_sequence seq;
      if(aw_delay<0 || w_delay<0 || resp_delay<0) `uvm_fatal("AXIL_DELAY","Driver delays must be nonnegative")
      seq=dma_axil_sequence::type_id::create("write_sequence");
      seq.item=dma_axil_item::type_id::create("write_item");
      seq.item.is_write=1; seq.item.addr=addr; seq.item.data=data; seq.item.strb=strb;
      seq.item.aw_delay=aw_delay; seq.item.w_delay=w_delay; seq.item.resp_delay=resp_delay;
      seq.start(axil_agent.sequencer); resp=seq.item.resp;
    endtask
    task read32(input logic [31:0] addr,output logic [31:0] data,output logic [1:0] resp,input int resp_delay=0);
      dma_axil_sequence seq;
      if(resp_delay<0) `uvm_fatal("AXIL_DELAY","Driver delays must be nonnegative")
      seq=dma_axil_sequence::type_id::create("read_sequence");
      seq.item=dma_axil_item::type_id::create("read_item");
      seq.item.is_write=0; seq.item.addr=addr; seq.item.resp_delay=resp_delay;
      seq.start(axil_agent.sequencer); data=seq.item.data; resp=seq.item.resp;
    endtask
  endclass
endpackage
