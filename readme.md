# IINA dependency build scripts

This repo holds build scripts that can build the dependencies for IINA. Unlike the old method (https://github.com/iina/homebrew-mpv-iina), we are not depending on Homebrew to compile libraries; brew is only used to download some building tools.

## Building Tools
Make sure they are available in PATH, otherwise the script will try to automatically install them from Homebrew.
- meson
- ninja
- cmake
- pkg-config
- automake (also autoconf)
- rust (for `dav1d`, can be installed via rustup)
- cargo-c (for `dav1d` as well, installed via `cargo install cargo-c`)
- nasm (for FFmpeg x86 builds)

## Structure
All dependencies are divided in to 4 layers, which defines the order of compilation.

- **Layer 1**: Leaf libraries that dones't depend on other libraries. All encoders and decoders are also in this layer since their dependency tree is straightfoward.
- **Layer 2**: Other libraries with layer 1 dependencies.
- **Layer 3**: Core media libraries: FFmpeg, libplacebo, libbluray, and libass. More imporant and directly depended by mpv.
- **Layer 4**: mpv.

Since layer 3 and layer 4 packages are more imporant since they are directly used by libmpv, we need to make clear decisions on their compilation flags, especially when updating their versions.

## Usage

First prepare the building dependencies. If tools are missing in the current environment, the script will try to install them via `brew install`.

```bash
./build.sh arm64 # For arm builds
./build.sh x86_64 # For x86 builds
./build.sh all
```

When building for both architectures, cross compilation will be enabled, and fat libraries will be generated. After successfully generated all dependencies needed, we have to fix their install names to @rpath for them to find dependencies when bundled.

```bash
./fix-install-names.sh install/arm64/lib/ output/
```

The script will try to find `libmpv.*.dylib` from the first path provided (default to `install/arm64/lib/`), and perform a BFS from the found libmpv to make sure the install name for every dependencies is fixed. The resulting binaries are copied to the second path provided (default to `output/`). Note that the original binaries in the install folder are not touched; only the copies are fixed.

## Source & Cache

The source code download point and version used for each library is defined in [`versions.env`](versions.env).There are 2 ways of acquiring source code:

- Tarball download. Tarball URL, version, and SHA256 are required.
- Git repo download. Repo URL, version tag are requried. This is sometimes needed for acquiring submodules which are typically missing in the tallballs (`libplacebo`).

The downloaded source code is stored in `sources/`, tempory build files are in `build/`; delete these folders if you want to remove the cache.

## Patches

If patches are need to be compiled with, put them under `patches/{package_name}`.
