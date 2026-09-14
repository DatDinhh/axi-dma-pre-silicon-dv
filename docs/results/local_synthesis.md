# Synthesis sanity review

I retain this sanitized report as a record of the measured run. Paths are portable aliases; see the [evidence notes](README.md) for source and hash scope.

Quartus Prime Standard 20.1.1 Analysis & Synthesis completed on an exact copy of the four RTL files. The selected target was Cyclone V 5CSEMA5F31C6; no source transformation or RTL edits were used.

Result: PASS, zero errors, 67 warnings. All warning codes were reviewed:

- 10762, 3 occurrences: the compiler cannot enumerate all values of a 32-bit CSR address case. All three case statements have explicit default branches (register decode, register write, register read).
- 13024, 1 summary, and 13410, 54 child occurrences: constant output bits. These are response low bits for OKAY/SLVERR and fixed AXI ID/length/size/burst/lock/cache/protection/QoS fields. The implemented subset is single-beat fullword INCR, ID zero.
- 21074, 1 summary, and 15610, 8 child occurrences: unused input bits. AXI-Lite AWPROT/ARPROT (six bits) and incoming AXI BID/RID (one bit each) do not influence RTL. The baseline environment returns ID zero and the scoreboard checks response IDs.

The log and synthesis report contain no reported inferred-latch, multiple-driver, undriven-net, or combinational-loop finding. This is a statement about tool diagnostics; it is not a formal proof of their absence.

Map estimates: 319 ALMs, 434 combinational ALUTs, 424 registers, zero block RAM bits, zero DSP blocks. These numbers are for this selected target and synthesis run only. No fitter, physical timing analysis, or timing closure was run.

The independent Yosys 0.33 native SystemVerilog parser rejected the unchanged package's `timeunit` declaration before elaboration. That attempt is preserved in `yosys_native_parser.log` and does not count as a passed check.

Reproduce from repository root: `python scripts/check_synthesis.py`. Default timeout is 180 seconds and parallelism is limited to two jobs. I preserve the original source hashes and result metadata in the accompanying JSON; the runner produces the full logs and vendor report when rerun.
