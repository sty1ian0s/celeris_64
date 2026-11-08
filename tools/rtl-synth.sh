#!/usr/bin/env bash
# Synthesize the Celeris-64 RTL and report cell counts. NO TIMING, NO BOARD.
#
# Why this needs a converter at all: Yosys's Verilog frontend does not accept
# `return` inside a function, which rtl/pkg/celeris64_pkg.sv uses throughout, and
# it rejects a part-select applied directly to a function call. Verilator accepts
# both. sv2v is used to lower the SystemVerilog to Verilog-2005 that Yosys reads.
# An earlier hand-rolled sed-based converter was deleted: sv2v is the purpose-built
# tool and it works.
#
# FIDELITY (docs/fidelity.md): a cell count is not a timing result. This script
# produces no clock frequency, no critical path and no area-per-technology claim.
# Generic `synth` cells are Yosys's internal gate library, not a real process.
# The iCE40 numbers are a real architecture's primitives but still unmapped to a
# board, unrouted, and untimed.
#
# Requires: ~/.local/sv2v/bin/sv2v, ~/.local/oss-cad-suite/bin/yosys
# Usage: tools/rtl-synth.sh [generic|ice40|all]   (default: all)

set -euo pipefail

SV2V="${SV2V:-$HOME/.local/sv2v/bin/sv2v}"
YOSYS="${YOSYS:-$HOME/.local/oss-cad-suite/bin/yosys}"

for tool in "$SV2V" "$YOSYS"; do
  if [ ! -x "$tool" ]; then
    echo "rtl-synth: missing $tool" >&2
    exit 1
  fi
done

cd "$(dirname "$0")/.."

# Package first: sv2v elaborates it into the modules that import it, so all
# sources must be converted in a single invocation.
SOURCES=(
  rtl/pkg/celeris64_pkg.sv
  rtl/alu.sv
  rtl/field_unit.sv
  rtl/select_unit.sv
  rtl/accel.sv
  rtl/stream_engine.sv
  rtl/regfile.sv
  rtl/core.sv
)

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

echo "rtl-synth: converting SystemVerilog to Verilog-2005 with sv2v"
"$SV2V" "${SOURCES[@]}" > "$OUT/design.v"

# A conversion that silently produced nothing would make every count below zero,
# which looks like a suspiciously small design rather than a failure.
if [ ! -s "$OUT/design.v" ]; then
  echo "rtl-synth: sv2v produced no output" >&2
  exit 1
fi
if ! grep -q "module core" "$OUT/design.v"; then
  echo "rtl-synth: converted output has no 'core' module" >&2
  exit 1
fi

mode="${1:-all}"

# Yosys prints a `stat` block after every pass, so take only the LAST block per
# run: that is the post-synthesis count. Printing every block would show the same
# numbers three times and invite a reader to average them.
last_stat_block() {
  awk '/^[0-9]+\. Printing statistics\.|^=== /{buf=""} {buf=buf $0 "\n"} END{printf "%s", buf}'
}

if [ "$mode" = "generic" ] || [ "$mode" = "all" ]; then
  echo
  echo "=== generic synthesis (Yosys internal cell library) ==="
  "$YOSYS" -p "read_verilog $OUT/design.v; synth -top core; stat" 2>&1 |
    last_stat_block |
    grep -E "^\s+[0-9]+ +\$_|^\s+[0-9]+ +cells" || true
fi

if [ "$mode" = "ice40" ] || [ "$mode" = "all" ]; then
  echo
  echo "=== iCE40 synthesis (SB_* primitives, flattened) ==="
  "$YOSYS" -p "read_verilog $OUT/design.v; synth_ice40 -top core -flatten; stat" 2>&1 |
    last_stat_block |
    grep -E "^\s+[0-9]+ +SB_|^\s+[0-9]+ +cells" || true
  echo
  echo "NOTE: cell counts only. Nothing here is placed, routed or timed, and no"
  echo "      clock frequency was established. An iCE40 HX8K has 7680 LUT4s."
fi
