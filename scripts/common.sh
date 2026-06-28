#!/bin/bash
# Shared helpers sourced by every build-*.sh script.
# Auto-sources config.env and versions.env if the caller hasn't done so.

_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "${ROOT_DIR:-}" ]; then
    source "${_COMMON_DIR}/../config.env"
fi
if [ -z "${LIBOGG_VERSION:-}" ]; then
    source "${_COMMON_DIR}/../versions.env"
fi

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

log_step() {
    echo "[$(date '+%H:%M:%S')] $*" >&2
}

# ---------------------------------------------------------------------------
# Download and verify
# ---------------------------------------------------------------------------

# download_and_verify <url> <sha256> <filename>
# Downloads to $SOURCES_DIR if not cached; verifies SHA256 either way.
download_and_verify() {
    local url="$1" expected_sha256="$2" filename="$3"
    local dest="${SOURCES_DIR}/${filename}"

    mkdir -p "$SOURCES_DIR"

    if [ -f "$dest" ]; then
        local actual_sha256
        actual_sha256=$(shasum -a 256 "$dest" | awk '{print $1}')
        if [ "$actual_sha256" = "$expected_sha256" ]; then
            log_step "Cached: ${filename}"
            return 0
        fi
        log_step "SHA256 mismatch on cached ${filename} — re-downloading"
        rm -f "$dest"
    fi

    log_step "Downloading: ${filename}"
    curl -fsSL --retry 3 --retry-delay 5 -o "$dest" "$url"

    local actual_sha256
    actual_sha256=$(shasum -a 256 "$dest" | awk '{print $1}')
    if [ "$actual_sha256" != "$expected_sha256" ]; then
        echo "ERROR: SHA256 mismatch for ${filename}" >&2
        echo "  Expected: ${expected_sha256}" >&2
        echo "  Got:      ${actual_sha256}" >&2
        rm -f "$dest"
        exit 1
    fi
    log_step "Verified: ${filename}"
}

# ---------------------------------------------------------------------------
# Source extraction
# ---------------------------------------------------------------------------

# extract_source <filename> <dir-name>
# Extracts SOURCES_DIR/<filename> into SOURCES_DIR/<dir-name>.
# Idempotent: skips extraction if the directory already exists.
# Handles any top-level directory name inside the archive.
extract_source() {
    local filename="$1" dir_name="$2"
    local src_dir="${SOURCES_DIR}/${dir_name}"

    if [ -d "$src_dir" ]; then
        log_step "Already extracted: ${dir_name}"
        return 0
    fi

    log_step "Extracting: ${filename}"
    local tarball="${SOURCES_DIR}/${filename}"
    local tmp_dir="${SOURCES_DIR}/.tmp_extract_$$"
    mkdir -p "$tmp_dir"

    case "$filename" in
        *.tar.gz|*.tgz)  tar -xzf "$tarball" -C "$tmp_dir" ;;
        *.tar.xz)        tar -xJf "$tarball" -C "$tmp_dir" ;;
        *.tar.bz2)       tar -xjf "$tarball" -C "$tmp_dir" ;;
        *.zip)           unzip -q  "$tarball" -d "$tmp_dir" ;;
        *)
            echo "ERROR: Unknown archive format: ${filename}" >&2
            rm -rf "$tmp_dir"
            exit 1
            ;;
    esac

    # Move the single top-level entry to the canonical location,
    # regardless of what it was named inside the archive.
    local entries=("${tmp_dir}"/*)
    if [ ${#entries[@]} -ne 1 ] || [ ! -d "${entries[0]}" ]; then
        echo "ERROR: Expected exactly one top-level directory in ${filename}" >&2
        rm -rf "$tmp_dir"
        exit 1
    fi
    mv "${entries[0]}" "$src_dir"
    rm -rf "$tmp_dir"
    log_step "Extracted to: ${src_dir}"
}

# ---------------------------------------------------------------------------
# Patch application
# ---------------------------------------------------------------------------

# apply_patches <dep-name> <source-dir>
# Applies all *.patch files from patches/<dep-name>/ in sorted order.
apply_patches() {
    local dep_name="$1" src_dir="$2"
    local patches_dir="${ROOT_DIR}/patches/${dep_name}"

    [ -d "$patches_dir" ] || return 0

    local patches=("${patches_dir}"/*.patch)
    # glob expands to literal path if no matches
    [ -e "${patches[0]}" ] || return 0

    for patch_file in "${patches[@]}"; do
        log_step "Applying: $(basename "$patch_file")"
        patch -d "$src_dir" -p1 < "$patch_file"
    done
}

# ---------------------------------------------------------------------------
# Path helpers
# ---------------------------------------------------------------------------

# get_prefix <arch>  →  $INSTALL_DIR/<arch>
get_prefix() {
    echo "${INSTALL_DIR}/$1"
}

# get_build_dir <dep-name> <arch>  →  $BUILD_DIR/<dep-name>/<arch>
get_build_dir() {
    echo "${BUILD_DIR}/$1/$2"
}

# get_host_triple <arch>  →  autotools host triple string
get_host_triple() {
    case "$1" in
        arm64)  echo "aarch64-apple-darwin" ;;
        x86_64) echo "x86_64-apple-darwin"  ;;
        *) echo "ERROR: Unknown arch: $1" >&2; exit 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Per-arch compiler environment
# ---------------------------------------------------------------------------

# setup_arch_env <arch>
# Exports CFLAGS, CXXFLAGS, OBJCFLAGS, LDFLAGS, PKG_CONFIG_PATH, HOST_TRIPLE.
# Call this at the top of each build_for_arch() function.
setup_arch_env() {
    local arch="$1"
    local prefix
    prefix="$(get_prefix "$arch")"

    local base_flags="-arch ${arch} -mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET} -isysroot ${MACOS_SDK}"

    export CFLAGS="${base_flags} -O2"
    export CXXFLAGS="${base_flags} -O2"
    export OBJCFLAGS="${base_flags} -O2"
    export LDFLAGS="${base_flags}"
    export PKG_CONFIG_PATH="${prefix}/lib/pkgconfig"
    export PKG_CONFIG_LIBDIR="${prefix}/lib/pkgconfig"
    export HOST_TRIPLE="$(get_host_triple "$arch")"

    mkdir -p "${prefix}/lib/pkgconfig"
}

# ---------------------------------------------------------------------------
# Universal binary merging
# ---------------------------------------------------------------------------

# lipo_merge <dep-name>
# For each non-symlink .dylib in install/arm64/lib/ that also exists in
# install/x86_64/lib/, runs lipo -create and writes to output/lib/.
# Silently skips if either arch prefix is absent (single-arch CI job).
lipo_merge() {
    local dep_name="$1"
    local arm64_lib="${INSTALL_DIR}/arm64/lib"
    local x86_64_lib="${INSTALL_DIR}/x86_64/lib"

    if [ ! -d "$arm64_lib" ] || [ ! -d "$x86_64_lib" ]; then
        log_step "lipo_merge ${dep_name}: single-arch build, skipping"
        return 0
    fi

    mkdir -p "${OUTPUT_DIR}/lib" "${OUTPUT_DIR}/include"

    find "$arm64_lib" -name "*.dylib" ! -type l | while read -r arm_lib; do
        local libname x86_lib out_lib
        libname="$(basename "$arm_lib")"
        x86_lib="${x86_64_lib}/${libname}"
        out_lib="${OUTPUT_DIR}/lib/${libname}"

        if [ -f "$x86_lib" ]; then
            lipo -create "$arm_lib" "$x86_lib" -output "$out_lib"
            log_step "lipo: ${libname}"
        else
            cp "$arm_lib" "$out_lib"
            log_step "lipo: ${libname} (arm64 only)"
        fi
    done

    # Re-create version symlinks (e.g. libogg.0.dylib → libogg.dylib)
    find "$arm64_lib" -name "*.dylib" -type l | while read -r link; do
        local linkname target
        linkname="$(basename "$link")"
        target="$(readlink "$link")"
        ln -sf "$target" "${OUTPUT_DIR}/lib/${linkname}" 2>/dev/null || true
    done
}
