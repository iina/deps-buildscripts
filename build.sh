#!/bin/bash
# -e is intentionally omitted: run_build catches failures individually so all
# scripts run even when some fail, giving a full picture in one CI run.
set -uo pipefail

cd "$(dirname "$0")"
source config.env
source versions.env

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
ARCH_FILTER="${1:-all}"  # "all", "arm64", or "x86_64"

if [ "$ARCH_FILTER" != "all" ] && [ "$ARCH_FILTER" != "arm64" ] && [ "$ARCH_FILTER" != "x86_64" ]; then
    echo "Usage: $0 [all|arm64|x86_64]" >&2
    exit 1
fi

if [ "$ARCH_FILTER" != "all" ]; then
    ARCHS="$ARCH_FILTER"
fi

# ---------------------------------------------------------------------------
# Check required build tools
# ---------------------------------------------------------------------------
check_tool() {
    command -v "$1" >/dev/null 2>&1 || { echo "ERROR: $1 not found. Install with: $2" >&2; exit 1; }
}
check_tool meson      "brew install meson"
check_tool ninja      "brew install ninja"
check_tool nasm       "brew install nasm"
check_tool cmake      "brew install cmake"
check_tool pkg-config "brew install pkg-config"

# ---------------------------------------------------------------------------
# Create directory tree
# ---------------------------------------------------------------------------
mkdir -p "$SOURCES_DIR" "$BUILD_DIR" "$OUTPUT_DIR"
LOG_DIR="${BUILD_DIR}/logs"
mkdir -p "$LOG_DIR"
for arch in $ARCHS; do
    mkdir -p "${INSTALL_DIR}/${arch}"
done

# ---------------------------------------------------------------------------
# Build helpers
# ---------------------------------------------------------------------------

FAILED_BUILDS=()
FAILED_LOGS=()

log_step() {
    echo "[$(date '+%H:%M:%S')] $*" >&2
}

# run_build <script-name>
# Tees script output to a per-script log file while streaming it live.
# On failure, the log path is saved so errors can be replayed at the end.
run_build() {
    local name="$1"
    local script="scripts/${name}"
    local log="${LOG_DIR}/${name}.log"

    if [ ! -f "$script" ]; then
        log_step "SKIP: ${name} (not yet implemented)"
        return
    fi

    if bash "$script" 2>&1 | tee "$log"; then
        log_step "OK: ${name}"
    else
        log_step "FAILED: ${name}"
        FAILED_BUILDS+=("${name}")
        FAILED_LOGS+=("${log}")
    fi
}

# ---------------------------------------------------------------------------
# Build in dependency order (Layer 1 → 4)
# ---------------------------------------------------------------------------

# --- Layer 1: Leaf libraries (no inter-dependencies) ---
run_build build-libogg.sh
run_build build-libvorbis.sh
run_build build-opus.sh
run_build build-freetype.sh
run_build build-fribidi.sh
run_build build-libunibreak.sh
run_build build-dav1d.sh
run_build build-luajit.sh
run_build build-uchardet.sh
run_build build-jpeg-turbo.sh
run_build build-little-cms2.sh
run_build build-mujs.sh
run_build build-libudfread.sh
run_build build-lz4.sh
run_build build-zstd.sh
run_build build-zimg.sh

# --- Layer 2: Libraries with Layer 1 dependencies ---
run_build build-harfbuzz.sh         # depends on freetype
run_build build-fontconfig.sh       # depends on freetype
run_build build-libplacebo.sh       # depends on little-cms2; built without Vulkan
run_build build-libbluray.sh        # depends on fontconfig, freetype, libudfread
run_build build-libarchive.sh       # depends on lz4, zstd (plus system zlib/bzip2/libiconv)

# --- Layer 3: Core media libraries ---
run_build build-libass.sh           # depends on freetype, fribidi, harfbuzz, fontconfig, libunibreak
run_build build-ffmpeg.sh           # depends on dav1d, opus, libvorbis

# --- Layer 4: mpv ---
run_build build-mpv.sh              # depends on everything above

# ---------------------------------------------------------------------------
# Combine per-arch builds into universal binaries
# ---------------------------------------------------------------------------
if [ "$ARCH_FILTER" = "all" ]; then
    bash scripts/create-universal.sh
fi

# ---------------------------------------------------------------------------
# Final report — replay the tail of every failed script's log
# ---------------------------------------------------------------------------
if [ ${#FAILED_BUILDS[@]} -gt 0 ]; then
    echo "" >&2
    echo "################################################################" >&2
    echo "# FAILED BUILDS (${#FAILED_BUILDS[@]}):" >&2
    printf '#   - %s\n' "${FAILED_BUILDS[@]}" >&2
    echo "################################################################" >&2

    for i in "${!FAILED_BUILDS[@]}"; do
        echo "" >&2
        echo "================================================================" >&2
        echo "  ERROR LOG: ${FAILED_BUILDS[$i]}" >&2
        echo "================================================================" >&2
        tail -80 "${FAILED_LOGS[$i]}" >&2
    done

    echo "" >&2
    echo "################################################################" >&2
    echo "# END OF ERROR SUMMARY" >&2
    echo "################################################################" >&2
    exit 1
fi

echo "Build complete. Output in ${OUTPUT_DIR}/"
