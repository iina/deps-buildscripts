#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

DEP_NAME="luajit"
# LuaJIT uses a rolling commit rather than versioned releases
COMMIT="${LUAJIT_COMMIT}"
TARBALL="${DEP_NAME}-${COMMIT}.tar.gz"

build_for_arch() {
    local arch="$1"
    local prefix src_dir
    prefix="$(get_prefix "$arch")"
    # Each arch gets its own in-source copy because LuaJIT's build system
    # does not support out-of-tree builds and leaves state in the source tree.
    src_dir="${BUILD_DIR}/${DEP_NAME}-${arch}"

    log_step "=== ${DEP_NAME} ${COMMIT} — ${arch} ==="
    setup_arch_env "$arch"

    rm -rf "$src_dir"
    cp -R "${SOURCES_DIR}/${DEP_NAME}-${COMMIT}" "$src_dir"

    local target_cflags="-arch ${arch} -mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET}"
    local native_arch; native_arch="$(uname -m)"

    if [ "$arch" = "$native_arch" ]; then
        # Native build — straightforward
        make -C "$src_dir" -j"$JOBS" \
            MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET}" \
            XCFLAGS="${target_cflags}" \
            PREFIX="$prefix" \
            DEFAULT_CC=clang \
            amalg
    else
        # Cross-compile (e.g. x86_64 target on an arm64 host).
        #
        # macOS has no arch-prefixed toolchain (there is no x86_64-apple-darwin-gcc);
        # clang cross-compiles via -arch, so CROSS must stay empty — otherwise the
        # Makefile invokes "<CROSS>gcc" and dies with "Unsupported target architecture".
        #
        # The host tools (minilua, buildvm) execute on the BUILD machine during the
        # build, so they must be compiled for the native arch. LuaJIT's HOST_ACFLAGS
        # pulls in CCOPTIONS, which contains $(XCFLAGS) and $(CFLAGS) — so the target
        # -arch must NOT travel through those vars or the host tools get built for the
        # foreign arch and can't run. We therefore:
        #   - pass the target -arch only via TARGET_FLAGS (target-only by design), and
        #   - blank CFLAGS/LDFLAGS on the make command line (setup_arch_env exports them
        #     with -arch <target>, and they'd otherwise leak into the host build).
        # Command-line assignments override the inherited environment in make.
        make -C "$src_dir" -j"$JOBS" \
            MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET}" \
            CC="clang" \
            HOST_CC="clang" \
            CFLAGS="" \
            LDFLAGS="" \
            TARGET_FLAGS="${target_cflags}" \
            PREFIX="$prefix" \
            amalg
    fi

    make -C "$src_dir" install PREFIX="$prefix"
}

download_and_verify "$LUAJIT_URL" "$LUAJIT_SHA256" "$TARBALL"
extract_source "$TARBALL" "${DEP_NAME}-${COMMIT}"
apply_patches "$DEP_NAME" "${SOURCES_DIR}/${DEP_NAME}-${COMMIT}"

for arch in $ARCHS; do build_for_arch "$arch"; done
lipo_merge "$DEP_NAME"
