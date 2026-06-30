#!/bin/bash
# Fix install names for one or both arch prefixes. For each arch, BFS from
# libmpv through install/<arch>/lib, copy every transitively referenced dylib
# to output/<arch>, and rewrite LC_ID_DYLIB / LC_LOAD_DYLIB to @rpath. The
# originals in install/ are never modified.
#
# Output files are named after the LC_ID_DYLIB basename (the "soname"), not the
# on-disk filename — this handles FFmpeg's versioning where the on-disk
# libavcodec.62.28.102.dylib has soname libavcodec.62.dylib.
#
# Usage:
#   fix-install-names.sh [all|arm64|x86_64]   (default: all)
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="${ROOT_DIR}/install"
OUTPUT_DIR="${ROOT_DIR}/output"

ARCH_FILTER="${1:-all}"
case "$ARCH_FILTER" in
    all)          archs=(arm64 x86_64) ;;
    arm64|x86_64) archs=("$ARCH_FILTER") ;;
    *) echo "Usage: $0 [all|arm64|x86_64]" >&2; exit 1 ;;
esac

# ── per-arch BFS state (reset at the start of each fix_arch) ──────────────────
src_dir=""; dest_dir=""
_seen_file="$(mktemp)"
trap 'rm -f "$_seen_file"' EXIT
queue_keys=(); queue_paths=(); _q_idx=0

_mark_seen() { printf '%s\n' "$1" >> "$_seen_file"; }
_is_seen()   { grep -qFx "$1" "$_seen_file" 2>/dev/null; }

_enqueue() {       # <key> <real_src_path>
    local key="$1" real="$2"
    _is_seen "$key" && return
    _mark_seen "$key"
    queue_keys+=("$key")
    queue_paths+=("$real")
}

# ── Process one dylib (operates on the current src_dir / dest_dir) ────────────
_fix_one() {
    local key="$1" real="$2"
    local name; name="$(basename "$real")"

    # Use the key (= what the consumer embeds) as the canonical output name and
    # @rpath name — correct even when the on-disk filename is a full-version
    # string (libavcodec.62.28.102.dylib) but consumers reference the soname.
    local dest_file="$dest_dir/$key"

    cp -p "$real" "$dest_file"
    if [ "$key" != "$name" ]; then
        echo "$name  →  $key"
    else
        echo "$name"
    fi

    install_name_tool -id "@rpath/$key" "$dest_file"

    local rpath
    while IFS= read -r rpath; do
        case "$rpath" in @*) continue ;; esac
        install_name_tool -delete_rpath "$rpath" "$dest_file" 2>/dev/null || true
        echo "  rpath  $rpath  (removed)"
    done < <(otool -l "$dest_file" | awk '/cmd LC_RPATH/{f=1} f && /path /{print $2; f=0}')

    local dep dep_base dep_path dep_real
    while IFS= read -r dep; do
        [ -z "$dep" ] && continue
        dep_base="$(basename "$dep")"

        dep_path="$src_dir/$dep_base"
        [ -f "$dep_path" ] || continue      # system / framework lib — skip

        if [ "$dep" != "@rpath/$dep_base" ]; then
            echo "  dep  $dep  →  @rpath/$dep_base"
            install_name_tool -change "$dep" "@rpath/$dep_base" "$dest_file"
        fi

        dep_real="$(realpath "$dep_path")"
        _enqueue "$dep_base" "$dep_real"
    done < <(otool -L "$dest_file" | tail -n +2 | awk '{print $1}')
}

# ── Fix one arch: install/<arch>/lib → output/<arch> ─────────────────────────
fix_arch() {
    local arch="$1"
    src_dir="${INSTALL_DIR}/${arch}/lib"
    if [ ! -d "$src_dir" ]; then
        echo "WARN: ${src_dir} not found — skipping ${arch}" >&2
        return 0
    fi
    src_dir="$(cd "$src_dir" && pwd)"

    dest_dir="${OUTPUT_DIR}/${arch}"
    rm -rf "$dest_dir"
    mkdir -p "$dest_dir"
    dest_dir="$(cd "$dest_dir" && pwd)"

    # Reset BFS state for this arch.
    : > "$_seen_file"
    queue_keys=(); queue_paths=(); _q_idx=0

    # Find the libmpv entry point.
    shopt -s nullglob
    local cands=("$src_dir"/libmpv.*.dylib "$src_dir"/libmpv.dylib)
    shopt -u nullglob
    local entry="" f
    for f in "${cands[@]}"; do
        [ -f "$f" ] || continue
        entry="$(realpath "$f")"; break
    done
    [ -n "$entry" ] || { echo "ERROR: libmpv not found in $src_dir" >&2; exit 1; }
    _enqueue "$(basename "$entry")" "$entry"

    echo "=== ${arch}: ${src_dir} → ${dest_dir} ==="
    while [ "$_q_idx" -lt "${#queue_paths[@]}" ]; do
        _fix_one "${queue_keys[$_q_idx]}" "${queue_paths[$_q_idx]}"
        _q_idx=$((_q_idx + 1))
    done
    echo "Done ${arch} — processed ${#queue_paths[@]} libraries."
}

for arch in "${archs[@]}"; do fix_arch "$arch"; done
