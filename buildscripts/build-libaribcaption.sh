#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

DEP_NAME="libaribcaption"
VERSION="${LIBARIBCAPTION_VERSION}"
TARBALL="${DEP_NAME}-${VERSION}.tar.gz"
SRC_DIR="${SOURCES_DIR}/${DEP_NAME}-${VERSION}"

build_for_arch() {
    local arch="$1"
    local build_dir
    build_dir="$(get_build_dir "$DEP_NAME" "$arch")"

    log_step "=== ${DEP_NAME} ${VERSION} — ${arch} ==="
    setup_arch_env "$arch"

    # On Apple platforms the renderer defaults to the CoreText backend, so no
    # FreeType/Fontconfig dependency is pulled in.
    cmake_configure "$build_dir" "$SRC_DIR" "$arch" \
        -DARIBCC_SHARED_LIBRARY=ON \
        -DARIBCC_BUILD_TESTS=OFF \
        -DARIBCC_USE_CORETEXT=ON

    cmake --build "$build_dir" -j"$JOBS"
    cmake --install "$build_dir"
}

download_and_verify "$LIBARIBCAPTION_URL" "$LIBARIBCAPTION_SHA256" "$TARBALL"
extract_source "$TARBALL" "${DEP_NAME}-${VERSION}"
apply_patches "$DEP_NAME" "$SRC_DIR"

for arch in $ARCHS; do build_for_arch "$arch"; done
