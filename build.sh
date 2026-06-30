#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"
ROOT_DIR="$(pwd)"
ARCHS="arm64 x86_64"
SOURCES_DIR="${ROOT_DIR}/sources"
BUILD_DIR="${ROOT_DIR}/build"
INSTALL_DIR="${ROOT_DIR}/install"
OUTPUT_DIR="${ROOT_DIR}/output"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
ARCH_FILTER="${1:-all}"  # "all", "arm64", or "x86_64"
shift 1
PACKAGE_FILTER="$*"     # optional: one or more package names (e.g. "ffmpeg mpv")

if [ "$ARCH_FILTER" != "all" ] && [ "$ARCH_FILTER" != "arm64" ] && [ "$ARCH_FILTER" != "x86_64" ]; then
    echo "Usage: $0 [all|arm64|x86_64] [package ...]" >&2
    exit 1
fi

if [ "$ARCH_FILTER" != "all" ]; then
    ARCHS="$ARCH_FILTER"
fi

# Export so child build-*.sh processes inherit the (possibly filtered) arch list
# instead of falling back to common.sh's default of "arm64 x86_64".
export ARCHS

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
check_tool aclocal    "brew install automake"  # also pulls in autoconf
check_tool cargo          "brew install rust"
check_tool cargo-cinstall "brew install cargo-c"

# ---------------------------------------------------------------------------
# Create directory tree
# ---------------------------------------------------------------------------
# On a full build (no package filter), wipe the install prefix for each arch
# being built so packages can't link against stale artifacts from a previous
# run (e.g. an old version, or a package since removed from the build list).
# Scoped per-arch: wiping the whole install/ would destroy the other arch's
# tree and silently degrade the final lipo_merge to single-arch.
# Skipped for partial builds, where dependencies must remain in the prefix.
if [ -z "$PACKAGE_FILTER" ]; then
    for arch in $ARCHS; do
        rm -rf "${INSTALL_DIR}/${arch}"
    done
fi

mkdir -p "$SOURCES_DIR" "$BUILD_DIR" "$OUTPUT_DIR"
for arch in $ARCHS; do
    mkdir -p "${INSTALL_DIR}/${arch}"
done

# ---------------------------------------------------------------------------
# Build helper
# ---------------------------------------------------------------------------

_BOLD="\033[1m"
_CYAN="\033[36m"
_GREEN="\033[32m"
_RESET="\033[0m"

if [ -n "$PACKAGE_FILTER" ]; then
    _PACKAGE_TOTAL=$(echo "$PACKAGE_FILTER" | wc -w | tr -d ' ')
else
    _PACKAGE_TOTAL=$(grep -c '^run buildscripts/build-' "$0")
fi
_PACKAGE_COUNT=0
_START_TIME=$SECONDS

_set_title() {
    if [ -n "${TMUX:-}" ]; then
        tmux rename-window "$1"
    else
        printf '\033]0;%s\007' "$1" >&2
    fi
}

# Restore the tmux window name on any exit (success, error, or interrupt),
# so a failed build doesn't leave the pane stuck on "Compiling ...".
_restore_title() {
    if [ -n "${TMUX:-}" ]; then
        tmux set-window-option automatic-rename on
    fi
}
trap _restore_title EXIT

# run <script> — skips if PACKAGE_FILTER is set and doesn't match the package name
run() {
    local script="$1"
    local name="${script#buildscripts/build-}"  # strip leading path and "build-"
    name="${name%.sh}"                     # strip .sh
    if [ -n "$PACKAGE_FILTER" ]; then
        case " $PACKAGE_FILTER " in
            *" $name "*) ;;
            *) return 0 ;;
        esac
    fi
    _PACKAGE_COUNT=$(( _PACKAGE_COUNT + 1 ))
    _set_title "Compiling ${name} (${_PACKAGE_COUNT}/${_PACKAGE_TOTAL})"
    printf "\n${_BOLD}${_CYAN}╔══ [%d/%d] %s${_RESET}\n" \
        "$_PACKAGE_COUNT" "$_PACKAGE_TOTAL" "$name" >&2
    rm -rf "${BUILD_DIR}/${name}"
    bash "$script"
    printf "${_BOLD}${_GREEN}╚══ done: %s${_RESET}\n" "$name" >&2
}

# ---------------------------------------------------------------------------
# Build in dependency order (Layer 1 → 4)
# ---------------------------------------------------------------------------

# --- Layer 1: Leaf libraries + encoders/decoders ---
run buildscripts/build-freetype.sh         # font rendering
run buildscripts/build-fribidi.sh          # unicode bidirectional algorithm
run buildscripts/build-libunibreak.sh      # unicode line/work break algorithm
run buildscripts/build-luajit.sh           # lua compiler required by mpv scripting
run buildscripts/build-mujs.sh             # javascript interpreter, used by mpv scripting
run buildscripts/build-uchardet.sh         # character encoding detector, used by mpv
run buildscripts/build-little-cms2.sh      # ICC color profile library
run buildscripts/build-libudfread.sh       # UDF filesystem reader required by libbluray
run buildscripts/build-lz4.sh              # compression algorithm used by libarchive
run buildscripts/build-zstd.sh             # compression algorithm used by libarchive
run buildscripts/build-zimg.sh             # image scaling algorithm used by mpv's zscale filter
run buildscripts/build-libbs2b.sh          # binaural audio filter
run buildscripts/build-libsoxr.sh          # high-quality resampling

## encoders
run buildscripts/build-jpeg-turbo.sh       # provides libjpeg, used by mpv to encode jpeg screenshots
run buildscripts/build-libwebp.sh          # WebP screenshots
run buildscripts/build-rav1e.sh            # AV1/AVIF screenshots
run buildscripts/build-libjxl.sh           # JPEG XL screenshots; uses bundled brotli, highway, lcms2

## decoders
run buildscripts/build-dav1d.sh            # AV1 decoder
run buildscripts/build-speex.sh            # Speex audio format decoding support
run buildscripts/build-libogg.sh           # base library for Ogg bitstream format
run buildscripts/build-libvorbis.sh        # Ogg Vorbis audio decoder; depends on libogg

# --- Layer 2: Libraries with Layer 1 dependencies ---
run buildscripts/build-harfbuzz.sh         # text shaping engine; depends on freetype
run buildscripts/build-fontconfig.sh       # font configuration and matching; depends on freetype
run buildscripts/build-libarchive.sh       # reading archive files used by mpv; depends on lz4, zstd
run buildscripts/build-rubberband.sh       # audio pitch/tempo, used by both mpv and FFmpeg

# --- Layer 3: Core media libraries ---
run buildscripts/build-libbluray.sh        # depends on fontconfig, freetype, libudfread
run buildscripts/build-libplacebo.sh       # depends on little-cms2
run buildscripts/build-libass.sh           # depends on freetype, fribidi, harfbuzz, fontconfig, libunibreak
run buildscripts/build-ffmpeg.sh           # depends on all Layer 1+2 libs above

# --- Layer 4: mpv ---
run buildscripts/build-mpv.sh

# ---------------------------------------------------------------------------
# Combine per-arch builds into universal binaries
# ---------------------------------------------------------------------------
if [ "$ARCH_FILTER" = "all" ] && [ -z "$PACKAGE_FILTER" ]; then
    bash buildscripts/create-universal.sh
fi

_ELAPSED=$(( SECONDS - _START_TIME ))
echo "Built ${_PACKAGE_COUNT}/${_PACKAGE_TOTAL} packages in $(( _ELAPSED / 60 ))m $(( _ELAPSED % 60 ))s. Output in ${OUTPUT_DIR}/"
