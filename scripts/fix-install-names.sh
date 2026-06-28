#!/bin/bash
# Rewrites LC_ID_DYLIB and LC_LOAD_DYLIB entries in every dylib under
# OUTPUT_DIR/lib so all references to our own libraries use @rpath.
# System library paths (/usr/lib, /System, etc.) are left untouched.
set -euo pipefail
source "$(dirname "$0")/common.sh"

lib_dir="${OUTPUT_DIR}/lib"

# Collect basenames of all real dylibs we built (the universe of @rpath names)
our_libs=()
while IFS= read -r f; do
    our_libs+=("$(basename "$f")")
done < <(find "$lib_dir" -maxdepth 1 -name "*.dylib" ! -type l)

for dylib in "$lib_dir"/*.dylib; do
    [ -L "$dylib" ] && continue
    libname="$(basename "$dylib")"
    log_step "Fixing: $libname"

    # Rewrite own install name
    install_name_tool -id "@rpath/$libname" "$dylib"

    # Rewrite each dependency that matches one of our own libs
    while IFS= read -r dep; do
        depname="$(basename "$dep")"
        for our_lib in "${our_libs[@]}"; do
            if [ "$depname" = "$our_lib" ] && [ "$dep" != "@rpath/$depname" ]; then
                install_name_tool -change "$dep" "@rpath/$depname" "$dylib"
                break
            fi
        done
    done < <(otool -L "$dylib" | tail -n +2 | awk '{print $1}')
done

log_step "Done fixing install names."
