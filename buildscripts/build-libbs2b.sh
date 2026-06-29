#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

DEP_NAME="libbs2b"
VERSION="${LIBBS2B_VERSION}"
TARBALL="${DEP_NAME}-${VERSION}.tar.gz"
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

    "${SRC_DIR}/configure" \
        --prefix="$prefix" \
        --host="$HOST_TRIPLE" \
        --enable-shared \
        --disable-static

    make -j"$JOBS"
    make install
}

download_and_verify "$LIBBS2B_URL" "$LIBBS2B_SHA256" "$TARBALL"
extract_source "$TARBALL" "${DEP_NAME}-${VERSION}"
apply_patches "$DEP_NAME" "$SRC_DIR"

# The shipped configure is stale — regenerate it so config.sub knows about aarch64-apple-darwin.
# dist-lzma was removed in modern automake; sndfile is only needed by CLI tools, not the library.
sed -i '' 's/dist-lzma//' "${SRC_DIR}/configure.ac"
sed -i '' '/PKG_CHECK_EXISTS.*sndfile/,/])/d' "${SRC_DIR}/configure.ac"
sed -i '' '/^bin_PROGRAMS/,/^$/d' "${SRC_DIR}/src/Makefile.am"
autoreconf --force --verbose --install "$SRC_DIR"

for arch in $ARCHS; do build_for_arch "$arch"; done
lipo_merge "$DEP_NAME"
