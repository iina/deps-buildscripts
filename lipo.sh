#!/bin/bash
# lipo-merge two per-arch dylib directories into universal binaries, then
# ad-hoc sign each result. Run this after fix-install-names.sh has produced
# the per-arch trees.
#
# Usage:
#   lipo.sh [arm64_dir [x86_64_dir [out_dir]]]
#   Defaults: arm64_dir = output/arm64   x86_64_dir = output/x86_64   out_dir = output/lib
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"

arm_dir="${1:-${ROOT_DIR}/output/arm64}"
x86_dir="${2:-${ROOT_DIR}/output/x86_64}"
out_dir="${3:-${ROOT_DIR}/output/fat}"

mkdir -p "$out_dir"

shopt -s nullglob
for arm_lib in "$arm_dir"/*.dylib; do
    [ -L "$arm_lib" ] && continue            # skip symlinks; merge real files only
    name="$(basename "$arm_lib")"
    out_lib="${out_dir}/${name}"
    x86_lib="${x86_dir}/${name}"

    if [ -f "$x86_lib" ]; then
        lipo -create "$arm_lib" "$x86_lib" -output "$out_lib"
    else
        echo "WARN: no x86_64 counterpart for ${name} — copying arm64" >&2
        cp -p "$arm_lib" "$out_lib"
    fi

    codesign --force --sign - "$out_lib"     # ad-hoc; replaced by real signing at release
    echo "$name"
done

echo "Universal binaries written to: ${out_dir}"
