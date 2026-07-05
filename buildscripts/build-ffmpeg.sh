#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

DEP_NAME="ffmpeg"
VERSION="${FFMPEG_VERSION}"
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

    local native_arch; native_arch="$(uname -m)"
    local cross_compile_flag=""
    if [ "$arch" != "$native_arch" ]; then
        cross_compile_flag="--enable-cross-compile"
    fi

    "${SRC_DIR}/configure" \
        --prefix="$prefix" \
        --arch="${arch}" \
        --target-os=darwin \
        --cc=clang \
        --cxx=clang++ \
        --extra-cflags="${CFLAGS} -I${prefix}/include" \
        --extra-ldflags="${LDFLAGS} -L${prefix}/lib" \
        --pkg-config=pkg-config \
        --enable-gpl \
        --enable-shared \
        --disable-static \
        --disable-programs \
        --disable-doc \
        --disable-debug \
        --enable-network \
        --enable-securetransport \
        --enable-videotoolbox \
        --enable-audiotoolbox \
        --enable-libspeex \
        --enable-libvorbis \
        --enable-libdav1d \
        --enable-libass \
        --enable-libwebp \
        --enable-libjxl \
        --enable-librav1e \
        --enable-libbs2b \
        --enable-libsoxr \
        --enable-librubberband \
        --enable-libzimg \
        --enable-libfontconfig \
        --enable-libfreetype \
        --enable-libfribidi \
        --enable-libharfbuzz \
        ${cross_compile_flag:+$cross_compile_flag}

    make -j"$JOBS"
    make install
}

download_and_verify "$FFMPEG_URL" "$FFMPEG_SHA256" "$TARBALL"
extract_source "$TARBALL" "${DEP_NAME}-${VERSION}"
apply_patches "$DEP_NAME" "$SRC_DIR"

for arch in $ARCHS; do build_for_arch "$arch"; done
