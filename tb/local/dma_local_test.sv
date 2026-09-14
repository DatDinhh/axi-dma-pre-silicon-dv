`timescale 1ns/1ps
// Classless local regression. UVM remains the primary portfolio testbench.
// The independent oracle snapshots all memory before START and checks every byte.
module dma_local_test;
  localparam int ADDR_WIDTH=32, AXIL_DATA_WIDTH=32, AXI_DATA_WIDTH=32;
  localparam int AXI_ID_WIDTH=1, MAX_BURST_BEATS=16, MEM_SIZE_BYTES=65536;
  localparam bit ENABLE_4KB_RULE=1, ENABLE_BYTES_REMAIN=1;
  logic clk=0, rst_n=0, irq;
  always #5 clk=~clk;
  axi_if axi(clk,rst_n);
  axil_if axil(clk,rst_n);
  mem_bkdr_if memif();
  axi_mem_model u_mem(axi,memif);
  dma_local_checks checks(axi,axil);
  top_soc_dut #(
    .ADDR_WIDTH          (ADDR_WIDTH),
    .AXIL_DATA_WIDTH     (AXIL_DATA_WIDTH),
    .AXI_DATA_WIDTH      (AXI_DATA_WIDTH),
    .AXI_ID_WIDTH        (AXI_ID_WIDTH),
    .MAX_BURST_BEATS     (MAX_BURST_BEATS),
    .MEM_SIZE_BYTES      (MEM_SIZE_BYTES),
    .ENABLE_4KB_RULE     (ENABLE_4KB_RULE),
    .ENABLE_BYTES_REMAIN (ENABLE_BYTES_REMAIN)
  ) dut (
    .clk            (clk),
    .rst_n          (rst_n),

    .s_axil_awaddr  (axil.awaddr),
    .s_axil_awprot  (axil.awprot),
    .s_axil_awvalid (axil.awvalid),
    .s_axil_awready (axil.awready),

    .s_axil_wdata   (axil.wdata),
    .s_axil_wstrb   (axil.wstrb),
    .s_axil_wvalid  (axil.wvalid),
    .s_axil_wready  (axil.wready),

    .s_axil_bresp   (axil.bresp),
    .s_axil_bvalid  (axil.bvalid),
    .s_axil_bready  (axil.bready),

    .s_axil_araddr  (axil.araddr),
    .s_axil_arprot  (axil.arprot),
    .s_axil_arvalid (axil.arvalid),
    .s_axil_arready (axil.arready),

    .s_axil_rdata   (axil.rdata),
    .s_axil_rresp   (axil.rresp),
    .s_axil_rvalid  (axil.rvalid),
    .s_axil_rready  (axil.rready),

    .m_axi_awid     (axi.awid),
    .m_axi_awaddr   (axi.awaddr),
    .m_axi_awlen    (axi.awlen),
    .m_axi_awsize   (axi.awsize),
    .m_axi_awburst  (axi.awburst),
    .m_axi_awlock   (axi.awlock),
    .m_axi_awcache  (axi.awcache),
    .m_axi_awprot   (axi.awprot),
    .m_axi_awqos    (axi.awqos),
    .m_axi_awvalid  (axi.awvalid),
    .m_axi_awready  (axi.awready),

    .m_axi_wdata    (axi.wdata),
    .m_axi_wstrb    (axi.wstrb),
    .m_axi_wlast    (axi.wlast),
    .m_axi_wvalid   (axi.wvalid),
    .m_axi_wready   (axi.wready),

    .m_axi_bid      (axi.bid),
    .m_axi_bresp    (axi.bresp),
    .m_axi_bvalid   (axi.bvalid),
    .m_axi_bready   (axi.bready),

    .m_axi_arid     (axi.arid),
    .m_axi_araddr   (axi.araddr),
    .m_axi_arlen    (axi.arlen),
    .m_axi_arsize   (axi.arsize),
    .m_axi_arburst  (axi.arburst),
    .m_axi_arlock   (axi.arlock),
    .m_axi_arcache  (axi.arcache),
    .m_axi_arprot   (axi.arprot),
    .m_axi_arqos    (axi.arqos),
    .m_axi_arvalid  (axi.arvalid),
    .m_axi_arready  (axi.arready),

    .m_axi_rid      (axi.rid),
    .m_axi_rdata    (axi.rdata),
    .m_axi_rresp    (axi.rresp),
    .m_axi_rlast    (axi.rlast),
    .m_axi_rvalid   (axi.rvalid),
    .m_axi_rready   (axi.rready),

    .irq            (irq)
  );


  string local_case;
  int unsigned rng=1, transfer_count=128;
  int unsigned transfers=0, completed=0, reset_aborts=0, memory_checked=0;
  bit oracle_active=0;
  logic [31:0] oracle_src, oracle_dst, oracle_len;
  int unsigned ar_count, r_count, aw_count, w_count, b_count;
  int unsigned r_errors, b_errors;
  byte unsigned initial_mem[MEM_SIZE_BYTES], expected_mem[MEM_SIZE_BYTES];

  function automatic int unsigned next_random();
    rng=rng^(rng<<13); rng=rng^(rng>>17); rng=rng^(rng<<5);
    return rng;
  endfunction

  // A hard simulation-time limit supplements bounded AXI-Lite and DMA polling.
  initial begin
    #100ms;
    $fatal(1,"LOCAL_WATCHDOG: exceeded 100ms simulation time");
  end

  task automatic idle_axil();
    axil.awaddr=0; axil.awprot=0; axil.awvalid=0;
    axil.wdata=0; axil.wstrb=0; axil.wvalid=0; axil.bready=0;
    axil.araddr=0; axil.arprot=0; axil.arvalid=0; axil.rready=0;
  endtask

  task automatic reset_dut(input bit already_negedge=0);
    if (!already_negedge) @(negedge clk);
    rst_n=0; idle_axil();
    repeat(5) @(posedge clk);
    @(negedge clk); rst_n=1;
    repeat(3) @(negedge clk);
  endtask

  task automatic csr_write(input logic[31:0] addr, data,
                           input logic[1:0] response=0,
                           input logic[3:0] strobe=4'hf,
                           input int aw_delay=0, w_delay=0, response_delay=0);
    bit aw_done=0, w_done=0;
    int waited=0;
    for (int cycle=0; cycle<2000; cycle++) begin
      @(negedge clk);
      axil.awaddr=addr; axil.awprot=0;
      axil.wdata=data; axil.wstrb=strobe;
      axil.awvalid=!aw_done && cycle>=aw_delay;
      axil.wvalid=!w_done && cycle>=w_delay;
      axil.bready=aw_done && w_done && waited>=response_delay;
      if (aw_done && w_done) waited++;
      @(posedge clk);
      if (axil.awvalid && axil.awready) aw_done=1;
      if (axil.wvalid && axil.wready) w_done=1;
      if (axil.bvalid && axil.bready) begin
        if (axil.bresp !== response)
          $fatal(1,"CSR_BRESP addr=%h expected=%h actual=%h",addr,response,axil.bresp);
        @(negedge clk); axil.awvalid=0; axil.wvalid=0; axil.bready=0;
        return;
      end
    end
    $fatal(1,"CSR_WRITE_TIMEOUT addr=%h",addr);
  endtask

  task automatic csr_read(input logic[31:0] addr, output logic[31:0] data,
                          input logic[1:0] response=0, input int response_delay=0);
    bit ar_done=0;
    int waited=0;
    for (int cycle=0; cycle<2000; cycle++) begin
      @(negedge clk);
      axil.araddr=addr; axil.arprot=0; axil.arvalid=!ar_done;
      axil.rready=ar_done && waited>=response_delay;
      if (ar_done) waited++;
      @(posedge clk);
      if (axil.arvalid && axil.arready) ar_done=1;
      if (axil.rvalid && axil.rready) begin
        data=axil.rdata;
        if (axil.rresp !== response)
          $fatal(1,"CSR_RRESP addr=%h expected=%h actual=%h",addr,response,axil.rresp);
        @(negedge clk); axil.arvalid=0; axil.rready=0;
        return;
      end
    end
    $fatal(1,"CSR_READ_TIMEOUT addr=%h",addr);
  endtask

  task automatic expect_csr(input logic[31:0] addr, expected,
                            input logic[1:0] response=0, input int response_delay=0);
    logic[31:0] data;
    csr_read(addr,data,response,response_delay);
    if (data !== expected) $fatal(1,"CSR_VALUE addr=%h expected=%h actual=%h",addr,expected,data);
  endtask

  task automatic expect_irq(input bit expected);
    @(negedge clk);
    if (irq !== expected) $fatal(1,"IRQ expected=%b actual=%b",expected,irq);
  endtask

  task automatic program_dma(input logic[31:0] src,dst,len);
    csr_write(4,src); csr_write(8,dst); csr_write(12,len);
  endtask

  task automatic prepare(input int unsigned src,dst,len,pattern=8'h3c);
    // Distinct source and destination are a documented descriptor precondition.
    for (int i=0; i<MEM_SIZE_BYTES; i++) memif.mem[i]=8'hc7;
    for (int i=0; i<len; i++) begin
      memif.mem[src+i]=8'(pattern+i);
      memif.mem[dst+i]=8'ha5;
    end
  endtask

  task automatic start_oracle(input logic[31:0] src,dst,len);
    if (oracle_active) $fatal(1,"ORACLE nested transfer");
    @(negedge clk);
    oracle_src=src; oracle_dst=dst; oracle_len=len;
    ar_count=0; r_count=0; aw_count=0; w_count=0; b_count=0;
    r_errors=0; b_errors=0;
    for(int i=0;i<MEM_SIZE_BYTES;i++) begin
      initial_mem[i]=memif.mem[i]; expected_mem[i]=memif.mem[i];
    end
    transfers++; oracle_active=1;
  endtask

  // Passive handshake oracle is independent of the engine's internal state.
  // It computes destination data exclusively from the pre-START source image.
  always @(posedge clk) begin : monitor_memory
    logic[31:0] expected_word;
    if (rst_n && oracle_active) begin
      if (axi.arvalid && axi.arready) begin
        if (axi.araddr >= MEM_SIZE_BYTES || axi.araddr !== oracle_src+4*ar_count || 4*ar_count>=oracle_len)
          $fatal(1,"ORACLE_AR addr=%h beat=%0d",axi.araddr,ar_count);
        ar_count++;
      end
      if (axi.rvalid && axi.rready) begin
        if (r_count>=ar_count) $fatal(1,"ORACLE_R without request");
        if (axi.rresp==0) begin
          for(int b=0;b<4;b++) expected_word[8*b+:8]=initial_mem[oracle_src+4*r_count+b];
          if (axi.rdata !== expected_word) $fatal(1,"ORACLE_RDATA beat=%0d",r_count);
        end else r_errors++;
        r_count++;
      end
      if (axi.awvalid && axi.awready) begin
        if (axi.awaddr >= MEM_SIZE_BYTES || axi.awaddr !== oracle_dst+4*aw_count || 4*aw_count>=oracle_len)
          $fatal(1,"ORACLE_AW addr=%h beat=%0d",axi.awaddr,aw_count);
        aw_count++;
      end
      if (axi.wvalid && axi.wready) begin
        if (w_count>=aw_count || 4*w_count>=oracle_len)
          $fatal(1,"ORACLE_W unexpected beat=%0d",w_count);
        for(int b=0;b<4;b++) begin
          expected_word[8*b+:8]=initial_mem[oracle_src+4*w_count+b];
          expected_mem[oracle_dst+4*w_count+b]=initial_mem[oracle_src+4*w_count+b];
        end
        if (axi.wdata !== expected_word || axi.wstrb!==4'hf)
          $fatal(1,"ORACLE_WDATA beat=%0d expected=%h actual=%h",w_count,expected_word,axi.wdata);
        w_count++;
      end
      if (axi.bvalid && axi.bready) begin
        if (b_count>=w_count) $fatal(1,"ORACLE_B without write");
        if (axi.bresp!=0) b_errors++;
        b_count++;
      end
    end
  end

  task automatic compare_memory();
    for(int i=0;i<MEM_SIZE_BYTES;i++) begin
      if(memif.mem[i] !== expected_mem[i])
        $fatal(1,"ORACLE_MEMORY addr=%h expected=%h actual=%h",i,expected_mem[i],memif.mem[i]);
    end
    memory_checked+=MEM_SIZE_BYTES;
  endtask

  task automatic wait_terminal(output logic[31:0] status);
    for(int i=0;i<30000;i++) begin
      csr_read(16,status);
      if (!status[0] && |status[2:1]) return;
    end
    $fatal(1,"DMA_TERMINAL_TIMEOUT");
  endtask

  task automatic finish_transfer(input int unsigned code=0,
                                  input bit irq_enable=1, clear_event=1,
                                  input int expected_reads=-1, expected_writes=-1,
                                  input bit old_done=0);
    logic[31:0] status;
    wait_terminal(status);
    if (status !== (code==0 ? 32'd2 : (old_done ? 32'd6 : 32'd4)))
      $fatal(1,"TERMINAL_STATUS code=%0d status=%h",code,status);
    expect_csr(24,code); expect_csr(28,0);
    expect_csr(20, code==0 ? 1 : (old_done ? 3 : 2));
    expect_irq(irq_enable);
    if (code==0) begin
      if (ar_count!=oracle_len/4 || r_count!=oracle_len/4 ||
          aw_count!=oracle_len/4 || w_count!=oracle_len/4 || b_count!=oracle_len/4 ||
          r_errors!=0 || b_errors!=0)
        $fatal(1,"ORACLE_SUCCESS_COUNTS ar/r/aw/w/b=%0d/%0d/%0d/%0d/%0d",ar_count,r_count,aw_count,w_count,b_count);
    end else begin
      if (expected_reads>=0 && (ar_count!=expected_reads || r_count!=expected_reads))
        $fatal(1,"ORACLE_ERROR_READ_COUNTS expected=%0d ar=%0d r=%0d",expected_reads,ar_count,r_count);
      if (expected_writes>=0 && (aw_count!=expected_writes || w_count!=expected_writes || b_count!=expected_writes))
        $fatal(1,"ORACLE_ERROR_WRITE_COUNTS expected=%0d aw=%0d w=%0d b=%0d",expected_writes,aw_count,w_count,b_count);
      if ((code==5 && (r_errors!=1 || b_errors!=0)) ||
          (code==6 && (r_errors!=0 || b_errors!=1)) ||
          (code<5 && (r_errors!=0 || b_errors!=0)))
        $fatal(1,"ORACLE_ERROR_RESPONSES code=%0d r=%0d b=%0d",code,r_errors,b_errors);
    end
    compare_memory(); oracle_active=0; completed++;
    if (clear_event) begin
      csr_write(20,3); expect_csr(16,0); expect_irq(0);
    end
  endtask

  task automatic run_copy(input int unsigned src,dst,len,
                          input bit irq_enable=1, input int unsigned pattern=8'h3c);
    prepare(src,dst,len,pattern); program_dma(src,dst,len);
    start_oracle(src,dst,len);
    if ($test$plusargs("LOCAL_ORACLE_NEGATIVE")) begin
      memif.mem['h7000]=memif.mem['h7000]^8'h01;
      $display("LOCAL_ORACLE_NEGATIVE injected guard corruption addr=00007000");
    end
    csr_write(0,irq_enable ? 3 : 1);
    finish_transfer(0,irq_enable);
  endtask

  task automatic bad_descriptor(input logic[31:0] src,dst,len,input int unsigned code);
    program_dma(src,dst,len); start_oracle(src,dst,len); csr_write(0,3);
    finish_transfer(code,1,1,0,0);
    expect_csr(24,code); csr_write(0,10); expect_csr(24,0);
    run_copy('h200,'h9000,16);
  endtask

  task automatic csr_scenario();
    for(int i=0;i<8;i++) expect_csr(4*i,0);
    csr_write(4,'h11223344,0,15,0,4,5); expect_csr(4,'h11223344,0,5);
    csr_write(8,'h55667788,0,15,4,0,5); expect_csr(8,'h55667788,0,5);
    csr_write(12,'h89abcdef,0,15,0,0,5); expect_csr(12,'h89abcdef,0,5);
    for(int strobe=0;strobe<15;strobe++) begin
      csr_write(4,'hfedcba98,2,4'(strobe)); expect_csr(4,'h11223344);
    end
    csr_write(2,32'hffffffff,2); expect_csr(2,0,2);
    csr_write(32,32'hffffffff,2); expect_csr(32,0,2);
    csr_write(32'hfffffff0,32'hffffffff,2); expect_csr(32'hfffffff0,0,2);
    csr_write(16,32'hffffffff); csr_write(24,32'hffffffff); csr_write(28,32'hffffffff);
    expect_csr(16,0); expect_csr(24,0); expect_csr(28,0);
    csr_write(0,2); expect_csr(0,2); expect_irq(0);
    csr_write(0,0); expect_csr(0,0);
    run_copy('h100,'h8000,64);
  endtask

  task automatic irq_scenario();
    prepare('h100,'h8000,16); program_dma('h100,'h8000,16);
    start_oracle('h100,'h8000,16); csr_write(0,1); finish_transfer(0,0,0);
    csr_write(0,2); expect_irq(1); csr_write(0,0); expect_irq(0);
    program_dma('h100,'h8000,0); start_oracle('h100,'h8000,0);
    csr_write(0,1); finish_transfer(1,0,0,0,0,1);
    csr_write(0,2); expect_irq(1); csr_write(20,1); expect_csr(16,4); expect_irq(1);
    csr_write(20,2); expect_csr(16,0); expect_csr(24,1); expect_irq(0);
    csr_write(0,10); expect_csr(24,0);
    prepare('h200,'h9000,4); program_dma('h200,'h9000,4);
    start_oracle('h200,'h9000,4); csr_write(0,3); finish_transfer(0,1,0);
    csr_write(0,6); expect_csr(16,0); expect_irq(0);
    run_copy('h200,'h9000,4);
  endtask

  task automatic busy_scenario();
    logic[31:0] status, remaining;
    prepare('h100,'h8000,512);
    for(int i=0;i<16;i++) begin memif.mem['h3000+i]=8'(i+'h7c); memif.mem['ha000+i]='ha5; end
    program_dma('h100,'h8000,512); start_oracle('h100,'h8000,512); csr_write(0,3);
    csr_read(16,status); if(!status[0]) $fatal(1,"BUSY_NOT_OBSERVED");
    csr_read(28,remaining); if(remaining==0 || remaining>512 || remaining%4) $fatal(1,"BUSY_REMAIN %0d",remaining);
    program_dma('h3000,'ha000,16); csr_write(0,3); // Ignored START, config latches for next transfer.
    finish_transfer();
    start_oracle('h3000,'ha000,16); csr_write(0,3); finish_transfer();
  endtask

  task automatic reset_scenario(input int phase);
    bit seen=0;
    prepare('h100,'h8000,256); program_dma('h100,'h8000,256);
    start_oracle('h100,'h8000,256); csr_write(0,3);
    for(int i=0;i<10000;i++) begin
      @(negedge clk);
      case(phase)
        0: seen=axi.arvalid;
        1: seen=axi.rready;
        2: seen=axi.awvalid;
        3: seen=axi.wvalid && !axi.awvalid;
        4: seen=axi.bready;
        default: $fatal(1,"BAD_RESET_PHASE");
      endcase
      if(seen) break;
    end
    if(!seen) $fatal(1,"RESET_PHASE_NOT_SEEN %0d",phase);
    $display("LOCAL_RESET_PHASE phase=%0d ar/r/aw/w/b=%0d/%0d/%0d/%0d/%0d",phase,ar_count,r_count,aw_count,w_count,b_count);
    // Reset arrives at the observed falling edge, before another handshake.
    reset_dut(1); compare_memory(); oracle_active=0; reset_aborts++;
    for(int i=0;i<8;i++) expect_csr(4*i,0);
    expect_irq(0);
    if(axi.arvalid || axi.awvalid || axi.wvalid || axi.bready || axi.rready)
      $fatal(1,"RESET_OUTSTANDING");
    run_copy('h200,'h9000,16);
  endtask

  task automatic fault_scenario(input bit write_fault);
    logic[31:0] injected_addr;
    int offset,src,dst,beats;
    if(write_fault) begin
      if(!$value$plusargs("AXI_BERR_ADDR=%h",injected_addr) || injected_addr!='h8000)
        $fatal(1,"write_errors requires AXI_BERR_ADDR=8000");
    end else begin
      if(!$value$plusargs("AXI_RERR_ADDR=%h",injected_addr) || injected_addr!='h100)
        $fatal(1,"read_errors requires AXI_RERR_ADDR=100");
    end
    for(int position=0;position<3;position++) begin
      offset=(position==0 ? 0 : position==1 ? 28 : 60);
      src=write_fault ? 'h100 : 'h100-offset;
      dst=write_fault ? 'h8000-offset : 'h8000;
      beats=offset/4+1;
      prepare(src,dst,64); program_dma(src,dst,64); start_oracle(src,dst,64); csr_write(0,3);
      finish_transfer(write_fault ? 6 : 5,1,1,beats,write_fault ? beats : beats-1);
      run_copy('h200,'h9000,16);
    end
  endtask

  initial begin : test_main
    int length,src,dst,pattern;
    bit irq_enable;
    idle_axil();
    if(!$value$plusargs("LOCAL_CASE=%s",local_case)) $fatal(1,"LOCAL_CASE is required");
    void'($value$plusargs("TEST_SEED=%d",rng)); if(rng==0) rng=1;
    void'($value$plusargs("TRANSFER_COUNT=%d",transfer_count));
    if(transfer_count<1 || transfer_count>10000) $fatal(1,"TRANSFER_COUNT range 1..10000");
    $display("LOCAL_BEGIN case=%s seed=%0d",local_case,rng);
    reset_dut();
    case(local_case)
      "csr": csr_scenario();
      "lengths": begin
        run_copy('h100,'h8000,4); run_copy('h100,'h8000,16);
        run_copy('h100,'h8000,64); run_copy('h100,'h8000,128); run_copy('h100,'h8000,512);
      end
      "boundaries": begin
        run_copy('hfffc,'h8000,4); run_copy('h100,'hfffc,4);
        run_copy('hffc,'h8ffc,32); run_copy(0,'h8000,4); run_copy('h8000,0,4);
      end
      "invalid_zero": bad_descriptor('h100,'h8000,0,1);
      "invalid_src_align": bad_descriptor('h102,'h8000,64,2);
      "invalid_dst_align": bad_descriptor('h100,'h8001,64,2);
      "invalid_len_align": begin
        bad_descriptor('h100,'h8000,1,2); bad_descriptor('h100,'h8000,3,2); bad_descriptor('h100,'h8000,6,2);
      end
      "invalid_src_range": begin bad_descriptor('h10000,'h8000,64,3); bad_descriptor('hfffc,'h8000,8,3); end
      "invalid_dst_range": begin bad_descriptor('h100,'h10000,64,3); bad_descriptor('h100,'hfffc,8,3); end
      "invalid_overflow": begin
        bad_descriptor(32'hfffffffc,'h8000,8,3); bad_descriptor('h100,32'hfffffffc,8,3);
        bad_descriptor('h100,'h8000,32'hfffffffc,3);
      end
      "irq": irq_scenario();
      "busy": busy_scenario();
      "reset_ar": reset_scenario(0);
      "reset_r": reset_scenario(1);
      "reset_aw": reset_scenario(2);
      "reset_w": reset_scenario(3);
      "reset_b": reset_scenario(4);
      "read_errors": fault_scenario(0);
      "write_errors": fault_scenario(1);
      "random": for(int i=0;i<transfer_count;i++) begin
        length=4*(1+next_random()%128); src=4*(next_random()%3500);
        dst='h8000+4*(next_random()%3500); pattern=next_random()&255;
        irq_enable=1'(next_random());
        run_copy(src,dst,length,irq_enable,pattern);
      end
      default: $fatal(1,"Unknown LOCAL_CASE=%s",local_case);
    endcase
    repeat(8) @(negedge clk);
    if(oracle_active || transfers!=completed+reset_aborts) $fatal(1,"LOCAL_INCOMPLETE");
    $display("LOCAL_SUMMARY transfers=%0d completed=%0d reset_aborts=%0d memory_checked=%0d",transfers,completed,reset_aborts,memory_checked);
    $display("LOCAL_TEST_PASS %s",local_case);
    $finish;
  end
endmodule
