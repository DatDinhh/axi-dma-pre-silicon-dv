# Simulator diagnostics

I keep tool capability and loader checks separate from DUT regressions. These
scripts help distinguish an environment failure from a design or checker failure.
Their results do not add cases or coverage to a passing DUT campaign.

## Legacy ModelSim loader study

`Compare-LegacyLoader.ps1` performs a fixed number of independent launches on a
copy of an existing compiled library. It alternates normal loading with
`vsim -nodpiexports` and retains every result in `study.json`.

```powershell
.\scripts\diagnostics\Compare-LegacyLoader.ps1 `
  -EvidenceDirectory .\output\uvm_<id> `
  -Repetitions 12
```

Replace `<id>` with a completed UVM run's identifier. The simulator is discovered
from PATH; `-VsimPath` can select an explicit executable. The diagnostic copies the
source manifest and leaves the original snapshot and work library unchanged.
Each launch has separate transcript, startup, stdout/stderr, and waveform files.
New studies use `output/loader-study-<id>/`.

### Failure and mitigation

I reproduced a startup SIGSEGV in `out_of_range_test`, seed 1, while ModelSim was
loading generated DPI export code, before time-zero UVM activity. Shortening
TEMP/TMP did not prevent the intermittent fault.

The tested UVM 1.2 library exports `m__uvm_report_dpi` even under `UVM_NO_DPI`.
This project has no C consumer of that function, but the export still triggers
wrapper generation and DLL loading. The tested ModelSim Intel FPGA Starter 2020.1
CLI documents `-nodpiexports` as a deprecated option to disable those wrappers.
The option retains SystemVerilog UVM reporting, agents, monitors, scoreboards,
and protocol checks.

The [fixed 12-pair study](../../docs/results/loader_ab_study.json) finished with
**11/12 normal trials passing and 12/12 no-export trials passing**. The failed
normal trial reported SIGSEGV while loading `vsim_auto_compile.dll`; every
no-export trial avoided the generated export DLLs. The earlier crash involved
`export_tramp.dll`. I treat these as evidence of a fault in the exercised export
loading path, not proof that both crashes occurred at the same instruction.

A preliminary three-pair study passed in both modes. Comparing their result,
scoreboard, coverage, and protocol-activity lines found matching behavior. I kept
that observation separate from the fixed follow-up study and the subsequent
[full UVM campaign](../../docs/validation.md).

### Runner behavior

The main runner supports `-DpiExportMode Auto|Enabled|Disabled`. `Auto` selects
`Disabled` only for the identified Windows ModelSim Intel FPGA Starter 2020.1
configuration and its `UVM_NO_DPI` build. Other versions retain their standard
export behavior. JSON records the resolved mode and reason; `Enabled` allows
the original loader path to be reproduced.

This mitigation depends on the current pure-SystemVerilog environment. Future
C/C++ callbacks into exported SystemVerilog functions would require the export
path and an appropriate simulator. A finite passing study does not establish
that an internal simulator defect has been repaired.

## Verilator capability probe

`tool_probe_verilator.sh` builds a small assertion/coverage probe independently
of the DMA. The [recorded tool results](../../docs/results/tool_capabilities.json)
show the observed capabilities of the tested installation. The probe establishes
that a feature executes; the separate
[local DUT campaign](../../docs/local_validation.md) provides design evidence.
