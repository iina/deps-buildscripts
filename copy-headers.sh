#!/bin/bash
# Copy the headers IINA needs into the output include dir. Headers are
# architecture-independent, so they come from one arch's prefix.
#
# Usage:
#   copy-headers.sh [src_include_dir [dest_include_dir]]
#   Defaults: src = install/arm64/include   dest = output/include
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"

src_dir="${1:-${ROOT_DIR}/install/arm64/include}"
dest_dir="${2:-${ROOT_DIR}/output/include}"

ffmpeg_libs=(libavcodec libavformat libavutil libswscale)  # whole directories
mpv_headers=(client.h render.h render_gl.h)                # selected headers

rm -rf "$dest_dir"
mkdir -p "$dest_dir"

for lib in "${ffmpeg_libs[@]}"; do
    rm -rf "${dest_dir}/${lib}"
    cp -R "${src_dir}/${lib}" "${dest_dir}/${lib}"
    echo "${lib}/"
done

mkdir -p "${dest_dir}/mpv"
for h in "${mpv_headers[@]}"; do
    cp "${src_dir}/mpv/${h}" "${dest_dir}/mpv/${h}"
    echo "mpv/${h}"
done

echo "Headers written to: ${dest_dir}"
