# Observed requirement coverage: CLOSED

I retain this sanitized report as a record of the measured run. Paths are portable aliases; see the [evidence notes](README.md) for source and hash scope.

70/70 required bins hit (100.0%).

Finite observed requirement-bin coverage only; not native covergroup, RTL code, assertion coverage, or proof of universal correctness.

Accepted runs: 39. All listed runs passed; no failed run or retry was discarded.

Frozen source SHA-256 signature: `851d564c1295a8577f4daf4c8248f888eb13d08aadf3c263a77ebaddae1a531b`

Missing required bins: none.

| Bin | Requirement | Hits | Evidence |
| --- | --- | ---: | --- |
| R01.copy_len_4 | R01 | 12 | run-19, run-20, run-21, run-22, run-23, run-24 |
| R01.copy_len_16 | R01 | 42 | run-19, run-20, run-21, run-22, run-23, run-24, run-25, run-26, run-27, run-28, run-29, run-30, run-34, run-35, run-36, run-37, run-38, run-39 |
| R01.copy_len_64 | R01 | 3 | run-1, run-2, run-3 |
| R01.copy_len_128 | R01 | 3 | run-4, run-5, run-6 |
| R01.copy_len_512 | R01 | 4 | run-25, run-26, run-27, run-33 |
| R02.read_response_okay | R02 | 7135 | run-1, run-2, run-3, run-4, run-5, run-6, run-19, run-20, run-21, run-22, run-23, run-24, run-25, run-26, run-27, run-28, run-29, run-30, run-31, run-32, run-33, run-34, run-35, run-36, run-37, run-38, run-39 |
| R02.write_response_okay | R02 | 7117 | run-1, run-2, run-3, run-4, run-5, run-6, run-19, run-20, run-21, run-22, run-23, run-24, run-25, run-26, run-27, run-28, run-29, run-30, run-31, run-32, run-33, run-34, run-35, run-36, run-37, run-38, run-39 |
| R03.axi_ar_stall | R03 | 23859 | run-1, run-2, run-3, run-4, run-5, run-6, run-19, run-20, run-21, run-22, run-23, run-24, run-25, run-26, run-27, run-28, run-29, run-30, run-31, run-32, run-33, run-34, run-35, run-36, run-37, run-38, run-39 |
| R03.axi_aw_stall | R03 | 23431 | run-1, run-2, run-3, run-4, run-5, run-6, run-19, run-20, run-21, run-22, run-23, run-24, run-25, run-26, run-27, run-28, run-29, run-30, run-31, run-32, run-33, run-34, run-35, run-36, run-37, run-38, run-39 |
| R03.axi_w_stall | R03 | 53983 | run-1, run-2, run-3, run-4, run-5, run-6, run-19, run-20, run-21, run-22, run-23, run-24, run-25, run-26, run-27, run-28, run-29, run-30, run-31, run-32, run-33, run-34, run-35, run-36, run-37, run-38, run-39 |
| R03.axil_r_stall | R03 | 45 | run-16, run-17, run-18 |
| R03.axil_b_stall | R03 | 45 | run-16, run-17, run-18 |
| R04.wvalid_before_aw_accept | R04 | 23431 | run-1, run-2, run-3, run-4, run-5, run-6, run-19, run-20, run-21, run-22, run-23, run-24, run-25, run-26, run-27, run-28, run-29, run-30, run-31, run-32, run-33, run-34, run-35, run-36, run-37, run-38, run-39 |
| R05.zero_length | R05 | 6 | run-7, run-8, run-9, run-22, run-23, run-24 |
| R05.unaligned_src | R05 | 3 | run-10, run-11, run-12 |
| R05.unaligned_dst | R05 | 3 | run-19, run-20, run-21 |
| R05.unaligned_len | R05 | 9 | run-19, run-20, run-21 |
| R06.src_range_error | R06 | 12 | run-13, run-14, run-15, run-19, run-20, run-21 |
| R06.src_end_of_memory | R06 | 3 | run-19, run-20, run-21 |
| R06.src_page_cross | R06 | 8 | run-19, run-20, run-21, run-31, run-32, run-33 |
| R06.dst_range_error | R06 | 6 | run-19, run-20, run-21 |
| R06.dst_end_of_memory | R06 | 3 | run-19, run-20, run-21 |
| R06.dst_page_cross | R06 | 7 | run-19, run-20, run-21, run-31, run-32 |
| R06.address_sum_overflow | R06 | 6 | run-19, run-20, run-21 |
| R07.read_ctrl | R07 | 24 | run-16, run-17, run-18, run-28, run-29, run-30 |
| R07.read_src | R07 | 30 | run-16, run-17, run-18, run-28, run-29, run-30 |
| R07.read_dst | R07 | 18 | run-16, run-17, run-18, run-28, run-29, run-30 |
| R07.read_len | R07 | 18 | run-16, run-17, run-18, run-28, run-29, run-30 |
| R07.read_status | R07 | 58976 | run-1, run-2, run-3, run-4, run-5, run-6, run-7, run-8, run-9, run-10, run-11, run-12, run-13, run-14, run-15, run-16, run-17, run-18, run-19, run-20, run-21, run-22, run-23, run-24, run-25, run-26, run-27, run-28, run-29, run-30, run-31, run-32, run-33, run-34, run-35, run-36, run-37, run-38, run-39 |
| R07.read_irq_status | R07 | 240 | run-1, run-2, run-3, run-4, run-5, run-6, run-7, run-8, run-9, run-10, run-11, run-12, run-13, run-14, run-15, run-16, run-17, run-18, run-19, run-20, run-21, run-22, run-23, run-24, run-25, run-26, run-27, run-28, run-29, run-30, run-31, run-32, run-33, run-34, run-35, run-36, run-37, run-38, run-39 |
| R07.read_err_code | R07 | 309 | run-1, run-2, run-3, run-4, run-5, run-6, run-7, run-8, run-9, run-10, run-11, run-12, run-13, run-14, run-15, run-16, run-17, run-18, run-19, run-20, run-21, run-22, run-23, run-24, run-25, run-26, run-27, run-28, run-29, run-30, run-31, run-32, run-33, run-34, run-35, run-36, run-37, run-38, run-39 |
| R07.read_bytes_remain | R07 | 180 | run-1, run-2, run-3, run-4, run-5, run-6, run-16, run-17, run-18, run-19, run-20, run-21, run-22, run-23, run-24, run-25, run-26, run-27, run-28, run-29, run-30, run-31, run-32, run-33, run-34, run-35, run-36, run-37, run-38, run-39 |
| R07.write_ctrl | R07 | 285 | run-1, run-2, run-3, run-4, run-5, run-6, run-7, run-8, run-9, run-10, run-11, run-12, run-13, run-14, run-15, run-16, run-17, run-18, run-19, run-20, run-21, run-22, run-23, run-24, run-25, run-26, run-27, run-28, run-29, run-30, run-31, run-32, run-33, run-34, run-35, run-36, run-37, run-38, run-39 |
| R07.write_src | R07 | 240 | run-1, run-2, run-3, run-4, run-5, run-6, run-7, run-8, run-9, run-10, run-11, run-12, run-13, run-14, run-15, run-16, run-17, run-18, run-19, run-20, run-21, run-22, run-23, run-24, run-25, run-26, run-27, run-28, run-29, run-30, run-31, run-32, run-33, run-34, run-35, run-36, run-37, run-38, run-39 |
| R07.write_dst | R07 | 231 | run-1, run-2, run-3, run-4, run-5, run-6, run-7, run-8, run-9, run-10, run-11, run-12, run-13, run-14, run-15, run-19, run-20, run-21, run-22, run-23, run-24, run-25, run-26, run-27, run-28, run-29, run-30, run-31, run-32, run-33, run-34, run-35, run-36, run-37, run-38, run-39 |
| R07.write_len | R07 | 231 | run-1, run-2, run-3, run-4, run-5, run-6, run-7, run-8, run-9, run-10, run-11, run-12, run-13, run-14, run-15, run-19, run-20, run-21, run-22, run-23, run-24, run-25, run-26, run-27, run-28, run-29, run-30, run-31, run-32, run-33, run-34, run-35, run-36, run-37, run-38, run-39 |
| R07.write_irq_status | R07 | 249 | run-1, run-2, run-3, run-4, run-5, run-6, run-7, run-8, run-9, run-10, run-11, run-12, run-13, run-14, run-15, run-19, run-20, run-21, run-22, run-23, run-24, run-25, run-26, run-27, run-28, run-29, run-30, run-31, run-32, run-33, run-34, run-35, run-36, run-37, run-38, run-39 |
| R07.write_status | R07 | 3 | run-16, run-17, run-18 |
| R07.write_err_code | R07 | 3 | run-16, run-17, run-18 |
| R07.read_unaligned | R07 | 3 | run-16, run-17, run-18 |
| R07.read_unmapped | R07 | 3 | run-16, run-17, run-18 |
| R07.write_unaligned | R07 | 3 | run-16, run-17, run-18 |
| R07.write_unmapped | R07 | 3 | run-16, run-17, run-18 |
| R07.strobe_partial | R07 | 3 | run-16, run-17, run-18 |
| R07.strobe_zero | R07 | 3 | run-16, run-17, run-18 |
| R07.axil_aw_first | R07 | 3 | run-16, run-17, run-18 |
| R07.axil_w_first | R07 | 3 | run-16, run-17, run-18 |
| R07.axil_same_cycle | R07 | 1248 | run-1, run-2, run-3, run-4, run-5, run-6, run-7, run-8, run-9, run-10, run-11, run-12, run-13, run-14, run-15, run-16, run-17, run-18, run-19, run-20, run-21, run-22, run-23, run-24, run-25, run-26, run-27, run-28, run-29, run-30, run-31, run-32, run-33, run-34, run-35, run-36, run-37, run-38, run-39 |
| R08.success_irq_enabled | R08 | 115 | run-1, run-2, run-3, run-4, run-5, run-6, run-19, run-20, run-21, run-22, run-23, run-24, run-25, run-26, run-27, run-28, run-29, run-30, run-31, run-32, run-33, run-34, run-35, run-36, run-37, run-38, run-39 |
| R08.success_irq_masked | R08 | 47 | run-22, run-23, run-24, run-31, run-32, run-33 |
| R08.pending_masked | R08 | 50 | run-22, run-23, run-24, run-31, run-32, run-33 |
| R08.pending_asserted | R08 | 172 | run-1, run-2, run-3, run-4, run-5, run-6, run-7, run-8, run-9, run-10, run-11, run-12, run-13, run-14, run-15, run-19, run-20, run-21, run-22, run-23, run-24, run-25, run-26, run-27, run-28, run-29, run-30, run-31, run-32, run-33, run-34, run-35, run-36, run-37, run-38, run-39 |
| R08.w1c_done | R08 | 162 | run-1, run-2, run-3, run-4, run-5, run-6, run-19, run-20, run-21, run-22, run-23, run-24, run-25, run-26, run-27, run-28, run-29, run-30, run-31, run-32, run-33, run-34, run-35, run-36, run-37, run-38, run-39 |
| R08.w1c_err | R08 | 54 | run-7, run-8, run-9, run-10, run-11, run-12, run-13, run-14, run-15, run-19, run-20, run-21, run-22, run-23, run-24, run-34, run-35, run-36, run-37, run-38, run-39 |
| R08.ctrl_clear_err | R08 | 36 | run-7, run-8, run-9, run-10, run-11, run-12, run-13, run-14, run-15, run-19, run-20, run-21, run-22, run-23, run-24 |
| R09.done_and_err | R09 | 6 | run-22, run-23, run-24 |
| R09.recovery_after_error | R09 | 24 | run-19, run-20, run-21, run-22, run-23, run-24, run-34, run-35, run-36, run-37, run-38, run-39 |
| R10.busy_start | R10 | 3 | run-25, run-26, run-27 |
| R11.reset_ar | R11 | 3 | run-28, run-29, run-30 |
| R11.reset_r | R11 | 3 | run-28, run-29, run-30 |
| R11.reset_aw | R11 | 6 | run-28, run-29, run-30 |
| R11.reset_w | R11 | 6 | run-28, run-29, run-30 |
| R11.reset_b | R11 | 3 | run-28, run-29, run-30 |
| R11.recovery_after_reset | R11 | 15 | run-28, run-29, run-30 |
| R12.read_slverr_first | R12 | 3 | run-34, run-35, run-36 |
| R12.read_slverr_middle | R12 | 3 | run-34, run-35, run-36 |
| R12.read_slverr_last | R12 | 3 | run-34, run-35, run-36 |
| R12.write_slverr_first | R12 | 3 | run-37, run-38, run-39 |
| R12.write_slverr_middle | R12 | 3 | run-37, run-38, run-39 |
| R12.write_slverr_last | R12 | 3 | run-37, run-38, run-39 |

## Evidence index

| Evidence | Test | Seed | Configuration |
| --- | --- | ---: | --- |
| run-1 | smoke_test | 1 | `7c5840d03784` |
| run-2 | smoke_test | 7 | `a0162993f7e1` |
| run-3 | smoke_test | 42 | `9b19dd9f9043` |
| run-4 | copy_test | 1 | `b4919e4111e3` |
| run-5 | copy_test | 7 | `e7818d43e1db` |
| run-6 | copy_test | 42 | `9fba1ce91626` |
| run-7 | len_zero_test | 1 | `9c3e68ec16fc` |
| run-8 | len_zero_test | 7 | `5213d7630871` |
| run-9 | len_zero_test | 42 | `3ed32fea96dc` |
| run-10 | unaligned_addr_test | 1 | `b483f0a4013b` |
| run-11 | unaligned_addr_test | 7 | `c192519eb84d` |
| run-12 | unaligned_addr_test | 42 | `4ce600627085` |
| run-13 | out_of_range_test | 1 | `34e283c26565` |
| run-14 | out_of_range_test | 7 | `a7f207a6c1c1` |
| run-15 | out_of_range_test | 42 | `cce58025fab2` |
| run-16 | csr_access_test | 1 | `9e9fd7075d5f` |
| run-17 | csr_access_test | 7 | `14c9adac28ca` |
| run-18 | csr_access_test | 42 | `a1f9028ac1be` |
| run-19 | descriptor_corner_test | 1 | `608432b8be7d` |
| run-20 | descriptor_corner_test | 7 | `e5e6f8c5ed9c` |
| run-21 | descriptor_corner_test | 42 | `3e1ecf2edfa5` |
| run-22 | irq_test | 1 | `e9146b5a3b3d` |
| run-23 | irq_test | 7 | `e5cd865a74dd` |
| run-24 | irq_test | 42 | `bdeb97b78fcc` |
| run-25 | busy_start_test | 1 | `c9e25bbebe7d` |
| run-26 | busy_start_test | 7 | `0aa163b06013` |
| run-27 | busy_start_test | 42 | `41343091ff7d` |
| run-28 | reset_mid_transfer_test | 1 | `efbc99658ade` |
| run-29 | reset_mid_transfer_test | 7 | `a1feecfb374d` |
| run-30 | reset_mid_transfer_test | 42 | `ad7f197df564` |
| run-31 | seeded_copy_test | 1 | `0f69555b9ae8` |
| run-32 | seeded_copy_test | 7 | `deda54c84546` |
| run-33 | seeded_copy_test | 42 | `086e873b49cc` |
| run-34 | read_error_test | 1 | `a073b54e5d2a` |
| run-35 | read_error_test | 7 | `d732f1b615ca` |
| run-36 | read_error_test | 42 | `cca2db8f778f` |
| run-37 | write_error_test | 1 | `faf1fabad66c` |
| run-38 | write_error_test | 7 | `efef4805f8f2` |
| run-39 | write_error_test | 42 | `820ac084c640` |

Full arguments, paths, hashes, bin descriptions, and source identities are in coverage_summary.json.

## Explicit exclusions

- **AXI_R_B_VALID_BACKPRESSURE**: DMA consumes each R/B response in the corresponding response state; memory response latency does not by itself create VALID&&!READY. Request stalls and AXI-Lite response stalls are selected instead.
- **ALL_POSSIBLE_CROSSES**: No Cartesian product is claimed. The 70 named scenario bins are the reviewed finite baseline selection, not all descriptors, timing combinations, or cross coverage.
- **R13_R14_R16_R17_UNIT_REQUIREMENTS**: Malformed RLAST, responder internals, checker sensitivity, runner integrity and register event priority have separate unit-check evidence; they are not sampled by this integration catalog.
- **NATIVE_COVERGROUP_CODE_ASSERTION_COVERAGE**: Requires supported simulator runtime and separate saved coverage databases; optional native covergroups are diagnostic and not counted here.
- **DECERR_RESPONSE**: Baseline memory responder injects SLVERR only; DECERR response sweeps are not implemented and not claimed.
- **FULL_RESET_CSR_CROSS**: The selected reset bins observe five DMA AXI phases. Reset with split AXI-Lite requests or every CSR/software timing combination is outside this catalog.
- **UNSUPPORTED_DUT_FEATURES**: Multi-beat bursts, outstanding IDs, overlap/memmove, unaligned byte copies, scatter-gather, CDC, coherency and DUT-only reset are outside the baseline specification.
