#!/bin/sh
# deps: build-base cmake zstd-dev
# ccache — turns the 40-minute LLVM rebuild above into a 4-minute one.
. "$(dirname "$0")/_common.sh"
sb_init

src=$(sb_fetch "https://github.com/ccache/ccache/releases/download/v$SB_VERSION/ccache-$SB_VERSION.tar.gz")
sb_unpack "$src" "$SB_WORK/src/ccache"
sb_cd "$SB_WORK/src/ccache/ccache-$SB_VERSION"

_DEFS="-DREDIS_STORAGE_BACKEND=OFF -DENABLE_DOCS=OFF -DENABLE_TESTING=OFF -DDEPS=OFF -DCMAKE_SKIP_RPATH=ON"

case "$SB_FAMILY" in
  elf)
    # shellcheck disable=SC2046 # word splitting is the point
    cmake -B out $(sb_cmake_args) -G "Unix Makefiles" -DCMAKE_BUILD_TYPE=Release $_DEFS \
      -DZSTD_FROM_INTERNET=ON \
      # shellcheck disable=SC2046 # word splitting is the point
      -DCMAKE_CXX_FLAGS="$(sb_cflags)" -DCMAKE_EXE_LINKER_FLAGS="-static -s"
    ;;
  macho)
    # shellcheck disable=SC2046 # word splitting is the point
    cmake -B out $(sb_cmake_args) -G "Unix Makefiles" -DCMAKE_BUILD_TYPE=Release $_DEFS \
      -DZSTD_FROM_INTERNET=ON \
      -DCMAKE_OSX_ARCHITECTURES="$SB_ARCH" -DCMAKE_OSX_SYSROOT="${SB_SDK:-iphoneos}"
    ;;
esac
cmake --build out -j "$SB_JOBS"

sb_bin out/ccache ccache
export SB_PATHS="bin"
export SB_ENTRY="bin/ccache"
sb_finish
