# Plan: IINA Dependency Build System

## 1. Project Context

### 1.1 What is IINA

IINA is the leading open-source video player for macOS, built in Swift. It uses **libmpv** (the library form of mpv) for all media playback. libmpv in turn depends on ffmpeg, libass, libplacebo, and ~15 other C/C++ libraries. IINA ships these as `.dylib` files bundled inside the app.

### 1.2 Current Build Process and Its Problems

IINA currently uses a **Homebrew-based approach** via a custom tap (`iina/homebrew-mpv-iina`) and a `compile.rb` script. This has several critical limitations:

- **Requires physical machines running the minimum target macOS version.** The homebrew tap README explicitly states: *"this script no longer injects MACOSX_DEPLOYMENT_TARGET... All libraries are targeted to the compiling system. So, in order to support a lower version of macOS, please run this script on that specific version of macOS."*
- **Requires separate ARM and Intel machines.** Builds for each architecture happen on different hardware, then get combined.
- **Homebrew actively resists customization.** It frequently changes formulae, doesn't support pinning well, and is designed as a package manager, not a build system.
- **Not CI-friendly.** The physical-machine requirement makes automation difficult.

A **Nix-based approach** (PR #6064) was also explored but has its own problems: Nix on macOS is a second-class citizen, its sandboxing model conflicts with macOS SDK/framework expectations, and cross-compilation targeting specific `MACOSX_DEPLOYMENT_TARGET` values is fragile.

### 1.3 Goal

Build a **self-contained build system** (shell scripts + CI configuration) that:

1. Compiles all of IINA's native dependencies from source
2. Targets **macOS 11.0 (Big Sur) and above**
3. Produces **universal binaries** (arm64 + x86_64) via `lipo`
4. Runs entirely in **GitHub Actions CI** (no physical machines)
5. Is **reproducible** (pinned versions, verified checksums)
6. Is **maintainable** by a small team (clear structure, documented, ~500-800 lines total)

### 1.4 Output Artifacts

The build system produces a set of `.dylib` files plus headers, ready to be dropped into IINA's `deps/` directory:

- `libmpv.dylib` (the main library IINA links against)
- All transitive `.dylib` dependencies (libavcodec, libavformat, libass, libplacebo, etc.)
- Corresponding header files in `include/`

---

## 2. Reference Projects

Study these projects before writing any code. They solve the same or adjacent problems and contain battle-tested solutions to macOS-specific build issues.

### 2.1 Primary References

| Project | URL | What to Study |
|---------|-----|---------------|
| **m154k1/mpv-build-macOS** | `https://github.com/m154k1/mpv-build-macOS` | **Best structural reference.** Individual `build-*` scripts per dependency, a `build-all` orchestrator, `.env` for config, `src/` for sources, `meson/native/` for meson config files. Active, 167 commits, CI with GitHub Actions. Study: script structure, the `.env` file for global variables, how each `build-*` script handles configure/make/install, how the `build-all` script orders dependencies. |
| **HandBrake contrib system** | `https://github.com/HandBrake/HandBrake/tree/master/contrib` | **Best reference for the module pattern.** Each dependency lives in `contrib/<name>/module.defs` with fetch URL, SHA256, configure flags, and patches. Over 40 dependencies managed this way. Study: how `module.defs` declares dependencies, how patches are applied, how `MACOSX_DEPLOYMENT_TARGET` and arch flags are threaded through, how the topological sort works. |
| **nilaoda/mpv-iina-avs** | `https://github.com/nilaoda/mpv-iina-avs` | **Directly targets IINA.** Builds a patched FFmpeg + mpv for IINA with custom patches, supports both arm64 and x86_64 cross-compilation. Study: `tools/` directory for build scripts, `tools/patches/` for IINA/macOS-specific patches, `.github/workflows/` for CI, how cross-compilation from arm64 to x86_64 is handled. |
| **eko5624/mpv-mac** | `https://github.com/eko5624/mpv-mac` | **Cross-compilation reference.** Shows meson cross-files for building mpv on the non-native arch, `build.env` for environment setup, CI with GitHub Actions on macOS runners. Study: the `build.env` file (MACOSX_DEPLOYMENT_TARGET, ARCH detection, cross-compile flags), meson cross-file format, how `-arch x86_64` is passed through autotools/meson/cmake. |

### 2.2 Secondary References

| Project | URL | What to Study |
|---------|-----|---------------|
| **WayneKoorts/ffmpeg-macos-universal-binary-builder** | `https://github.com/WayneKoorts/ffmpeg-macos-universal-binary-builder` | Clean single-script approach to building FFmpeg + codec deps as universal binaries. Uses source caching. Good reference for the lipo step and version pinning via env vars. |
| **mpv-player/mpv-build** | `https://github.com/mpv-player/mpv-build` | Official mpv helper scripts for Linux. Study: how `ffmpeg_options` and `mpv_options` files work, version switching (`use-ffmpeg-release` / `use-ffmpeg-master`). Not macOS-specific but good for understanding mpv's build expectations. |
| **iina/homebrew-mpv-iina** | `https://github.com/iina/homebrew-mpv-iina` | The current system being replaced. Study: which configure flags IINA's mpv build uses, which dependencies are enabled/disabled, which Homebrew patches exist. The `compile.rb` script and the ffmpeg/mpv formula `.rb` files define the exact feature set IINA needs. |
| **mpv's own CI** | `https://github.com/mpv-player/mpv/blob/master/.github/workflows/build.yml` | How mpv's official CI builds on macOS. Study: which macOS runner versions are used, how `MACOSX_DEPLOYMENT_TARGET` is set, how Homebrew deps are handled in CI (to understand what we're replacing). |
| **IINA's `change_lib_dependencies.rb`** | In the IINA repo at `other/change_lib_dependencies.rb` | The post-build step that rewrites dylib install names for embedding in the app bundle. The new build system must produce output compatible with this script. Study: expected input format, how `@rpath` / `@loader_path` rewriting works. |

### 2.3 Key Technical Documents to Read

- **mpv's `meson.build`**: Understand mpv's meson options (especially `-Dlibmpv=true`, `-Dswift-build=disabled`, `-Dcocoa=enabled`)
- **ffmpeg's `./configure --help`**: Understand which decoders/features IINA needs enabled
- **Apple's `lipo` and `install_name_tool` man pages**: The tools for combining archs and rewriting dylib paths
- **Apple's SDK cross-compilation docs**: How `-isysroot`, `-mmacosx-version-min`, and `-target` interact

---

## 3. Dependency Graph

### 3.1 Full Dependency Tree

Build order must respect this graph (build leaves first, work upward):

```
Layer 0 — System / Xcode SDK (no build needed):
  zlib, libiconv, bzip2, Accelerate, AudioToolbox,
  CoreAudio, CoreMedia, CoreVideo, VideoToolbox,
  Metal, IOKit, IOSurface, QuartzCore, OpenGL, AppKit

Layer 1 — Leaf libraries (no inter-dependencies among themselves):
  pkg-config  (build tool only, not shipped)
  nasm        (build tool only, needed for dav1d asm)
  meson       (build tool only, via pip)
  ninja       (build tool only)
  freetype    (autotools/meson, no deps beyond zlib)
  fribidi     (meson, no deps)
  libunibreak (autotools, no deps)
  luajit      (custom makefile, no deps)
  uchardet    (cmake, no deps)
  dav1d       (meson + nasm, no deps)
  libvorbis   (autotools, depends on libogg)
  libogg      (autotools, no deps)
  opus        (autotools/meson, no deps)
  jpeg-turbo  (cmake, no deps — needed by mpv for JPEG screenshot output)
  little-cms2 (autotools, no deps — ICC color profile support for mpv and libplacebo)
  mujs        (makefile, no deps — JavaScript scripting support for mpv)
  libudfread  (autotools, no deps — UDF filesystem layer required by libbluray)
  lz4         (cmake, no deps — LZ4 compression support for libarchive)
  zstd        (cmake, no deps — Zstandard compression support for libarchive)
  zimg          (autotools, no deps — high-quality image scaling used by mpv's zscale filter)

Layer 2 — Libraries with Layer 1 deps:
  harfbuzz    (meson; depends on freetype, optionally ICU)
  fontconfig  (meson; depends on freetype, optionally expat/libxml2)
  libplacebo  (meson; depends on little-cms2; built with OpenGL renderer, Vulkan disabled)
  libbluray   (autotools; depends on fontconfig, freetype, libxml2, libudfread)
  libarchive  (cmake; depends on zlib, bzip2, libiconv — system — plus lz4, zstd)

Layer 3 — Core media libraries:
  libass      (meson; depends on freetype, fribidi, harfbuzz, fontconfig, libunibreak)
  ffmpeg      (autotools; depends on dav1d, opus, libvorbis, and many
               optional deps. IINA needs decoders only, not encoders.)

Layer 4 — mpv:
  mpv         (meson; depends on ffmpeg, libass, libplacebo, luajit,
               libbluray, libarchive, uchardet, jpeg-turbo, little-cms2,
               mujs, zimg. Build with -Dlibmpv=true, Vulkan disabled)
```

### 3.2 What IINA Actually Needs from FFmpeg

IINA is a **playback** application. It does NOT need encoders (x264, x265, libvpx encoding, etc.). The ffmpeg configure should focus on:

**Enable:** All built-in decoders (enabled by default), `--enable-videotoolbox`, `--enable-audiotoolbox`, hardware acceleration, `--enable-libdav1d` (AV1), `--enable-libvorbis`, `--enable-libopus`, shared libraries (`--enable-shared`), optimizations.

**Disable:** Encoders that pull in heavy deps (`--disable-libx264`, `--disable-libx265`, `--disable-libvpx` encoding), programs (`--disable-programs` — IINA doesn't use the ffmpeg/ffprobe binaries), static libs (`--disable-static`).

Consult `iina/homebrew-mpv-iina`'s ffmpeg formula for the exact flag set IINA has historically used.

### 3.3 Estimated Library Count

Approximately **22-25 libraries** to build. Vulkan and its entire dependency chain (vulkan-headers, vulkan-loader, MoltenVK, shaderc, glslang, SPIRV-Headers, SPIRV-Tools) are excluded — IINA uses mpv's OpenGL render path and never goes through Vulkan. libplacebo is built with its OpenGL renderer only.

---

## 4. Implementation Steps

### Phase 1: Project Scaffolding

**Step 1.1 — Create the repository structure**

```
iina-deps/
├── README.md                  # How to use, how to maintain
├── versions.env               # All version pins + SHA256 hashes
├── config.env                 # Global build config (deployment target, archs)
├── build.sh                   # Main entry point
├── scripts/
│   ├── common.sh              # Shared functions (download, verify, patch, etc.)
│   ├── build-libogg.sh
│   ├── build-freetype.sh
│   ├── build-fribidi.sh
│   ├── build-libunibreak.sh
│   ├── build-luajit.sh
│   ├── build-uchardet.sh
│   ├── build-dav1d.sh
│   ├── build-opus.sh
│   ├── build-libvorbis.sh
│   ├── build-jpeg-turbo.sh
│   ├── build-little-cms2.sh
│   ├── build-mujs.sh
│   ├── build-libudfread.sh
│   ├── build-lz4.sh
│   ├── build-zstd.sh
│   ├── build-zimg.sh
│   ├── build-harfbuzz.sh
│   ├── build-fontconfig.sh
│   ├── build-libplacebo.sh
│   ├── build-libbluray.sh
│   ├── build-libarchive.sh
│   ├── build-libass.sh
│   ├── build-ffmpeg.sh
│   └── build-mpv.sh
├── patches/                   # Any macOS-specific patches, organized per-dep
│   ├── ffmpeg/
│   ├── mpv/
│   └── libplacebo/
├── cross/                     # Meson/CMake cross-compilation files
│   ├── meson-x86_64-darwin.txt
│   └── meson-arm64-darwin.txt
├── .github/
│   └── workflows/
│       └── build.yml          # CI workflow
└── output/                    # .gitignored; where final dylibs + headers land
```

**Step 1.2 — Define `config.env`**

```bash
# Minimum macOS version IINA supports
export MACOSX_DEPLOYMENT_TARGET="11.0"

# Architectures to build
export ARCHS="arm64 x86_64"

# Parallel jobs
export JOBS=$(sysctl -n hw.ncpu)

# Paths
export ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SOURCES_DIR="${ROOT_DIR}/sources"       # Downloaded tarballs
export BUILD_DIR="${ROOT_DIR}/build"           # Per-arch build trees
export INSTALL_DIR="${ROOT_DIR}/install"       # Per-arch install prefixes
export OUTPUT_DIR="${ROOT_DIR}/output"         # Final universal binaries

# Compiler flags applied globally
# These are set per-arch in build.sh; defined here for documentation
# CFLAGS="-arch ${ARCH} -mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET} -O2"
# LDFLAGS="-arch ${ARCH} -mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET}"
```

**Step 1.3 — Define `versions.env`**

Pin every dependency to an exact version with a SHA256 hash of the source tarball. Example:

```bash
FREETYPE_VERSION="2.13.3"
FREETYPE_SHA256="..."
FREETYPE_URL="https://download.savannah.gnu.org/releases/freetype/freetype-${FREETYPE_VERSION}.tar.xz"

FRIBIDI_VERSION="1.0.16"
FRIBIDI_SHA256="..."
FRIBIDI_URL="https://github.com/fribidi/fribidi/releases/download/v${FRIBIDI_VERSION}/fribidi-${FRIBIDI_VERSION}.tar.xz"

HARFBUZZ_VERSION="10.1.0"
HARFBUZZ_SHA256="..."
HARFBUZZ_URL="https://github.com/harfbuzz/harfbuzz/releases/download/${HARFBUZZ_VERSION}/harfbuzz-${HARFBUZZ_VERSION}.tar.xz"

# New deps added vs original plan
JPEG_TURBO_VERSION="3.1.0"
JPEG_TURBO_SHA256="..."
JPEG_TURBO_URL="https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/${JPEG_TURBO_VERSION}/libjpeg-turbo-${JPEG_TURBO_VERSION}.tar.gz"

LITTLE_CMS2_VERSION="2.17"
LITTLE_CMS2_SHA256="..."
LITTLE_CMS2_URL="https://github.com/mm2/Little-CMS/releases/download/lcms${LITTLE_CMS2_VERSION}/lcms2-${LITTLE_CMS2_VERSION}.tar.gz"

MUJS_VERSION="1.3.6"
MUJS_SHA256="..."
MUJS_URL="https://mujs.com/downloads/mujs-${MUJS_VERSION}.tar.gz"

LIBUDFREAD_VERSION="0.2.3"
LIBUDFREAD_SHA256="..."
LIBUDFREAD_URL="https://code.videolan.org/videolan/libudfread/-/archive/${LIBUDFREAD_VERSION}/libudfread-${LIBUDFREAD_VERSION}.tar.gz"

LZ4_VERSION="1.10.0"
LZ4_SHA256="..."
LZ4_URL="https://github.com/lz4/lz4/releases/download/v${LZ4_VERSION}/lz4-${LZ4_VERSION}.tar.gz"

ZSTD_VERSION="1.5.7"
ZSTD_SHA256="..."
ZSTD_URL="https://github.com/facebook/zstd/releases/download/v${ZSTD_VERSION}/zstd-${ZSTD_VERSION}.tar.gz"

SPIRV_HEADERS_VERSION="1.4.309.0"
SPIRV_HEADERS_SHA256="..."
SPIRV_HEADERS_URL="https://github.com/KhronosGroup/SPIRV-Headers/archive/refs/tags/vulkan-sdk-${SPIRV_HEADERS_VERSION}.tar.gz"

SPIRV_TOOLS_VERSION="2024.4.rc2"
SPIRV_TOOLS_SHA256="..."
SPIRV_TOOLS_URL="https://github.com/KhronosGroup/SPIRV-Tools/archive/refs/tags/v${SPIRV_TOOLS_VERSION}.tar.gz"

GLSLANG_VERSION="15.3.0"
GLSLANG_SHA256="..."
GLSLANG_URL="https://github.com/KhronosGroup/glslang/archive/refs/tags/${GLSLANG_VERSION}.tar.gz"

SHADERC_VERSION="2024.4"
SHADERC_SHA256="..."
SHADERC_URL="https://github.com/google/shaderc/archive/refs/tags/v${SHADERC_VERSION}.tar.gz"

ZIMG_VERSION="3.0.5"
ZIMG_SHA256="..."
ZIMG_URL="https://github.com/sekrit-twc/zimg/archive/refs/tags/release-${ZIMG_VERSION}.tar.gz"

# ... (all other dependencies)

FFMPEG_VERSION="8.1.2"
FFMPEG_SHA256="464beb5e7bf0c311e68b45ae2f04e9cc2af88851abb4082231742a74d97b524c"
FFMPEG_URL="https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz"

MPV_VERSION="0.41.0"
MPV_SHA256="ee21092a5ee427353392360929dc64645c54479aefdb5babc5cfbb5fad626209"
MPV_URL="https://github.com/mpv-player/mpv/archive/refs/tags/v${MPV_VERSION}.tar.gz"
```

**To populate these values:** For each dependency, go to its official release page, find the latest stable release tarball URL, and compute `sha256sum`. FFmpeg and mpv SHA256s above are taken from the Homebrew formula and can be trusted. All others marked `"..."` must be computed at implementation time. The SPIRV-Tools version string format (`vX.Y.rc`) is irregular — verify the exact tag on GitHub before pinning.

### Phase 2: Core Build Infrastructure

**Step 2.1 — Implement `scripts/common.sh`**

This file contains shared functions used by all per-dependency build scripts:

```bash
# download_and_verify <url> <sha256> <output_file>
#   Downloads if not already cached, verifies SHA256

# extract_source <tarball> <dest_dir>
#   Extracts to a clean directory

# apply_patches <dep_name> <source_dir>
#   Applies all patches from patches/<dep_name>/ in sorted order

# get_prefix <arch>
#   Returns the install prefix for the given architecture
#   e.g., /path/to/install/arm64

# get_build_dir <dep_name> <arch>
#   Returns the build directory for a dep+arch combination

# get_arch_flags <arch>
#   Returns CFLAGS/LDFLAGS/PKG_CONFIG_PATH for the given arch

# lipo_merge <dep_name>
#   Takes per-arch installed libs and merges them into universal binaries
#   in the output directory

# log_step <message>
#   Consistent logging with timestamps
```

**Step 2.2 — Implement per-dependency build scripts**

Each `scripts/build-<dep>.sh` follows the same pattern:

```bash
#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

DEP_NAME="freetype"
# Variables come from versions.env (already sourced by build.sh)

build_for_arch() {
    local arch=$1
    local prefix=$(get_prefix "$arch")
    local build_dir=$(get_build_dir "$DEP_NAME" "$arch")
    local src_dir="${SOURCES_DIR}/${DEP_NAME}-${FREETYPE_VERSION}"

    eval "$(get_arch_flags "$arch")"

    # Clean and enter build directory
    rm -rf "$build_dir"
    mkdir -p "$build_dir"

    # Configure (autotools example)
    cd "$src_dir"
    ./configure \
        --prefix="$prefix" \
        --host="$(get_host_triple "$arch")" \
        --enable-shared \
        --disable-static \
        --without-bzip2 \
        --without-png \
        --without-brotli

    # Build and install
    make -j"$JOBS"
    make install
}

# Download and extract once
download_and_verify "$FREETYPE_URL" "$FREETYPE_SHA256" "freetype-${FREETYPE_VERSION}.tar.xz"
extract_source "freetype-${FREETYPE_VERSION}.tar.xz" "${DEP_NAME}-${FREETYPE_VERSION}"
apply_patches "$DEP_NAME" "${SOURCES_DIR}/${DEP_NAME}-${FREETYPE_VERSION}"

# Build for each arch
for arch in $ARCHS; do
    log_step "Building ${DEP_NAME} for ${arch}"
    build_for_arch "$arch"
done

# Create universal binary
lipo_merge "$DEP_NAME"
```

For **meson-based** projects (harfbuzz, fribidi, dav1d, libplacebo, libass, mpv), the configure step uses meson instead:

```bash
    meson setup "$build_dir" "$src_dir" \
        --cross-file="${ROOT_DIR}/cross/meson-${arch}-darwin.txt" \
        --prefix="$prefix" \
        --default-library=shared \
        --buildtype=release \
        -Ddocs=disabled \
        -Dtests=disabled
    ninja -C "$build_dir" -j"$JOBS"
    ninja -C "$build_dir" install
```

For **cmake-based** projects (uchardet, vulkan-headers, libarchive):

```bash
    cmake -S "$src_dir" -B "$build_dir" \
        -DCMAKE_INSTALL_PREFIX="$prefix" \
        -DCMAKE_OSX_ARCHITECTURES="$arch" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=ON
    cmake --build "$build_dir" -j"$JOBS"
    cmake --install "$build_dir"
```

**Step 2.3 — Implement meson cross-files**

Create `cross/meson-x86_64-darwin.txt`:

```ini
[binaries]
c = 'clang'
cpp = 'clang++'
objc = 'clang'
ar = 'ar'
strip = 'strip'
pkg-config = 'pkg-config'

[built-in options]
c_args = ['-arch', 'x86_64', '-mmacosx-version-min=11.0']
c_link_args = ['-arch', 'x86_64', '-mmacosx-version-min=11.0']
cpp_args = ['-arch', 'x86_64', '-mmacosx-version-min=11.0']
cpp_link_args = ['-arch', 'x86_64', '-mmacosx-version-min=11.0']
objc_args = ['-arch', 'x86_64', '-mmacosx-version-min=11.0']

[host_machine]
system = 'darwin'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
```

Create `cross/meson-arm64-darwin.txt` (identical but with `arm64`/`aarch64`):

```ini
[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'

# ... same pattern, s/x86_64/arm64/
```

**Important nuance:** When building natively (e.g., arm64 on an arm64 runner), you should use a **native file** instead of a cross-file, or omit the cross-file entirely and just set env vars. The cross-file is only needed when the build arch differs from the host arch.

**Step 2.4 — Implement the `build.sh` orchestrator**

```bash
#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"
source config.env
source versions.env

# Parse arguments
ARCH_FILTER="${1:-all}"  # "all", "arm64", or "x86_64"
if [ "$ARCH_FILTER" != "all" ]; then
    ARCHS="$ARCH_FILTER"
fi

# Install build tools (if not present)
command -v meson >/dev/null || pip3 install meson
command -v ninja >/dev/null || brew install ninja
command -v nasm  >/dev/null || brew install nasm
command -v pkg-config >/dev/null || brew install pkg-config
command -v cmake >/dev/null || brew install cmake

# Create directories
mkdir -p "$SOURCES_DIR" "$BUILD_DIR" "$OUTPUT_DIR"
for arch in $ARCHS; do
    mkdir -p "${INSTALL_DIR}/${arch}"
done

# Build in dependency order (Layer 0→4)
# Layer 1 (no inter-dependencies — could be parallelized)
bash scripts/build-libogg.sh
bash scripts/build-freetype.sh
bash scripts/build-fribidi.sh
bash scripts/build-libunibreak.sh
bash scripts/build-luajit.sh
bash scripts/build-uchardet.sh
bash scripts/build-dav1d.sh
bash scripts/build-opus.sh
bash scripts/build-jpeg-turbo.sh
bash scripts/build-little-cms2.sh
bash scripts/build-mujs.sh
bash scripts/build-libudfread.sh
bash scripts/build-lz4.sh
bash scripts/build-zstd.sh
bash scripts/build-zimg.sh

# Layer 2 (depend on Layer 1)
bash scripts/build-libvorbis.sh    # depends on libogg
bash scripts/build-harfbuzz.sh     # depends on freetype
bash scripts/build-fontconfig.sh   # depends on freetype
bash scripts/build-libplacebo.sh   # depends on little-cms2; built without Vulkan
bash scripts/build-libbluray.sh    # depends on fontconfig, freetype, libudfread
bash scripts/build-libarchive.sh   # depends on lz4, zstd (plus system zlib/bzip2/libiconv)

# Layer 3 (depend on Layer 1+2)
bash scripts/build-libass.sh       # depends on freetype, fribidi, harfbuzz, fontconfig, libunibreak
bash scripts/build-ffmpeg.sh       # depends on dav1d, opus, libvorbis

# Layer 4
bash scripts/build-mpv.sh          # depends on everything above

# Final: create universal binaries if we built both archs
if [ "$ARCH_FILTER" = "all" ]; then
    bash scripts/create-universal.sh
fi

echo "✅ Build complete. Output in ${OUTPUT_DIR}/"
```

**Step 2.5 — Implement `scripts/create-universal.sh`**

This script walks through all `.dylib` files in the per-arch install prefixes and runs `lipo -create` to produce universal binaries:

```bash
#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

# For each .dylib in arm64 prefix, find matching x86_64 and lipo them
ARM64_LIB="${INSTALL_DIR}/arm64/lib"
X86_64_LIB="${INSTALL_DIR}/x86_64/lib"
UNIVERSAL_LIB="${OUTPUT_DIR}/lib"
UNIVERSAL_INCLUDE="${OUTPUT_DIR}/include"

mkdir -p "$UNIVERSAL_LIB" "$UNIVERSAL_INCLUDE"

find "$ARM64_LIB" -name '*.dylib' -not -type l | while read arm_lib; do
    basename=$(basename "$arm_lib")
    x86_lib="${X86_64_LIB}/${basename}"

    if [ -f "$x86_lib" ]; then
        log_step "lipo: ${basename}"
        lipo -create "$arm_lib" "$x86_lib" -output "${UNIVERSAL_LIB}/${basename}"
    else
        log_step "WARN: no x86_64 match for ${basename}, copying arm64 only"
        cp "$arm_lib" "${UNIVERSAL_LIB}/${basename}"
    fi
done

# Copy symlinks (preserving relative targets)
find "$ARM64_LIB" -name '*.dylib' -type l | while read link; do
    target=$(readlink "$link")
    basename=$(basename "$link")
    ln -sf "$target" "${UNIVERSAL_LIB}/${basename}"
done

# Copy headers (arch-independent)
cp -R "${INSTALL_DIR}/arm64/include/"* "$UNIVERSAL_INCLUDE/"
```

### Phase 3: FFmpeg and mpv (The Hard Part)

These two are the most complex and most critical builds.

**Step 3.1 — FFmpeg build script**

FFmpeg 8.x is the current target. The configure flags below are appropriate for 8.x; verify against `./configure --help` if a flag is rejected (8.x removed some flags present in 7.x, e.g. `--enable-neon` is now auto-detected and should be omitted).

**TLS strategy:** Use `--enable-securetransport` to use macOS's native Security.framework for HTTPS streams — no OpenSSL dependency needed. If securetransport proves insufficient (e.g. specific protocol support missing), the fallback is to add `openssl@3` as a dep and switch to `--enable-openssl`.

```bash
./configure \
    --prefix="$prefix" \
    --enable-shared \
    --disable-static \
    --disable-programs \
    --disable-doc \
    --enable-gpl \
    --enable-version3 \
    --enable-pthreads \
    --enable-videotoolbox \
    --enable-audiotoolbox \
    --enable-securetransport \
    --enable-libdav1d \
    --enable-libvorbis \
    --enable-libopus \
    --arch="$arch" \
    --extra-cflags="-arch ${arch} -mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET}" \
    --extra-ldflags="-arch ${arch} -mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET}" \
    --cc=clang \
    --enable-cross-compile \
    --target-os=darwin
```

**Critical cross-compilation note for ffmpeg:** When building x86_64 on an arm64 host, ffmpeg needs `--enable-cross-compile --arch=x86_64 --target-os=darwin`, and you should set `--sysroot` to the macOS SDK path (`xcrun --show-sdk-path`). Note: `--pkg-config-flags="--static"` was removed from the flags above — it caused pkg-config to return static lib paths which then broke shared linking in ffmpeg 8.x.

**Step 3.2 — mpv build script**

mpv uses meson. Key options for IINA:

```bash
meson setup "$build_dir" "$src_dir" \
    --cross-file="${ROOT_DIR}/cross/meson-${arch}-darwin.txt" \
    --prefix="$prefix" \
    --default-library=shared \
    --buildtype=release \
    -Dlibmpv=true \
    -Dcplayer=false \
    -Dcocoa=enabled \
    -Dcoreaudio=enabled \
    -Dvideotoolbox-gl=enabled \
    -Dswift-build=disabled \
    -Dlua=luajit \
    -Djavascript=enabled \
    -Dlibbluray=enabled \
    -Dlibarchive=enabled \
    -Duchardet=enabled \
    -Dlcms2=enabled \
    -Dvulkan=disabled \
    -Dvapoursynth=disabled \
    -Drubberband=disabled \
    -Dmanpage-build=disabled \
    -Dtests=false
```

The `-Dcplayer=false` flag skips building the mpv binary (IINA only needs libmpv). The `-Dswift-build=disabled` avoids Swift interop in the library (IINA has its own Swift wrappers). `-Djavascript=enabled` requires mujs; `-Dlcms2=enabled` requires little-cms2; `-Dvulkan=disabled` removes the entire Vulkan render path — IINA uses the OpenGL or Metal render path instead.

**Note on option names for mpv 0.41.0:** Some option names may differ from earlier releases. Verify with `meson configure` output if any flag is rejected. In particular, `-Dvideotoolbox-gl` may be renamed in 0.41.x — check mpv's `meson_options.txt` in the source tree.

**Critical:** mpv's meson.build may need symlinks to find libplacebo and libavutil headers when cross-compiling. See the `eko5624/mpv-mac` workaround:

```bash
# In the mpv source directory, before meson setup:
if [ "$arch" != "$(uname -m)" ]; then
    ln -sf "${prefix}/include/libplacebo" libplacebo
    ln -sf "${prefix}/include/libavutil" libavutil
fi
```

### Phase 4: CI Configuration

**Step 4.1 — GitHub Actions workflow**

The recommended approach is to **build each architecture on its native runner** and then combine:

```yaml
name: Build IINA Dependencies

on:
  workflow_dispatch:    # Manual trigger
  push:
    paths:
      - 'versions.env'
      - 'scripts/**'
      - 'patches/**'
      - '.github/workflows/build.yml'

jobs:
  build-arm64:
    runs-on: macos-14    # Apple Silicon runner
    steps:
      - uses: actions/checkout@v4

      - name: Install build tools
        run: |
          brew install nasm ninja cmake pkg-config
          pip3 install meson --break-system-packages

      - name: Build all dependencies (arm64)
        run: bash build.sh arm64

      - name: Upload arm64 artifacts
        uses: actions/upload-artifact@v4
        with:
          name: deps-arm64
          path: install/arm64/

  build-x86_64:
    runs-on: macos-13    # Intel runner
    steps:
      - uses: actions/checkout@v4

      - name: Install build tools
        run: |
          brew install nasm ninja cmake pkg-config
          pip3 install meson --break-system-packages

      - name: Build all dependencies (x86_64)
        run: bash build.sh x86_64

      - name: Upload x86_64 artifacts
        uses: actions/upload-artifact@v4
        with:
          name: deps-x86_64
          path: install/x86_64/

  create-universal:
    needs: [build-arm64, build-x86_64]
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4

      - name: Download arm64 artifacts
        uses: actions/download-artifact@v4
        with:
          name: deps-arm64
          path: install/arm64/

      - name: Download x86_64 artifacts
        uses: actions/download-artifact@v4
        with:
          name: deps-x86_64
          path: install/x86_64/

      - name: Create universal binaries
        run: bash scripts/create-universal.sh

      - name: Verify universal binaries
        run: |
          for dylib in output/lib/*.dylib; do
            [ -L "$dylib" ] && continue
            echo "Checking $dylib..."
            lipo -info "$dylib"
            # Verify both architectures present
            lipo -info "$dylib" | grep -q "arm64" || { echo "FAIL: missing arm64"; exit 1; }
            lipo -info "$dylib" | grep -q "x86_64" || { echo "FAIL: missing x86_64"; exit 1; }
            # Verify deployment target
            otool -l "$dylib" | grep -A2 LC_VERSION_MIN_MACOSX || true
          done

      - name: Package output
        run: tar czf iina-deps-universal.tar.gz -C output .

      - name: Upload release artifact
        uses: actions/upload-artifact@v4
        with:
          name: iina-deps-universal
          path: iina-deps-universal.tar.gz

      - name: Create release (on tag)
        if: startsWith(github.ref, 'refs/tags/')
        uses: softprops/action-gh-release@v2
        with:
          files: iina-deps-universal.tar.gz
```

**Why native builds instead of cross-compilation in CI:**
- GitHub Actions provides both Intel (`macos-13`) and ARM (`macos-14`, `macos-15`) runners for free
- Native builds avoid all cross-compilation edge cases (asm-heavy libraries like dav1d have architecture-specific assembly that can fail under cross-compilation)
- The lipo step is trivially parallelizable
- If GitHub retires Intel runners in the future, you can switch to cross-compiling at that point with the meson cross-files already in place

### Phase 5: Integration with IINA

**Step 5.1 — Output format compatibility**

The output must be compatible with IINA's existing `other/change_lib_dependencies.rb` script. This script:
1. Takes a prefix directory and the path to libmpv.dylib
2. Walks all dylib dependencies via `otool -L`
3. Copies them to `deps/lib/`
4. Rewrites install names to `@rpath/`

The build system should install dylibs with standard install names (which it will, since we use `--prefix`), and IINA's existing script handles the rest.

**Step 5.2 — Header file delivery**

Copy the following header directories from the install prefix:
- `include/mpv/` — mpv's client API headers (client.h, render.h, render_gl.h, stream_cb.h)
- `include/libav*/` — FFmpeg headers (needed for IINA's direct FFmpeg usage, if any)

These go into IINA's `deps/include/`.

**Step 5.3 — IINA integration changes**

Modify IINA's build documentation to point to this new system:
- Update README.md to reference the new build system
- Update `download_libs.sh` to pull from this project's GitHub Releases
- Optionally add a git submodule or subtree reference

---

## 5. Verification Checklist

After each build, the agent should verify:

### 5.1 Architecture Checks

```bash
# Every non-symlink dylib must be universal (contain both arm64 and x86_64)
for f in output/lib/*.dylib; do
    [ -L "$f" ] && continue
    arches=$(lipo -archs "$f")
    echo "$f: $arches"
    [[ "$arches" == *"arm64"* ]] || echo "FAIL: missing arm64"
    [[ "$arches" == *"x86_64"* ]] || echo "FAIL: missing x86_64"
done
```

### 5.2 Deployment Target Checks

```bash
# Every dylib must target macOS 11.0 or lower (not higher)
for f in output/lib/*.dylib; do
    [ -L "$f" ] && continue
    # Check the minimum OS version in Mach-O headers
    otool -l "$f" | grep -A3 "LC_BUILD_VERSION" | grep "minos" || \
    otool -l "$f" | grep -A2 "LC_VERSION_MIN_MACOSX" | grep "version"
done
```

### 5.3 Dependency Closure Check

```bash
# libmpv.dylib must not reference any paths outside of @rpath or /usr/lib/
otool -L output/lib/libmpv.dylib | grep -v "@rpath" | grep -v "/usr/lib/" | grep -v ":" && \
    echo "FAIL: external dependency found" || echo "OK: all deps are @rpath or system"
```

### 5.4 Functional Check

```bash
# Quick smoke test: link a trivial C program against libmpv and run it
cat > /tmp/test_mpv.c << 'EOF'
#include <mpv/client.h>
#include <stdio.h>
int main() {
    printf("mpv API version: %lu\n", mpv_client_api_version());
    mpv_handle *ctx = mpv_create();
    if (ctx) {
        printf("mpv context created successfully\n");
        mpv_destroy(ctx);
    }
    return 0;
}
EOF

clang /tmp/test_mpv.c \
    -I output/include \
    -L output/lib \
    -lmpv \
    -Wl,-rpath,output/lib \
    -o /tmp/test_mpv

/tmp/test_mpv
```

---

## 6. Maintenance Guide

### 6.1 Routine Version Bumps (Quarterly)

1. Check for new releases of each dependency
2. Update `versions.env` with new version, URL, and SHA256
3. Push to a branch; CI will build automatically
4. If CI passes, merge and tag a release

### 6.2 When a Build Breaks After a Version Bump

Common causes and fixes:

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| `configure: error: unrecognized option` | Upstream removed/renamed a flag | Read upstream changelog, update the build script's configure flags |
| Undefined symbol errors at link time | API change in a dependency | Check if a downstream dep needs a version bump too |
| Assembly errors during cross-compile | Architecture-specific asm not handled | Add `--disable-asm` for that dep when cross-compiling, or use native builds only |
| `meson.build` parse error | Meson version incompatibility | Pin meson version in CI (`pip install meson==X.Y.Z`) |
| New header not found | Upstream restructured includes | Update header search paths in the build script |

### 6.3 When mpv or ffmpeg has a Major Release

These are the most disruptive events (happens ~1-2 times per year per project):

1. Read the release notes thoroughly for build system changes
2. Build the new version with existing flags on a local machine first
3. Fix any flag changes (ffmpeg has historically been stable; mpv's meson transition was the big one, already completed)
4. Test that IINA still links and runs correctly against the new libmpv
5. Check for API deprecations/removals that might affect IINA's Swift code

### 6.4 Adding a New Dependency

1. Add version/URL/SHA256 to `versions.env`
2. Create `scripts/build-<dep>.sh` following the template
3. Add it to the correct layer in `build.sh`
4. Add it to ffmpeg or mpv's configure flags if it's an optional feature for either
5. Test locally, then push to CI

---

## 7. Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| GitHub retires free Intel macOS runners | Medium (2-3 years) | Medium | Cross-compilation files already in place; switch to cross-compiling from ARM | 
| A dependency requires a macOS > 11.0 API | Low per-dep, accumulates | High | Pin that dep's version, or contribute a compatibility patch upstream |
| ffmpeg major version breaks configure flags | Low (annual) | Medium | Build locally before CI, diff configure --help output |
| mpv changes its meson.build significantly | Low (annual) | Medium | Follow mpv's development branch, test before release |
| LuaJIT doesn't build for new Xcode/SDK | Low | Low | LuaJIT's macOS support is mature; worst case, switch to PUC Lua |
| Dylib install name rewriting breaks | Very Low | High | Test with IINA's existing `change_lib_dependencies.rb` after every build |

---

## 8. Estimated Effort

| Phase | Estimated Time | Notes |
|-------|---------------|-------|
| Phase 1: Scaffolding | 2-3 hours | Repo structure, env files, common.sh |
| Phase 2: Build scripts (Layer 1-2 deps) | 6-8 hours | ~22 scripts, each 30-60 lines; SPIRV/shaderc chain adds complexity |
| Phase 3: FFmpeg + mpv | 3-4 hours | Most complex configure flags, cross-compile edge cases |
| Phase 4: CI setup | 2-3 hours | GitHub Actions workflow, artifact passing, verification |
| Phase 5: Integration + testing | 2-3 hours | Test with actual IINA build, verify on macOS 11+ |
| **Total initial build** | **~2-3 focused days** | |
| **Ongoing maintenance** | **2-4 hours/quarter** | Mostly version bumps |
