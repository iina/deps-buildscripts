#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

DEP_NAME="rav1e"
VERSION="${RAV1E_VERSION}"
TARBALL="${DEP_NAME}-${VERSION}.tar.gz"
SRC_DIR="${SOURCES_DIR}/${DEP_NAME}-${VERSION}"

build_for_arch() {
    local arch="$1"
    local prefix
    prefix="$(get_prefix "$arch")"

    log_step "=== ${DEP_NAME} ${VERSION} — ${arch} ==="

    local rust_target
    case "$arch" in
        arm64)  rust_target="aarch64-apple-darwin" ;;
        x86_64) rust_target="x86_64-apple-darwin"  ;;
        *)      echo "ERROR: Unknown arch: $arch" >&2; exit 1 ;;
    esac

    # Ensure the target toolchain is available (no-op if already installed).
    rustup target add "$rust_target" 2>/dev/null || true

    ( cd "$SRC_DIR" && \
      MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET}" \
      cargo cinstall \
          --release \
          --target "$rust_target" \
          --prefix="$prefix" \
          --library-type=cdylib
    )
}

# cargo cinstall writes a lockfile relative to cwd; ensure the source directory
# exists before the first build_for_arch call.
download_and_verify "$RAV1E_URL" "$RAV1E_SHA256" "$TARBALL"
extract_source "$TARBALL" "${DEP_NAME}-${VERSION}"
apply_patches "$DEP_NAME" "$SRC_DIR"

for arch in $ARCHS; do build_for_arch "$arch"; done
