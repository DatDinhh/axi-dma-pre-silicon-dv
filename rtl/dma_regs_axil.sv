//==============================================================================
// rtl/dma_regs_axil.sv (cleaned for Intel ModelSim)
//------------------------------------------------------------------------------
// AXI4-Lite slave register block for DMA (Spec v0.1)
// - No `default_nettype directives (ModelSim-ASE compatibility)
//==============================================================================

`ifndef DMA_REGS_AXIL_SV
`define DMA_REGS_AXIL_SV

module dma_regs_axil #(
  parameter int unsigned ADDR_WIDTH = 32,
  parameter int unsigned DATA_WIDTH = 32,
  parameter bit          ENABLE_BYTES_REMAIN = 1'b1
)(
  input  logic                         clk,
  input  logic                         rst_n,

  // AXI4-Lite slave interface
  input  logic [ADDR_WIDTH-1:0]        s_axil_awaddr,
  input  logic [2:0]                   s_axil_awprot,
  input  logic                         s_axil_awvalid,
  output logic                         s_axil_awready,

  input  logic [DATA_WIDTH-1:0]        s_axil_wdata,
  input  logic [(DATA_WIDTH/8)-1:0]    s_axil_wstrb,
  input  logic                         s_axil_wvalid,
  output logic                         s_axil_wready,

  output logic [1:0]                   s_axil_bresp,
  output logic                         s_axil_bvalid,
  input  logic                         s_axil_bready,

  input  logic [ADDR_WIDTH-1:0]        s_axil_araddr,
  input  logic [2:0]                   s_axil_arprot,
  input  logic                         s_axil_arvalid,
  output logic                         s_axil_arready,

  output logic [DATA_WIDTH-1:0]        s_axil_rdata,
  output logic [1:0]                   s_axil_rresp,
  output logic                         s_axil_rvalid,
  input  logic                         s_axil_rready,

  // Config outputs to engine
  output logic [ADDR_WIDTH-1:0]        cfg_src_addr,
  output logic [ADDR_WIDTH-1:0]        cfg_dst_addr,
  output logic [31:0]                  cfg_len_bytes,
  output logic                         cfg_irq_en,
  output logic                         start_req_pulse,

  // Status/event inputs from engine
  input  logic                         engine_busy,
  input  logic [31:0]                  engine_bytes_remain,
  input  logic                         start_accept_pulse,
  input  logic                         set_done_pulse,
  input  logic                         set_err_pulse,
  input  logic [7:0]                   err_code_value,

  // Sticky event outputs
  output logic                         sticky_done,
  output logic                         sticky_err
);

  import dma_pkg::*;

  localparam int unsigned STRB_WIDTH = (DATA_WIDTH/8);
  localparam int unsigned ALIGN_LSB  = $clog2(STRB_WIDTH);

  localparam logic [1:0] AXIL_OKAY   = 2'b00;
  localparam logic [1:0] AXIL_SLVERR = 2'b10;

  localparam logic [STRB_WIDTH-1:0] FULL_WSTRB = {STRB_WIDTH{1'b1}};

  // Write capture
  logic [ADDR_WIDTH-1:0] awaddr_lat;
  logic                  aw_captured;

  logic [DATA_WIDTH-1:0] wdata_lat;
  logic [STRB_WIDTH-1:0] wstrb_lat;
  logic                  w_captured;

  // Responses
  logic [1:0]            bresp_r;
  logic                  bvalid_r;

  logic [DATA_WIDTH-1:0] rdata_r;
  logic [1:0]            rresp_r;
  logic                  rvalid_r;

  // Register file
  logic [ADDR_WIDTH-1:0] reg_src_addr;
  logic [ADDR_WIDTH-1:0] reg_dst_addr;
  logic [31:0]           reg_len_bytes;
  logic                  reg_irq_en;

  logic                  sticky_done_r;
  logic                  sticky_err_r;
  err_code_t             reg_err_code;

  // Pulses
  logic start_pulse_r, clr_done_pulse_r, clr_err_pulse_r;
  logic irqstat_clr_done_r, irqstat_clr_err_r;

  // Outputs
  assign cfg_src_addr      = reg_src_addr;
  assign cfg_dst_addr      = reg_dst_addr;
  assign cfg_len_bytes     = reg_len_bytes;
  assign cfg_irq_en        = reg_irq_en;
  assign start_req_pulse   = start_pulse_r;

  assign sticky_done       = sticky_done_r;
  assign sticky_err        = sticky_err_r;

  assign s_axil_bresp      = bresp_r;
  assign s_axil_bvalid     = bvalid_r;

  assign s_axil_rdata      = rdata_r;
  assign s_axil_rresp      = rresp_r;
  assign s_axil_rvalid     = rvalid_r;

  // Ready generation
  assign s_axil_awready = rst_n && (!bvalid_r) && (!aw_captured);
  assign s_axil_wready  = rst_n && (!bvalid_r) && (!w_captured);
  assign s_axil_arready = rst_n && (!rvalid_r);

  function automatic bit addr_aligned(input logic [ADDR_WIDTH-1:0] a);
    if (ALIGN_LSB == 0) return 1'b1;
    return (a[ALIGN_LSB-1:0] == '0);
  endfunction

  function automatic bit is_known_offset(input logic [31:0] off);
    case (off)
      REG_OFF_CTRL,
      REG_OFF_SRC_ADDR,
      REG_OFF_DST_ADDR,
      REG_OFF_LEN,
      REG_OFF_STATUS,
      REG_OFF_IRQ_STATUS,
      REG_OFF_ERR_CODE,
      REG_OFF_BYTES_REMAIN: is_known_offset = 1'b1;
      default:              is_known_offset = 1'b0;
    endcase
  endfunction

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      awaddr_lat   <= '0;
      aw_captured  <= 1'b0;
      wdata_lat    <= '0;
      wstrb_lat    <= '0;
      w_captured   <= 1'b0;

      bresp_r      <= AXIL_OKAY;
      bvalid_r     <= 1'b0;

      rdata_r      <= '0;
      rresp_r      <= AXIL_OKAY;
      rvalid_r     <= 1'b0;

      reg_src_addr <= '0;
      reg_dst_addr <= '0;
      reg_len_bytes<= 32'd0;
      reg_irq_en   <= 1'b0;

      sticky_done_r<= 1'b0;
      sticky_err_r <= 1'b0;
      reg_err_code <= ERR_NONE;

      start_pulse_r      <= 1'b0;
      clr_done_pulse_r   <= 1'b0;
      clr_err_pulse_r    <= 1'b0;
      irqstat_clr_done_r <= 1'b0;
      irqstat_clr_err_r  <= 1'b0;

    end else begin
      // default pulses low
      start_pulse_r      <= 1'b0;
      clr_done_pulse_r   <= 1'b0;
      clr_err_pulse_r    <= 1'b0;
      irqstat_clr_done_r <= 1'b0;
      irqstat_clr_err_r  <= 1'b0;

      // Capture AW/W independently
      if (s_axil_awvalid && s_axil_awready) begin
        awaddr_lat  <= s_axil_awaddr;
        aw_captured <= 1'b1;
      end

      if (s_axil_wvalid && s_axil_wready) begin
        wdata_lat   <= s_axil_wdata;
        wstrb_lat   <= s_axil_wstrb;
        w_captured  <= 1'b1;
      end

      // Commit write when both captured
      begin
        logic aw_fire, w_fire, do_commit;
        logic [ADDR_WIDTH-1:0] addr_eff;
        logic [DATA_WIDTH-1:0] data_eff;
        logic [STRB_WIDTH-1:0] strb_eff;

        logic [31:0] off32;
        bit align_ok, strobe_ok, off_ok;

        aw_fire   = (s_axil_awvalid && s_axil_awready);
        w_fire    = (s_axil_wvalid  && s_axil_wready);
        do_commit = (!bvalid_r) && ((aw_captured || aw_fire) && (w_captured || w_fire));

        addr_eff = aw_fire ? s_axil_awaddr : awaddr_lat;
        data_eff = w_fire  ? s_axil_wdata  : wdata_lat;
        strb_eff = w_fire  ? s_axil_wstrb  : wstrb_lat;

        off32    = addr_eff[31:0];
        align_ok = addr_aligned(addr_eff);
        strobe_ok= (strb_eff == FULL_WSTRB);
        off_ok   = is_known_offset(off32);

        if (do_commit) begin
          bresp_r <= AXIL_OKAY;

          aw_captured <= 1'b0;
          w_captured  <= 1'b0;

          if (!align_ok) begin
            bresp_r <= AXIL_SLVERR;
          end else if (!strobe_ok) begin
            bresp_r <= AXIL_SLVERR;
          end else if (!off_ok) begin
            bresp_r <= AXIL_SLVERR;
          end else begin
            case (off32)
              REG_OFF_CTRL: begin
                reg_irq_en <= data_eff[CTRL_IRQ_EN_BIT];
                if (data_eff[CTRL_START_BIT])    start_pulse_r    <= 1'b1;
                if (data_eff[CTRL_CLR_DONE_BIT]) clr_done_pulse_r <= 1'b1;
                if (data_eff[CTRL_CLR_ERR_BIT])  clr_err_pulse_r  <= 1'b1;
              end
              REG_OFF_SRC_ADDR: reg_src_addr  <= addr_t'(data_eff);
              REG_OFF_DST_ADDR: reg_dst_addr  <= addr_t'(data_eff);
              REG_OFF_LEN:      reg_len_bytes <= data_eff[31:0];
              REG_OFF_IRQ_STATUS: begin
                if (data_eff[IRQSTAT_DONE_BIT]) irqstat_clr_done_r <= 1'b1;
                if (data_eff[IRQSTAT_ERR_BIT])  irqstat_clr_err_r  <= 1'b1;
              end
              default: begin
                // RO writes ignored
              end
            endcase
          end

          bvalid_r <= 1'b1;
        end
      end

      // B handshake
      if (bvalid_r && s_axil_bready) begin
        bvalid_r <= 1'b0;
      end

      // Read accept -> response
      if (s_axil_arvalid && s_axil_arready) begin
        logic [31:0] off32;
        bit align_ok, off_ok;

        off32    = s_axil_araddr[31:0];
        align_ok = addr_aligned(s_axil_araddr);
        off_ok   = is_known_offset(off32);

        rdata_r <= '0;
        rresp_r <= AXIL_OKAY;

        if (!align_ok || !off_ok) begin
          rresp_r <= AXIL_SLVERR;
        end else begin
          case (off32)
            REG_OFF_CTRL: begin
              rdata_r <= '0;
              rdata_r[CTRL_IRQ_EN_BIT] <= reg_irq_en;
            end
            REG_OFF_SRC_ADDR: rdata_r <= data_t'(reg_src_addr);
            REG_OFF_DST_ADDR: rdata_r <= data_t'(reg_dst_addr);
            REG_OFF_LEN:      rdata_r <= data_t'(reg_len_bytes);
            REG_OFF_STATUS: begin
              rdata_r <= '0;
              rdata_r[STATUS_BUSY_BIT] <= engine_busy;
              rdata_r[STATUS_DONE_BIT] <= sticky_done_r;
              rdata_r[STATUS_ERR_BIT]  <= sticky_err_r;
            end
            REG_OFF_IRQ_STATUS: begin
              rdata_r <= '0;
              rdata_r[IRQSTAT_DONE_BIT] <= sticky_done_r;
              rdata_r[IRQSTAT_ERR_BIT]  <= sticky_err_r;
            end
            REG_OFF_ERR_CODE: begin
              rdata_r <= '0;
              rdata_r[7:0] <= reg_err_code;
            end
            REG_OFF_BYTES_REMAIN: begin
              rdata_r <= '0;
              if (ENABLE_BYTES_REMAIN) rdata_r <= data_t'(engine_bytes_remain);
            end
            default: begin
              rresp_r <= AXIL_SLVERR;
              rdata_r <= '0;
            end
          endcase
        end

        rvalid_r <= 1'b1;
      end

      // R handshake
      if (rvalid_r && s_axil_rready) begin
        rvalid_r <= 1'b0;
      end

      // Event logic
      if (start_accept_pulse) begin
        sticky_done_r <= 1'b0;
        sticky_err_r  <= 1'b0;
        reg_err_code  <= ERR_NONE;
      end

      if (clr_done_pulse_r) sticky_done_r <= 1'b0;
      if (clr_err_pulse_r)  begin
        sticky_err_r <= 1'b0;
        reg_err_code <= ERR_NONE;
      end

      if (irqstat_clr_done_r) sticky_done_r <= 1'b0;
      if (irqstat_clr_err_r)  sticky_err_r  <= 1'b0;

      if (set_done_pulse) sticky_done_r <= 1'b1;
      if (set_err_pulse) begin
        sticky_err_r <= 1'b1;
        reg_err_code <= err_code_t'(err_code_value);
      end
    end
  end

endmodule

`endif // DMA_REGS_AXIL_SV
