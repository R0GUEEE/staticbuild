#!/bin/sh
# deps: build-base cmake python3
# Ninja — 12 KiB of build graph executor, the one tool every other recipe uses.
. "$(dirname "$0")/_common.sh"
sb_init

src=$(sb_fetch "https://github.com/ninja-build/ninja/archive/refs/tags/v$SB_VERSION.tar.gz")
sb_unpack "$src" "$SB_WORK/src/ninja"

sb_cd "$SB_WORK/src/ninja/ninja-$SB_VERSION"

case "$SB_FAMILY" in
  pe)
    # ninja's own build is CMake; cross-configuring CMake for mingw is more
    # moving parts than compiling the sources directly.
    _cxx=$(sb_cc | sed 's/gcc$/g++/; s/cc$/c++/')
    $_cxx -O2 -std=c++17 $(sb_cflags) -o ninja.exe src/*.cc || die "ninja: mingw build failed"
    sb_bin ninja.exe ninja.exe
    ;;
  elf)
    cmake -B out -G "Unix Makefiles" \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_FLAGS="-O2" -DCMAKE_CXX_FLAGS="-O2" \
      -DCMAKE_EXE_LINKER_FLAGS="-static" \
      -DCMAKE_SKIP_RPATH=ON -DBUILD_TESTING=OFF
    cmake --build out -j "$SB_JOBS"
    sb_bin out/ninja ninja
    ;;
  macho)
    cmake -B out -G "Unix Makefiles" \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_OSX_ARCHITECTURES="$SB_ARCH" \
      -DCMAKE_OSX_SYSROOT="${SB_SDK:-iphoneos}" \
      -DCMAKE_OSX_DEPLOYMENT_TARGET="${SB_MIN_OS:-15.0}" \
      -DCMAKE_SKIP_RPATH=ON -DBUILD_TESTING=OFF
    cmake --build out -j "$SB_JOBS"
    sb_bin out/ninja ninja
    ;;
esac

sb_symlinks samu
export SB_PATHS=bin
sb_finish
