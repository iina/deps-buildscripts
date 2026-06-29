#!/bin/bash
# Combines per-arch install prefixes into universal binaries in output/.
# Runs on the machine that has downloaded both arm64 and x86_64 artifacts.
set -euo pipefail
source "$(dirname "$0")/common.sh"

ARM64_LIB="${INSTALL_DIR}/arm64/lib"
X86_64_LIB="${INSTALL_DIR}/x86_64/lib"
ARM64_INC="${INSTALL_DIR}/arm64/include"
UNIVERSAL_LIB="${OUTPUT_DIR}/lib"
UNIVERSAL_INC="${OUTPUT_DIR}/include"

mkdir -p "$UNIVERSAL_LIB" "$UNIVERSAL_INC"

# Merge non-symlink dylibs
find "$ARM64_LIB" -name "*.dylib" ! -type l | while read -r arm_lib; do
    local_name="$(basename "$arm_lib")"
    x86_lib="${X86_64_LIB}/${local_name}"
    out_lib="${UNIVERSAL_LIB}/${local_name}"

    if [ -f "$x86_lib" ]; then
        lipo -create "$arm_lib" "$x86_lib" -output "$out_lib"
        log_step "lipo: ${local_name}"
    else
        log_step "WARN: no x86_64 counterpart for ${local_name} — copying arm64"
        cp "$arm_lib" "$out_lib"
    fi
done

# Re-create dylib version symlinks from the arm64 artifacts (present in local
# builds; absent in CI where staging strips symlinks).
find "$ARM64_LIB" -name "*.dylib" -type l | while read -r link; do
    link_name="$(basename "$link")"
    target="$(readlink "$link")"
    ln -sf "$target" "${UNIVERSAL_LIB}/${link_name}" 2>/dev/null || true
done

# For CI: staging only copies real files, so soname symlinks are missing.
# Recreate them by reading each lipo'd file's LC_ID_DYLIB.  If the soname
# (e.g. libavcodec.62.dylib) differs from the filename on disk
# (e.g. libavcodec.62.28.102.dylib), create the missing symlink so that
# fix-install-names.sh can find and rename/copy it correctly.
find "$UNIVERSAL_LIB" -maxdepth 1 -name "*.dylib" ! -type l | while read -r lib; do
    disk_name="$(basename "$lib")"
    soname_path="$(otool -D "$lib" | awk 'NR==2{print $1}')"
    soname="$(basename "$soname_path")"
    if [ "$soname" != "$disk_name" ] && [ ! -e "${UNIVERSAL_LIB}/${soname}" ]; then
        ln -sf "$disk_name" "${UNIVERSAL_LIB}/${soname}"
        log_step "symlink: $soname → $disk_name"
    fi
done

# Copy headers (architecture-independent — use arm64 as the source)
if [ -d "$ARM64_INC" ]; then
    cp -R "${ARM64_INC}/"* "$UNIVERSAL_INC/"
fi

log_step "Universal binaries written to: ${OUTPUT_DIR}"
