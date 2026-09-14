# Local native Verilator coverage

I retain this sanitized report as a record of the measured run. Paths are portable aliases; see the [evidence notes](README.md) for source and hash scope.

Only rtl/ files in the simulated top_soc_dut elaboration

Each column uses its own instrumented-point denominator; no exclusions are subtracted.

| RTL file | Line/block points | Branch outcomes | Toggle points |
| --- | ---: | ---: | ---: |
| rtl/dma_engine_axi.sv | 18/20 (90.00%) | 23/26 (88.46%) | 271/455 (59.56%) |
| rtl/dma_regs_axil.sv | 22/24 (91.67%) | 42/44 (95.45%) | 459/518 (88.61%) |
| rtl/top_soc_dut.sv | not instrumented | not instrumented | 368/501 (73.45%) |
| TOTAL | 40/44 (90.91%) | 65/70 (92.86%) | 1098/1474 (74.49%) |

## Concurrent assertion activation

Native cover properties below are collected during passing DUT runs only.

| Property instance | Hits |
| --- | ---: |
| TOP.dma_local_test.checks.c_axi_aw_valid | 116638 |
| TOP.dma_local_test.checks.c_axi_w_valid | 233246 |
| TOP.dma_local_test.checks.c_axi_b_valid | 27038 |
| TOP.dma_local_test.checks.c_axi_ar_valid | 122541 |
| TOP.dma_local_test.checks.c_axi_r_valid | 27056 |
| TOP.dma_local_test.checks.c_axil_b_valid | 3057 |
| TOP.dma_local_test.checks.c_axil_r_valid | 228851 |
| TOP.dma_local_test.checks.lr.c_handshake | 228806 |
| TOP.dma_local_test.checks.lar.c_handshake | 228806 |
| TOP.dma_local_test.checks.law.c_handshake | 3012 |
| TOP.dma_local_test.checks.r.c_handshake | 27056 |
| TOP.dma_local_test.checks.lw.c_handshake | 3012 |
| TOP.dma_local_test.checks.w.c_handshake | 27041 |
| TOP.dma_local_test.checks.lb.c_handshake | 3012 |
| TOP.dma_local_test.checks.b.c_handshake | 27038 |
| TOP.dma_local_test.checks.aw.c_handshake | 27044 |
| TOP.dma_local_test.checks.ar.c_handshake | 27059 |
| TOP.dma_local_test.checks.lr.c_stall | 45 |
| TOP.dma_local_test.checks.lar.c_stall | 0 |
| TOP.dma_local_test.checks.law.c_stall | 0 |
| TOP.dma_local_test.checks.r.c_stall | 0 |
| TOP.dma_local_test.checks.lw.c_stall | 0 |
| TOP.dma_local_test.checks.w.c_stall | 206205 |
| TOP.dma_local_test.checks.lb.c_stall | 45 |
| TOP.dma_local_test.checks.b.c_stall | 0 |
| TOP.dma_local_test.checks.aw.c_stall | 89594 |
| TOP.dma_local_test.checks.ar.c_stall | 95482 |
| TOP.dma_local_test.checks.lr.c_stall_release | 9 |
| TOP.dma_local_test.checks.lar.c_stall_release | 0 |
| TOP.dma_local_test.checks.law.c_stall_release | 0 |
| TOP.dma_local_test.checks.r.c_stall_release | 0 |
| TOP.dma_local_test.checks.lw.c_stall_release | 0 |
| TOP.dma_local_test.checks.w.c_stall_release | 27041 |
| TOP.dma_local_test.checks.lb.c_stall_release | 9 |
| TOP.dma_local_test.checks.b.c_stall_release | 0 |
| TOP.dma_local_test.checks.aw.c_stall_release | 22370 |
| TOP.dma_local_test.checks.ar.c_stall_release | 23843 |

## Limits

- Percentages count Verilator-instrumented points, not every textual HDL line.
- Line/block, branch outcomes, toggles and cover-property activation have different denominators.
- Testbench/interface/responder counters are excluded from RTL totals.
- Verilator is a predominantly two-state simulator; this lane does not verify X/Z behavior.
- Cover-property hits show exercised scenarios, not formal proof or native covergroup closure.
- The optional LCOV export merges coverage types by source line and is a lossy projection.
