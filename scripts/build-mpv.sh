#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

DEP_NAME="mpv"
VERSION="${MPV_VERSION}"
TARBALL="${DEP_NAME}-${VERSION}.tar.gz"
SRC_DIR="${SOURCES_DIR}/${DEP_NAME}-${VERSION}"

build_for_arch() {
    local arch="$1"
    local build_dir prefix
    build_dir="$(get_build_dir "$DEP_NAME" "$arch")"
    prefix="$(get_prefix "$arch")"

    log_step "=== ${DEP_NAME} ${VERSION} — ${arch} ==="
    setup_arch_env "$arch"

    # ffmpeg was built as static libs; tell pkg-config to expose their private
    # dependencies so the linker pulls in all transitive static-lib flags.
    export PKG_CONFIG_PATH="${prefix}/lib/pkgconfig"
    export PKG_CONFIG="${PKG_CONFIG:-pkg-config}"

    meson_setup "$build_dir" "$SRC_DIR" "$arch" \
        -Dlibmpv=true \
        -Dcplayer=false \
        -Dlua=luajit \
        -Djavascript=enabled \
        -Dlcms2=enabled \
        -Dvulkan=disabled \
        -Dgl=enabled \
        -Dcocoa=enabled \
        -Dzimg=enabled \
        -Dlibbluray=enabled \
        -Dlibarchive=enabled \
        -Duchardet=enabled \
        -Djpeg=enabled \
        -Dswift-build=disabled \
        -Dtests=false

    ninja -C "$build_dir" -j"$JOBS"
    ninja -C "$build_dir" install
}

download_and_verify "$MPV_URL" "$MPV_SHA256" "$TARBALL"
extract_source "$TARBALL" "${DEP_NAME}-${VERSION}"
apply_patches "$DEP_NAME" "$SRC_DIR"

for arch in $ARCHS; do build_for_arch "$arch"; done
lipo_merge "$DEP_NAME"
