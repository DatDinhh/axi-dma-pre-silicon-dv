// Finite, observed requirement bins for the single-beat baseline.
// Coverage is exported without a native covergroup license. The portfolio
// aggregator accepts only passing runs with identical source/catalog hashes.
// This metric is NOT native covergroup, RTL code, or assertion coverage.
package dma_cov_pkg;
  timeunit 1ns; timeprecision 1ps;
  class dma_cov;
    string name;
    int unsigned reg_reads[9], reg_writes[9];
    int unsigned starts, results, successes, errors[9], busy_starts, reset_aborts;
    int unsigned read_beats, write_beats, stall_cycles[5];
    int unsigned reg_id, outcome, error_code, len_bucket;
    bit is_write, irq_enable, src_aligned, dst_aligned;
    // Fixed storage avoids simulator-specific associative-array serialization.
    string bin_names[128];
    longint unsigned bin_hits[128];
    int unsigned bin_count;
    logic [31:0] transfer_src, transfer_dst, transfer_len;
    int unsigned read_response_index, write_response_index;
    bit transfer_open, previous_error, awaiting_reset_recovery;
`ifdef ENABLE_SV_COV
    // Optional diagnostic covergroups. Their cross products are not the finite
    // required-bin catalog and no closure percentage is inferred from them.
    covergroup cg_register;
      option.per_instance = 1;
      cp_register: coverpoint reg_id { bins registers[] = {[0:7]}; bins invalid = {8}; }
      cp_direction: coverpoint is_write;
      register_direction: cross cp_register, cp_direction;
    endgroup
    covergroup cg_transfer;
      option.per_instance = 1;
      cp_length: coverpoint len_bucket { bins zero={0}; bins word={1}; bins short_copy={2}; bins medium_copy={3}; bins long_copy={4}; }
      cp_irq: coverpoint irq_enable;
      cp_src_alignment: coverpoint src_aligned;
      cp_dst_alignment: coverpoint dst_aligned;
      length_irq: cross cp_length, cp_irq;
      alignment: cross cp_src_alignment, cp_dst_alignment;
    endgroup
    covergroup cg_result;
      option.per_instance = 1;
      cp_error: coverpoint error_code { bins none={0}; bins length={1}; bins alignment={2}; bins range={3}; bins read_response={5}; bins write_response={6}; bins read_last={8}; }
      cp_irq: coverpoint irq_enable;
      cp_length: coverpoint len_bucket;
      error_irq: cross cp_error, cp_irq;
      length_error: cross cp_length, cp_error;
    endgroup
`endif
    function void add_bin(string id);
      if (bin_count>=128) $fatal(1,"Requirement coverage catalog exceeds storage");
      bin_names[bin_count]=id; bin_hits[bin_count]=0; bin_count++;
    endfunction
    function void hit(string id);
      for (int i=0;i<bin_count;i++) begin
        if (bin_names[i]==id) begin bin_hits[i]++; return; end
      end
      $fatal(1,"Unknown requirement coverage bin: %s",id);
    endfunction
    function new(string name="dma_cov");
      this.name=name;
      add_bin("R01.copy_len_4");
      add_bin("R01.copy_len_16");
      add_bin("R01.copy_len_64");
      add_bin("R01.copy_len_128");
      add_bin("R01.copy_len_512");
      add_bin("R02.read_response_okay");
      add_bin("R02.write_response_okay");
      add_bin("R03.axi_ar_stall");
      add_bin("R03.axi_aw_stall");
      add_bin("R03.axi_w_stall");
      add_bin("R03.axil_r_stall");
      add_bin("R03.axil_b_stall");
      add_bin("R04.wvalid_before_aw_accept");
      add_bin("R05.zero_length");
      add_bin("R05.unaligned_src");
      add_bin("R05.unaligned_dst");
      add_bin("R05.unaligned_len");
      add_bin("R06.src_range_error");
      add_bin("R06.src_end_of_memory");
      add_bin("R06.src_page_cross");
      add_bin("R06.dst_range_error");
      add_bin("R06.dst_end_of_memory");
      add_bin("R06.dst_page_cross");
      add_bin("R06.address_sum_overflow");
      add_bin("R07.read_ctrl");
      add_bin("R07.read_src");
      add_bin("R07.read_dst");
      add_bin("R07.read_len");
      add_bin("R07.read_status");
      add_bin("R07.read_irq_status");
      add_bin("R07.read_err_code");
      add_bin("R07.read_bytes_remain");
      add_bin("R07.write_ctrl");
      add_bin("R07.write_src");
      add_bin("R07.write_dst");
      add_bin("R07.write_len");
      add_bin("R07.write_irq_status");
      add_bin("R07.write_status");
      add_bin("R07.write_err_code");
      add_bin("R07.read_unaligned");
      add_bin("R07.read_unmapped");
      add_bin("R07.write_unaligned");
      add_bin("R07.write_unmapped");
      add_bin("R07.strobe_partial");
      add_bin("R07.strobe_zero");
      add_bin("R07.axil_aw_first");
      add_bin("R07.axil_w_first");
      add_bin("R07.axil_same_cycle");
      add_bin("R08.success_irq_enabled");
      add_bin("R08.success_irq_masked");
      add_bin("R08.pending_masked");
      add_bin("R08.pending_asserted");
      add_bin("R08.w1c_done");
      add_bin("R08.w1c_err");
      add_bin("R08.ctrl_clear_err");
      add_bin("R09.done_and_err");
      add_bin("R09.recovery_after_error");
      add_bin("R10.busy_start");
      add_bin("R11.reset_ar");
      add_bin("R11.reset_r");
      add_bin("R11.reset_aw");
      add_bin("R11.reset_w");
      add_bin("R11.reset_b");
      add_bin("R11.recovery_after_reset");
      add_bin("R12.read_slverr_first");
      add_bin("R12.read_slverr_middle");
      add_bin("R12.read_slverr_last");
      add_bin("R12.write_slverr_first");
      add_bin("R12.write_slverr_middle");
      add_bin("R12.write_slverr_last");
`ifdef ENABLE_SV_COV
      cg_register=new(); cg_transfer=new(); cg_result=new();
`endif
    endfunction
    function string register_name(int unsigned index);
      case(index)
        0:return "ctrl"; 1:return "src"; 2:return "dst"; 3:return "len";
        4:return "status"; 5:return "irq_status"; 6:return "err_code";
        7:return "bytes_remain"; default:return "invalid";
      endcase
    endfunction
    function void sample_register(logic [31:0] addr, bit write_access);
      // Decode the complete address; high-address aliases remain invalid.
      reg_id=(!$isunknown(addr) && addr<=32'h1c && addr[1:0]==0) ? addr/4 : 8;
      is_write=write_access;
      if (is_write) reg_writes[reg_id]++; else reg_reads[reg_id]++;
`ifdef ENABLE_SV_COV
      cg_register.sample();
`endif
    endfunction
    // Call on B/R handshake with payload retained from the accepted AW/W or AR.
    // This method includes sample_register; do not call both for one response.
    function void sample_csr_response(logic [31:0] addr, bit write_access,
                                      logic [31:0] data, logic [3:0] strb,
                                      logic [1:0] resp, logic irq_sample);
      string direction;
      sample_register(addr,write_access);
      direction=write_access ? "write" : "read";
      if (resp===2'b00 && reg_id<8) begin
        // BYTES_REMAIN RO write is not selected in the baseline catalog.
        if (!write_access || reg_id!=7)
          hit({"R07.",direction,"_",register_name(reg_id)});
        if (write_access && strb===4'hf) begin
          if (addr==32'h14 && data[1:0]===2'b01) hit("R08.w1c_done");
          if (addr==32'h14 && data[1:0]===2'b10) hit("R08.w1c_err");
          if (addr==0 && data[3]===1'b1) hit("R08.ctrl_clear_err");
        end
        if (!write_access) begin
          if (addr==32'h14 && !$isunknown(data[1:0]) && data[1:0]!=0) begin
            if (irq_sample===1'b0) hit("R08.pending_masked");
            if (irq_sample===1'b1) hit("R08.pending_asserted");
          end
          if ((addr==32'h10 && data[2:1]===2'b11) ||
              (addr==32'h14 && data[1:0]===2'b11)) hit("R09.done_and_err");
        end
      end
      if (resp===2'b10 && !$isunknown(addr)) begin
        if (addr[1:0]!=0) hit({"R07.",direction,"_unaligned"});
        else if (addr>32'h1c) hit({"R07.",direction,"_unmapped"});
        if (write_access && reg_id<8 && !$isunknown(strb)) begin
          if (strb==0) hit("R07.strobe_zero");
          else if (strb!=4'hf) hit("R07.strobe_partial");
        end
      end
    endfunction
    function void sample_axil_order(int unsigned order);
      case(order)
        0:hit("R07.axil_aw_first");
        1:hit("R07.axil_w_first");
        2:hit("R07.axil_same_cycle");
        default:$fatal(1,"Invalid AXI-Lite handshake order");
      endcase
    endfunction
    function void sample_bus_stall(int unsigned channel);
      if(channel<5) stall_cycles[channel]++;
      case(channel)
        0:hit("R03.axi_ar_stall");
        2:hit("R03.axi_aw_stall");
        3:hit("R03.axi_w_stall");
        default:; // R/B VALID backpressure is not an eligible baseline bin.
      endcase
    endfunction
    function void sample_axil_stall(int unsigned channel);
      case(channel)
        1:hit("R03.axil_r_stall");
        4:hit("R03.axil_b_stall");
        default:;
      endcase
    endfunction
    function void sample_aw_wait_w();
      hit("R04.wvalid_before_aw_accept");
    endfunction
    function void sample_busy_start();
      busy_starts++; hit("R10.busy_start");
    endfunction
    function void sample_reset_abort();
      reset_aborts++; awaiting_reset_recovery=1; transfer_open=0; previous_error=0;
    endfunction
    function void sample_reset_phase(int unsigned channel);
      case(channel)
        0:hit("R11.reset_ar"); 1:hit("R11.reset_r");
        2:hit("R11.reset_aw"); 3:hit("R11.reset_w"); 4:hit("R11.reset_b");
        default:$fatal(1,"Invalid reset phase");
      endcase
    endfunction
    function void sample_start(logic [31:0] src, dst, len, bit irq_en);
      starts++; irq_enable=irq_en;
      transfer_src=src; transfer_dst=dst; transfer_len=len;
      read_response_index=0; write_response_index=0; transfer_open=1;
      src_aligned=(src[1:0]==0); dst_aligned=(dst[1:0]==0);
      if (len==0) len_bucket=0;
      else if (len==4) len_bucket=1;
      else if (len<=64) len_bucket=2;
      else if (len<=256) len_bucket=3;
      else len_bucket=4;
`ifdef ENABLE_SV_COV
      cg_transfer.sample();
`endif
    endfunction
    // Response index comes from observed handshakes, never injected address or
    // test name. Positions are exclusive; "middle" excludes first and last.
    function void sample_bus_response(bit write_response, logic [1:0] resp,
                                      logic last=1'b1);
      int unsigned response_index;
      string direction, position;
      response_index=write_response ? write_response_index : read_response_index;
      direction=write_response ? "write" : "read";
      if (write_response) write_response_index++;
      else begin read_response_index++; read_beats++; end
      if (resp===2'b00 && (write_response || last===1'b1))
        hit({"R02.",direction,"_response_okay"});
      if (transfer_open && transfer_len>=4 && resp===2'b10 &&
          (write_response || last===1'b1)) begin
        if(response_index==0) position="first";
        else if(response_index==(transfer_len/4)-1) position="last";
        else if(response_index<(transfer_len/4)-1) position="middle";
        else return; // An unexpected excess response is a checker failure.
        hit({"R12.",direction,"_slverr_",position});
      end
    endfunction
    // The scoreboard calls this after terminal STATUS and whole-memory checking.
    // A failed run is excluded by the report merger, even if bins were sampled.
    function void sample_result(int unsigned code);
      longint unsigned src_end,dst_end;
      results++; error_code=code; transfer_open=0;
      src_end={1'b0,transfer_src}+{1'b0,transfer_len};
      dst_end={1'b0,transfer_dst}+{1'b0,transfer_len};
      if (code==0) begin
        successes++;
        case(transfer_len)
          4:hit("R01.copy_len_4"); 16:hit("R01.copy_len_16");
          64:hit("R01.copy_len_64"); 128:hit("R01.copy_len_128");
          512:hit("R01.copy_len_512");
          default:; // Other legal lengths remain checked but not separate bins.
        endcase
        if(src_end==65536) hit("R06.src_end_of_memory");
        if(dst_end==65536) hit("R06.dst_end_of_memory");
        if(transfer_len!=0 && (transfer_src/4096)!=((src_end-1)/4096))
          hit("R06.src_page_cross");
        if(transfer_len!=0 && (transfer_dst/4096)!=((dst_end-1)/4096))
          hit("R06.dst_page_cross");
        if(irq_enable) hit("R08.success_irq_enabled");
        else hit("R08.success_irq_masked");
        if(previous_error) hit("R09.recovery_after_error");
        if(awaiting_reset_recovery) begin
          hit("R11.recovery_after_reset"); awaiting_reset_recovery=0;
        end
      end else if (code<=8) errors[code]++;
      if(code==1 && transfer_len==0) hit("R05.zero_length");
      if(code==2) begin
        if(transfer_src[1:0]!=0) hit("R05.unaligned_src");
        if(transfer_dst[1:0]!=0) hit("R05.unaligned_dst");
        if(transfer_len[1:0]!=0) hit("R05.unaligned_len");
      end
      if(code==3) begin
        if(src_end>65536) hit("R06.src_range_error");
        if(dst_end>65536) hit("R06.dst_range_error");
        if(src_end>64'hffffffff || dst_end>64'hffffffff)
          hit("R06.address_sum_overflow");
      end
      previous_error=(code!=0);
`ifdef ENABLE_SV_COV
      cg_result.sample();
`endif
    endfunction
    // Simple, deterministic TSV keeps old simulator runtimes compatible.
    // The catalog supplies descriptions, requirement IDs and explicit exclusions.
    function bit write_report();
      string path;
      int fd;
      if (!$value$plusargs("COVERAGE_FILE=%s",path)) return 1;
      fd=$fopen(path,"w");
      if(fd==0) return 0;
      $fdisplay(fd,"bin\thits");
      for(int i=0;i<bin_count;i++) $fdisplay(fd,"%s\t%0d",bin_names[i],bin_hits[i]);
      $fclose(fd);
      return 1;
    endfunction
  endclass
endpackage
