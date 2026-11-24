#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

DEP_NAME="shaderc"
VERSION="${SHADERC_VERSION}"
TARBALL="${DEP_NAME}-${VERSION}.tar.xz"
SRC_DIR="${SOURCES_DIR}/${DEP_NAME}-${VERSION}"

clone_source() {
    if [ -d "$SRC_DIR" ]; then
        log_step "Already cloned: ${DEP_NAME} v${VERSION}"
        return 0
    fi
    log_step "Cloning: ${DEP_NAME} v${VERSION}"
    git clone --recurse-submodules --depth 1 \
        --branch "v${VERSION}" \
        "${SHADERC_REPO}" \
        "$SRC_DIR"
    cd "$SRC_DIR"
    ./utils/git-sync-deps
}

build_for_arch() {
    local arch="$1"
    local build_dir
    build_dir="$(get_build_dir "$DEP_NAME" "$arch")"

    log_step "=== ${DEP_NAME} ${VERSION} — ${arch} ==="
    setup_arch_env "$arch"

    cmake_configure "$build_dir" "$SRC_DIR" "$arch" \
        -DSHADERC_SKIP_TESTS=ON \
        -DSKIP_GLSLANG_INSTALL=ON \
        -DSKIP_SPIRV_TOOLS_INSTALL=ON \
        -DSKIP_GOOGLETEST_INSTALL=ON

    cmake --build "$build_dir" -j"$JOBS"
    cmake --install "$build_dir"
}

clone_source
apply_patches "$DEP_NAME" "$SRC_DIR"

for arch in $ARCHS; do build_for_arch "$arch"; done
