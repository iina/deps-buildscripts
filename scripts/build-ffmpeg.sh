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
        --extra-cflags="${CFLAGS}" \
        --extra-ldflags="${LDFLAGS}" \
        --pkg-config=pkg-config \
        --enable-shared \
        --disable-static \
        --disable-programs \
        --disable-doc \
        --disable-debug \
        --disable-autodetect \
        --enable-avcodec \
        --enable-avformat \
        --enable-avutil \
        --enable-swscale \
        --enable-swresample \
        --enable-avfilter \
        --enable-network \
        --enable-protocol=http,https,file,pipe,crypto,tcp \
        --enable-securetransport \
        --enable-zlib \
        --enable-bzlib \
        --enable-iconv \
        --extra-libs="-liconv" \
        --enable-libvorbis \
        --enable-libopus \
        --enable-libdav1d \
        --enable-libass \
        --enable-demuxer=matroska,mov,mp4,avi,ogg,flac,wav,aac,mp3,srt,ass,webvtt \
        --enable-decoder=h264,hevc,vp8,vp9,av1,aac,mp3,flac,vorbis,opus,srt,ass,webvtt,mpeg4,mpeg2video,mjpeg,png,tiff,bmp \
        --enable-encoder=png,tiff,bmp,mjpeg \
        --enable-muxer=null,md5,rawvideo,image2 \
        --enable-filter=scale,format,aresample,atrim,trim,setpts,fps,colorspace \
        ${cross_compile_flag:+$cross_compile_flag}

    make -j"$JOBS"
    make install
}

download_and_verify "$FFMPEG_URL" "$FFMPEG_SHA256" "$TARBALL"
extract_source "$TARBALL" "${DEP_NAME}-${VERSION}"
apply_patches "$DEP_NAME" "$SRC_DIR"

for arch in $ARCHS; do build_for_arch "$arch"; done
lipo_merge "$DEP_NAME"
