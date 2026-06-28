#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

DEP_NAME="libplacebo"
VERSION="${LIBPLACEBO_VERSION}"
TARBALL="${DEP_NAME}-v${VERSION}.tar.bz2"
SRC_DIR="${SOURCES_DIR}/${DEP_NAME}-${VERSION}"

build_for_arch() {
    local arch="$1"
    local build_dir
    build_dir="$(get_build_dir "$DEP_NAME" "$arch")"

    log_step "=== ${DEP_NAME} ${VERSION} — ${arch} ==="
    setup_arch_env "$arch"

    meson_setup "$build_dir" "$SRC_DIR" "$arch" \
        -Dvulkan=disabled \
        -Dopengl=enabled \
        -Dd3d11=disabled \
        -Ddemos=false \
        -Dtests=false \
        -Dshaderc=disabled \
        -Dglslang=disabled \
        -Dlcms=enabled

    ninja -C "$build_dir" -j"$JOBS"
    ninja -C "$build_dir" install
}

download_and_verify "$LIBPLACEBO_URL" "$LIBPLACEBO_SHA256" "$TARBALL"
extract_source "$TARBALL" "${DEP_NAME}-${VERSION}"
apply_patches "$DEP_NAME" "$SRC_DIR"

for arch in $ARCHS; do build_for_arch "$arch"; done
lipo_merge "$DEP_NAME"
