#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

DEP_NAME="libbluray"
VERSION="${LIBBLURAY_VERSION}"
TARBALL="${DEP_NAME}-${VERSION}.tar.xz"
SRC_DIR="${SOURCES_DIR}/${DEP_NAME}-${VERSION}"

build_for_arch() {
    local arch="$1"
    local prefix build_dir
    prefix="$(get_prefix "$arch")"
    build_dir="$(get_build_dir "$DEP_NAME" "$arch")"

    log_step "=== ${DEP_NAME} ${VERSION} — ${arch} ==="
    setup_arch_env "$arch"

    rm -rf "$build_dir" && mkdir -p "$build_dir"
    cd "$build_dir"

    PKG_CONFIG_PATH="${prefix}/lib/pkgconfig" \
    "${SRC_DIR}/configure" \
        --prefix="$prefix" \
        --host="$HOST_TRIPLE" \
        --enable-shared \
        --disable-static \
        --disable-bdjava-jar \
        --disable-examples \
        --disable-doxygen-doc \
        --without-libxml2

    make -j"$JOBS"
    make install
}

download_and_verify "$LIBBLURAY_URL" "$LIBBLURAY_SHA256" "$TARBALL"
extract_source "$TARBALL" "${DEP_NAME}-${VERSION}"
apply_patches "$DEP_NAME" "$SRC_DIR"

for arch in $ARCHS; do build_for_arch "$arch"; done
lipo_merge "$DEP_NAME"
