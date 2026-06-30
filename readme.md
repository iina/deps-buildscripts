# IINA dependency build scripts

This repo holds build scripts that build the dependencies for IINA. Unlike the old method (https://github.com/iina/homebrew-mpv-iina), we do not depend on Homebrew to compile libraries; brew is only used to download some build tools.

This build system is only tested on the latest macOS releases. Older versions of macOS might happen to work, but there is no guarantee.

## Building Tools
Make sure they are available in PATH, otherwise the script will try to automatically install them from Homebrew.
- meson
- ninja
- cmake
- pkg-config
- automake (also autoconf)
- rust (for `rav1e`, can be installed via rustup)
- cargo-c (for `rav1e` as well, installed via `cargo install cargo-c`)
- nasm (for x86 assembly builds, e.g. FFmpeg and dav1d)

## Structure
All dependencies are divided into 4 layers, which define the order of compilation.

- **Layer 1**: Leaf libraries that don't depend on other libraries. All encoders and decoders are also in this layer since their dependency tree is straightforward.
- **Layer 2**: Other libraries with layer 1 dependencies.
- **Layer 3**: Core media libraries: FFmpeg, libplacebo, libbluray, and libass. More important and directly depended on by mpv.
- **Layer 4**: mpv.

Since layer 3 and layer 4 packages are directly used by libmpv, we need to make clear decisions on their compilation flags, especially when updating their versions.

## Usage

First prepare the building dependencies. If tools are missing in the current environment, the script will try to install them via `brew install`.

```bash
./build.sh arm64 # For arm builds
./build.sh x86_64 # For x86 builds
./build.sh all
```

When building for both architectures, cross compilation will be enabled, and fat libraries will be generated. After successfully generating all needed dependencies, we have to fix their install names to @rpath so they can find their dependencies when bundled.

```bash
./fix-install-names.sh install/arm64/lib/ output/
```

The script will try to find `libmpv.*.dylib` from the first path provided (default to `install/arm64/lib/`), and perform a BFS from the found libmpv to make sure the install name for every dependencies is fixed. The resulting binaries are copied to the second path provided (default to `output/`). Note that the original binaries in the install folder are not touched; only the copies are fixed.

## Source & Cache

The source code download point and version used for each library is defined in [`versions.env`](versions.env). There are 2 ways of acquiring source code:

- Tarball download. Tarball URL, version, and SHA256 are required.
- Git repo download. Repo URL and version tag are required. This is sometimes needed for acquiring submodules, which are typically missing in the tarballs (`libplacebo`).

The downloaded source code is stored in `sources/`, and temporary build files are in `build/`; delete these folders if you want to remove the cache.

## Patches

If patches need to be applied, put them under `patches/{package_name}`.
