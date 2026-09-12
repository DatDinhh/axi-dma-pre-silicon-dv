//============================================================
// tb/coverage/dma_cov.sv
// Lightweight functional coverage model for AXI DMA project.
//
// IMPORTANT (ModelSim Intel FPGA Edition friendliness):
//   - By default, this file compiles in "stub mode" (no covergroups),
//     so ModelSim won't choke on coverage features.
//   - To enable real SystemVerilog functional coverage (covergroups),
//     compile with: +define+ENABLE_SV_COV
//     (Recommended only when using Questa or a simulator with SV coverage support.)
//
// Integration (later):
//   - Import dma_cov_pkg::*
//   - Create dma_cov handle and call sample_*() from tb_pkg tasks/tests
//============================================================

`timescale 1ns/1ps
`default_nettype none

package dma_cov_pkg;

  // Import design constants if present (not required for stub mode)
  import dma_pkg::*;

  // -----------------------------
  // Simple register decode helper
  // -----------------------------
  typedef enum int unsigned {
    REG_UNKNOWN     = 0,
    REG_SRC_ADDR    = 1,
    REG_DST_ADDR    = 2,
    REG_LEN_BYTES   = 3,
    REG_CTRL        = 4,
    REG_STATUS      = 5,
    REG_IRQ_ENABLE  = 6,
    REG_IRQ_STATUS  = 7,
    REG_ERR_CODE    = 8,
    REG_BYTES_REMAIN= 9
  } reg_id_e;

  // NOTE: This assumes the canonical reg map offsets used in this repo.
  // If you change the reg map, update this decode function accordingly.
  function automatic reg_id_e decode_reg_id(input logic [31:0] addr);
    logic [7:0] off;
    off = addr[7:0];
    unique case (off)
      8'h00: return REG_SRC_ADDR;
      8'h04: return REG_DST_ADDR;
      8'h08: return REG_LEN_BYTES;
      8'h0C: return REG_CTRL;
      8'h10: return REG_STATUS;
      8'h14: return REG_IRQ_ENABLE;
      8'h18: return REG_IRQ_STATUS;
      8'h1C: return REG_ERR_CODE;
      8'h20: return REG_BYTES_REMAIN;
      default: return REG_UNKNOWN;
    endcase
  endfunction

  //============================================================
  // dma_cov class (two-mode):
  //   - ENABLE_SV_COV: covergroups enabled
  //   - else: stub (no-op sampling functions)
  //============================================================

`ifdef ENABLE_SV_COV

  class dma_cov;

    // -----------------------------
    // State captured for sampling
    // -----------------------------
    string         name;

    // Reg access sampling
    reg_id_e       reg_id;
    bit            reg_is_write;

    // Start sampling (captured at DMA start)
    int unsigned   start_len;
    bit            src_aligned;
    bit            dst_aligned;
    bit            irq_done_en;
    bit            irq_err_en;

    // Result sampling (captured at completion)
    bit            status_done;
    bit            status_err;
    bit            status_busy;

    bit            irqstat_done;
    bit            irqstat_err;

    int unsigned   result_err_code;

    // -----------------------------
    // Covergroups
    // -----------------------------

    // Register access coverage (read/write to each key register)
    covergroup cg_reg_access;
      option.per_instance = 1;

      cp_reg: coverpoint reg_id {
        bins src      = {REG_SRC_ADDR};
        bins dst      = {REG_DST_ADDR};
        bins len      = {REG_LEN_BYTES};
        bins ctrl     = {REG_CTRL};
        bins status   = {REG_STATUS};
        bins irq_en   = {REG_IRQ_ENABLE};
        bins irq_stat = {REG_IRQ_STATUS};
        bins err_code = {REG_ERR_CODE};
        bins bytes_rm = {REG_BYTES_REMAIN};
        bins unknown  = {REG_UNKNOWN};
      }

      cp_rw: coverpoint reg_is_write {
        bins rd = {0};
        bins wr = {1};
      }

      x_reg_rw: cross cp_reg, cp_rw;
    endgroup

    // DMA start coverage (LEN bins, alignment bins, irq enable bins)
    covergroup cg_start;
      option.per_instance = 1;

      cp_len: coverpoint start_len {
        bins len0     = {0};
        bins len1_3   = {[1:3]};
        bins len4     = {4};
        bins len8     = {8};
        bins len16    = {16};
        bins len64    = {64};
        bins len128   = {128};
        bins len256p  = {[256:$]};
        bins other    = default;
      }

      cp_src_aligned: coverpoint src_aligned { bins aligned={1}; bins misaligned={0}; }
      cp_dst_aligned: coverpoint dst_aligned { bins aligned={1}; bins misaligned={0}; }

      cp_irq_done_en: coverpoint irq_done_en { bins off={0}; bins on={1}; }
      cp_irq_err_en : coverpoint irq_err_en  { bins off={0}; bins on={1}; }

      x_align: cross cp_src_aligned, cp_dst_aligned;
      x_len_irq: cross cp_len, cp_irq_done_en, cp_irq_err_en;
    endgroup

    // DMA result coverage (DONE vs ERR, err_code bins, irq_status bins)
    covergroup cg_result;
      option.per_instance = 1;

      // Outcome encoding: {ERR, DONE}
      cp_outcome: coverpoint {status_err, status_done} {
        bins none = {2'b00};  // (should not be sampled at completion, but safe)
        bins done = {2'b01};
        bins err  = {2'b10};
        illegal_bins both = {2'b11}; // should never be both
      }

      // IRQ cause encoding: {ERR, DONE}
      cp_irqcause: coverpoint {irqstat_err, irqstat_done} {
        bins none = {2'b00};
        bins done = {2'b01};
        bins err  = {2'b10};
        illegal_bins both = {2'b11};
      }

      // Error code bins (numeric mapping used in this repo):
      //  0: none, 1: LEN0, 2: ALIGN, 3: RANGE
      cp_err_code: coverpoint result_err_code {
        bins none  = {0};
        bins len0  = {1};
        bins align = {2};
        bins range = {3};
        bins other = default; // reserved/future (e.g., BUSY)
      }

      // Cross: what LEN led to what outcome / error
      x_len_outcome: cross start_len, cp_outcome;
      x_len_err    : cross start_len, cp_err_code;
    endgroup

    // -----------------------------
    // Constructor
    // -----------------------------
    function new(string name = "dma_cov");
      this.name = name;

      cg_reg_access = new();
      cg_start      = new();
      cg_result     = new();
    endfunction

    // -----------------------------
    // Sampling APIs
    // -----------------------------

    // Call on AXI-Lite write (addr/data are included for future expansion)
    function void sample_reg_write(input logic [31:0] addr, input logic [31:0] data);
      reg_id       = decode_reg_id(addr);
      reg_is_write = 1'b1;
      cg_reg_access.sample();
    endfunction

    // Call on AXI-Lite read (addr/data are included for future expansion)
    function void sample_reg_read(input logic [31:0] addr, input logic [31:0] data);
      reg_id       = decode_reg_id(addr);
      reg_is_write = 1'b0;
      cg_reg_access.sample();
    endfunction

    // Call when DMA START is issued/accepted
    function void sample_start_evt(
      input logic [31:0] src,
      input logic [31:0] dst,
      input logic [31:0] len_bytes,
      input bit          irq_done_enable,
      input bit          irq_err_enable
    );
      start_len   = len_bytes;
      src_aligned = ((src & 32'h3) == 32'h0);
      dst_aligned = ((dst & 32'h3) == 32'h0);
      irq_done_en = irq_done_enable;
      irq_err_en  = irq_err_enable;
      cg_start.sample();
    endfunction

    // Call at completion / observation point (after DONE or ERR)
    function void sample_result_evt(
      input logic [31:0] status,
      input logic [31:0] irq_status,
      input logic [31:0] err_code
    );
      // Bit mapping used in this repo:
      // STATUS: [0]=BUSY, [1]=DONE, [2]=ERR
      status_busy = status[0];
      status_done = status[1];
      status_err  = status[2];

      // IRQ_STATUS: [0]=DONE, [1]=ERR
      irqstat_done = irq_status[0];
      irqstat_err  = irq_status[1];

      result_err_code = err_code;

      cg_result.sample();
    endfunction

  endclass

`else  // ------------------ STUB MODE (no covergroups) ------------------

  class dma_cov;

    function new(string name = "dma_cov");
      // no-op
    endfunction

    function void sample_reg_write(input logic [31:0] addr, input logic [31:0] data);
      // no-op
    endfunction

    function void sample_reg_read(input logic [31:0] addr, input logic [31:0] data);
      // no-op
    endfunction

    function void sample_start_evt(
      input logic [31:0] src,
      input logic [31:0] dst,
      input logic [31:0] len_bytes,
      input bit          irq_done_enable,
      input bit          irq_err_enable
    );
      // no-op
    endfunction

    function void sample_result_evt(
      input logic [31:0] status,
      input logic [31:0] irq_status,
      input logic [31:0] err_code
    );
      // no-op
    endfunction

  endclass

`endif

endpackage : dma_cov_pkg

`default_nettype wire
