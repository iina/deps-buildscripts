#!/bin/bash
# BFS from libmpv: collect all transitively referenced dylibs that live in
# src_dir, copy them to dest_dir (or fix in-place when dest_dir is omitted),
# and rewrite LC_ID_DYLIB / LC_LOAD_DYLIB entries to use @rpath.
#
# The output file is named after the LC_ID_DYLIB basename (the "soname"), not
# the disk filename.  This correctly handles FFmpeg's three-level versioning
# where libavcodec.62.28.102.dylib has LC_ID_DYLIB = …/libavcodec.62.dylib.
#
# Usage (in-place, default for CI after lipo):
#   fix-install-names.sh [lib_dir]
#
# Usage (copy-then-fix, like the IINA Ruby script — preserves src unchanged):
#   fix-install-names.sh <src_lib_dir> <dest_lib_dir>
set -euo pipefail
source "$(dirname "$0")/common.sh"

src_dir="${1:-${OUTPUT_DIR}/lib}"
src_dir="$(cd "$src_dir" && pwd)"

if [ -n "${2:-}" ]; then
    mkdir -p "$2"
    dest_dir="$(cd "$2" && pwd)"
    in_place=0
else
    dest_dir="$src_dir"
    in_place=1
fi

log_step "Fixing install names  src=$src_dir  dest=$dest_dir"

# ── "seen" set (bash 3.2 compatible; no associative arrays) ──────────────────
# Key = LC_ID_DYLIB basename (= what consumers reference, e.g. libavcodec.62.dylib)
_seen_file="$(mktemp)"
trap 'rm -f "$_seen_file"' EXIT

_mark_seen() { printf '%s\n' "$1" >> "$_seen_file"; }
_is_seen()   { grep -qFx "$1" "$_seen_file" 2>/dev/null; }

# ── BFS queue (parallel arrays) ──────────────────────────────────────────────
queue_keys=()   # LC_ID_DYLIB basename = seen-set key
queue_paths=()  # real file path in src_dir
_q_idx=0

_enqueue() {       # <key> <real_src_path>
    local key="$1" real="$2"
    _is_seen "$key" && return
    _mark_seen "$key"
    queue_keys+=("$key")
    queue_paths+=("$real")
}

# ── Find libmpv entry point ───────────────────────────────────────────────────
shopt -s nullglob
_cands=("$src_dir"/libmpv.*.dylib "$src_dir"/libmpv.dylib)
shopt -u nullglob
_entry_real=""
for _f in "${_cands[@]}"; do
    [ -f "$_f" ] || continue
    _entry_real="$(realpath "$_f")"
    break
done
[ -n "$_entry_real" ] || { echo "ERROR: libmpv not found in $src_dir" >&2; exit 1; }
_enqueue "$(basename "$_entry_real")" "$_entry_real"

# ── Process one dylib ─────────────────────────────────────────────────────────
_fix_one() {
    local key="$1" real="$2"
    local name; name="$(basename "$real")"

    # Use the key (= dep_base = what the consumer embeds) as the canonical
    # output name and @rpath name.  This is correct even when the on-disk
    # filename is a full-version string (e.g. libavcodec.62.28.102.dylib)
    # while consumers reference the soname (libavcodec.62.dylib).
    local dest_file="$dest_dir/$key"

    if [ "$in_place" = "1" ]; then
        # Rename disk file to the name consumers reference if they differ.
        if [ "$key" != "$name" ]; then
            mv "$real" "$src_dir/$key"
            log_step "  renamed  $name  →  $key"
        fi
    else
        # Copy (only if not already present) using the consumer-facing name.
        [ -f "$dest_file" ] || cp -p "$real" "$dest_file"
    fi

    log_step "  $key  →  @rpath/$key"

    # Fix own install name.
    install_name_tool -id "@rpath/$key" "$dest_file"

    # Walk LC_LOAD_DYLIB entries from dest_file (already has the updated -id).
    # Rewrite any dep that lives in src_dir, then enqueue it.
    local dep dep_base dep_path dep_real
    while IFS= read -r dep; do
        [ -z "$dep" ] && continue
        dep_base="$(basename "$dep")"

        dep_path="$src_dir/$dep_base"
        [ -f "$dep_path" ] || continue      # system / framework lib — skip

        if [ "$dep" != "@rpath/$dep_base" ]; then
            install_name_tool -change "$dep" "@rpath/$dep_base" "$dest_file"
        fi

        dep_real="$(realpath "$dep_path")"
        _enqueue "$dep_base" "$dep_real"
    done < <(otool -L "$dest_file" | tail -n +2 | awk '{print $1}')
}

# ── BFS loop ──────────────────────────────────────────────────────────────────
while [ "$_q_idx" -lt "${#queue_paths[@]}" ]; do
    _fix_one "${queue_keys[$_q_idx]}" "${queue_paths[$_q_idx]}"
    _q_idx=$((_q_idx + 1))
done

log_step "Done — processed ${#queue_paths[@]} libraries."
