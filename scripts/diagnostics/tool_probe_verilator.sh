#!/bin/sh
set -eu
probe_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$probe_root"
mkdir -p "$probe_root/out"
probe_dir=$(mktemp -d "$probe_root/out/tool_probe_verilator_XXXXXXXXXXXX")
printf '%s\n' "$probe_dir"
verilator --version > "$probe_dir/version.txt"
timeout 120 verilator --cc --exe --build --timing --assert --coverage-line --coverage-user -Wno-fatal --top-module tool_probe_assertion --Mdir "$probe_dir/assert_obj" "$probe_root/scripts/diagnostics/tool_probe_assertion.sv" "$probe_root/scripts/diagnostics/tool_probe_main.cpp" > "$probe_dir/assert_build.log" 2>&1
cd "$probe_dir"
timeout 15 "$probe_dir/assert_obj/Vtool_probe_assertion" > "$probe_dir/assert_run.log" 2>&1
cat "$probe_dir/assert_run.log"
grep -q TOOL_PROBE_ASSERTION_PASS "$probe_dir/assert_run.log"
test -s coverage.dat
set +e
(ulimit -c 0; timeout 15 "$probe_dir/assert_obj/Vtool_probe_assertion" +VIOLATE) > "$probe_dir/assert_negative.log" 2>&1
negative_exit=$?
set -e
printf 'Intentional assertion violation exit: %s\n' "$negative_exit"
cat "$probe_dir/assert_negative.log"
if [ "$negative_exit" -eq 0 ]; then exit 1; fi
grep -q TOOL_PROBE_SVA_DETECTED "$probe_dir/assert_negative.log"
verilator_coverage --write-info coverage.info coverage.dat
verilator_coverage --annotate annotation --annotate-min 1 coverage.dat > coverage_summary.txt
cat coverage_summary.txt
if verilator --lint-only --timing --assert --top-module covergroup_probe "$probe_root/scripts/probes/covergroup_probe.sv" > "$probe_dir/covergroup_lint.log" 2>&1; then
  printf '%s\n' 'covergroup lint accepted'
else
  printf '%s\n' 'covergroup lint rejected; see retained log'
fi
