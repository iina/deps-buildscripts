# IINA dependency build scripts

This repo holds build scripts that build the dependencies for IINA. Unlike the old method (https://github.com/iina/homebrew-mpv-iina), we do not depend on Homebrew to compile libraries; brew is only used to download some build tools.

This build system is only tested on the latest macOS releases. Older versions of macOS might happen to work, but there is no guarantee.

## Building Tools
Make sure they are installed and available in PATH.

- meson
- ninja
- cmake
- pkg-config
- automake (also autoconf)
- nasm (for x86 assembly builds, e.g. FFmpeg and dav1d)

Assuming homebrew is installed. To install all:

```bash
brew install meson ninja pkg-config automake nasm
```

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
./build.sh arm64  # For arm builds
./build.sh x86_64 # For x86 builds
./build.sh all    # Default
```

The build scripts only compile each package and install it into `install/<arch>/`; they do no lipo, install-name, or signing work. When building `all`, cross compilation is enabled and the post-build packaging step runs automatically (see below).

After installing all dependencies, we should fix their install names before creating universal binaries.

```bash
./fix-install-names.sh arm64
./fix-install-names.sh x86_64
./fix-install-names.sh all     # Default
```

Use `lipo.sh` to create universal binaries. This script will find all `dylibs` in `output/arm64/` and `output/x86_64` and `lipo` them into `output/fat`. An ad-hoc sign will also be performed after lipo'ing.

```bash
./lipo.sh
```

Finally, copy the headers used by IINA to `output/include/`:

```bash
./copy-headers.sh
```

## Source & Cache

The source code download point and version used for each library is defined in [`versions.env`](versions.env). There are 2 ways of acquiring source code:

- Tarball download. Tarball URL, version, and SHA256 are required.
- Git repo download. Repo URL and version tag are required. This is sometimes needed for acquiring submodules, which are typically missing in the tarballs (`libplacebo`).

The downloaded source code is stored in `sources/`, and temporary build files are in `build/`; delete these folders if you want to remove the cache.

## Patches

If patches need to be applied, put them under `patches/{package_name}`.
