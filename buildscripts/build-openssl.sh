#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

DEP_NAME="openssl"
VERSION="${OPENSSL_VERSION}"
TARBALL="${DEP_NAME}-${VERSION}.tar.gz"
SRC_DIR="${SOURCES_DIR}/${DEP_NAME}-${VERSION}"

build_for_arch() {
    local arch="$1"
    local prefix build_dir target
    prefix="$(get_prefix "$arch")"
    build_dir="$(get_build_dir "$DEP_NAME" "$arch")"

    case "$arch" in
        arm64)  target="darwin64-arm64-cc" ;;
        x86_64) target="darwin64-x86_64-cc" ;;
        *) echo "ERROR: Unknown arch: ${arch}" >&2; exit 1 ;;
    esac

    log_step "=== ${DEP_NAME} ${VERSION} — ${arch} ==="
    setup_arch_env "$arch"

    rm -rf "$build_dir" && mkdir -p "$(dirname "$build_dir")"
    cp -R "$SRC_DIR" "$build_dir"
    cd "$build_dir"

    ./Configure "$target" \
        --prefix="$prefix" \
        --libdir=lib \
        --openssldir=/etc/ssl \
        shared \
        no-tests \
        no-apps \
        no-docs

    make -j"$JOBS"
    make install_sw
}

download_and_verify "$OPENSSL_URL" "$OPENSSL_SHA256" "$TARBALL"
extract_source "$TARBALL" "${DEP_NAME}-${VERSION}"
apply_patches "$DEP_NAME" "$SRC_DIR"

for arch in $ARCHS; do build_for_arch "$arch"; done
