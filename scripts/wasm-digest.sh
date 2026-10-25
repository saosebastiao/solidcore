#!/usr/bin/env bash
# Runs the Rust side of difftest units natively and on wasm32-wasip1 (wasmtime) and
# compares the per-case output digests (`difftest --digest-dir`): equal digests mean
# bit-identical Rust outputs on both targets. The C++ kernel is never run on wasm32: a
# case whose Rust side needs it (fixture exports) is `needs-cpp` there and skipped.
#
#   scripts/wasm-digest.sh [--jobs N] [--out DIR] [--units-file FILE] [--units-out FILE]
#                          [difftest selection...]                        # default --green
#
# `--units-file` runs exactly the unit ids listed in FILE (one per line, `#` comments and
# blank lines ignored) instead of a difftest selection; CI uses it with the checked-in
# `scripts/wasm-digest-units.txt` (the units whose outputs are libm-insensitive).
# `--units-out` writes, sorted, the units of this run with no mismatch (and no lost
# digest): the next `--units-file`, i.e. how the list is regenerated after a libm change.
#
# Needs `rustup target add wasm32-wasip1`, `wasmtime` on PATH and the C++ build
# (SOLIDCORE_CPP_DIR) for the native side. Writes DIR/{native,wasm}/<unit>.digest and
# DIR/mismatches.txt (default DIR: bin/wasm-digest); exits 1 on any mismatch.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
target=${CARGO_TARGET_DIR:-$root/bin}
jobs=2
out=$root/bin/wasm-digest
units_file=
units_out=
sel=()
while [ $# -gt 0 ]; do
  case $1 in
    --jobs) jobs=$2; shift 2 ;;
    --out) out=$2; shift 2 ;;
    --units-file) units_file=$2; shift 2 ;;
    --units-out) units_out=$2; shift 2 ;;
    *) sel+=("$1"); shift ;;
  esac
done
if [ -n "$units_file" ]; then
  [ -f "$units_file" ] || { echo "wasm-digest: no such units file: $units_file" >&2; exit 2; }
  [ ${#sel[@]} -eq 0 ] || { echo "wasm-digest: --units-file excludes a difftest selection" >&2; exit 2; }
  while IFS= read -r id || [ -n "$id" ]; do
    case $id in ''|'#'*) continue ;; esac
    sel+=(--unit "$id")
  done <"$units_file"
  [ ${#sel[@]} -gt 0 ] || { echo "wasm-digest: empty units file: $units_file" >&2; exit 2; }
fi
[ ${#sel[@]} -gt 0 ] || sel=(--green)
mkdir -p "$out"
out=$(cd "$out" && pwd)
rm -rf "$out/native" "$out/wasm" "$out/log"
mkdir -p "$out/native" "$out/wasm" "$out/log"

cd "$root"
cargo build --profile difftest -p difftest --features cpp
cargo build --profile difftest -p difftest --features cpp --target wasm32-wasip1
wasm=$target/wasm32-wasip1/difftest/difftest.wasm
python3 "$root/scripts/wasm_stub.py" "$wasm" "$out/stub.wat"
wasmtime compile "$wasm" -o "$out/difftest.cwasm"

"$target/difftest/difftest" "${sel[@]}" --jobs "$jobs" --digest-dir "$out/native" >"$out/log/native.txt"
# one wasmtime process per unit: a trap or abort (panic = abort on wasm32) loses one unit
ls "$out/native" | sed -n 's/\.digest$//p' >"$out/units.txt"
# WASI does not follow a symlink out of a preopened dir: map a linked upstream/ itself.
# (`readlink -f` is GNU-only; `pwd -P` is portable.)
up=$(cd "$root/upstream" && pwd -P)
export out root up
# One unit per process: a trap or abort (panic = abort on wasm32) loses only that unit.
# The runner is a file rather than `sh -c '<script>'` because BSD xargs caps the command
# template (-S, 255 bytes by default), which made this fail on macOS.
cat >"$out/run-unit.sh" <<'SH'
#!/bin/sh
# Runs one unit's Rust side on wasm32-wasip1; out/root/up come from the environment.
wasmtime run --allow-precompiled --dir "$root::$root" --dir "$up::$root/upstream" \
  --dir "$out::$out" --preload "env=$out/stub.wat" "$out/difftest.cwasm" \
  --unit "$1" --digest-dir "$out/wasm" >"$out/log/$1.txt" 2>&1 \
  || echo "wasm exit $? $1" >>"$out/log/$1.txt"
SH
xargs -P "$jobs" -I{} sh "$out/run-unit.sh" {} <"$out/units.txt"

: >"$out/mismatches.txt"
units=0 cases=0 needs=0 bad=0 lost=0
while read -r id; do
  units=$((units + 1))
  w=$out/wasm/$id.digest
  if [ ! -f "$w" ]; then
    lost=$((lost + 1))
    echo "$id: no wasm digest ($(tail -n 1 "$out/log/$id.txt"))" >>"$out/mismatches.txt"
    continue
  fi
  read -r c n m < <(paste "$out/native/$id.digest" "$w" | awk -F'\t' -v id="$id" -v f="$out/mismatches.txt" '
    { c++ }
    $3 != $1 { print id ": case order differs at line " NR >>f; m++; next }
    $4 == "needs-cpp" { n++; next }
    $2 != $4 { print id "\t" $1 "\tnative=" $2 "\twasm=" $4 >>f; m++ }
    END { print c + 0, n + 0, m + 0 }')
  cases=$((cases + c)) needs=$((needs + n)) bad=$((bad + m))
done <"$out/units.txt"
echo "wasm-digest: $units unit(s), $cases case(s), $((cases - needs)) compared, $needs needs-cpp, $bad mismatch(es), $lost unit(s) without wasm digest"
if [ -n "$units_out" ]; then
  # mismatches.txt lines are either `<id>\t<case>\t...` or `<id>: <reason>`
  cut -f1 "$out/mismatches.txt" | sed 's/: .*//' | sort -u >"$out/units-mismatched.txt"
  {
    echo '# Units whose Rust output is bit-identical natively (x86-64 glibc) and on wasm32-wasip1'
    echo '# (issue #487): the wasm-digest CI job compares their per-case output digests.'
    echo '# Written by scripts/wasm-digest.sh --units-out; see crates/difftest/README.md.'
    LC_ALL=C sort "$out/units.txt" | comm -23 - "$out/units-mismatched.txt"
  } >"$units_out"
  echo "wasm-digest: $(grep -vc '^#' "$units_out" | tr -d ' ') libm-insensitive unit(s) -> $units_out"
fi
[ "$bad" -eq 0 ] && [ "$lost" -eq 0 ]
