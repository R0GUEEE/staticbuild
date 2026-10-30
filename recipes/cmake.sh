#!/bin/sh
# deps: build-base make
# CMake, bootstrapped without curl/openssl so it links nothing.
# `--parallel` and `-DCMAKE_USE_OPENSSL=OFF` are the two flags that decide whether
# this builds in 6 minutes or 40.
. "$(dirname "$0")/_common.sh"
sb_init

src=$(sb_fetch "https://github.com/Kitware/CMake/releases/download/v$SB_VERSION/cmake-$SB_VERSION.tar.gz")
sb_unpack "$src" "$SB_WORK/src/cmake"
cd "$SB_WORK/src/cmake/cmake-$SB_VERSION"

case "$SB_FAMILY" in
  elf)
    ./bootstrap --parallel="$SB_JOBS" --prefix=/usr \
      -- -DCMAKE_USE_OPENSSL=OFF -DBUILD_CursesDialog=OFF -DBUILD_TESTING=OFF \
         -DCMAKE_C_FLAGS="$(sb_cflags)" -DCMAKE_CXX_FLAGS="$(sb_cflags)" \
         -DCMAKE_EXE_LINKER_FLAGS="-static"
    ;;
  macho)
    ./bootstrap --parallel="$SB_JOBS" --prefix=/usr \
      -- -DCMAKE_USE_OPENSSL=OFF -DBUILD_CursesDialog=OFF -DBUILD_TESTING=OFF \
         -DCMAKE_OSX_ARCHITECTURES="$SB_ARCH" -DCMAKE_OSX_SYSROOT="${SB_SDK:-iphoneos}"
    ;;
esac

make -j "$SB_JOBS"
make install DESTDIR="$SB_WORK/cmake-dist"

_p="$SB_WORK/cmake-dist/usr"
sb_bin "$_p/bin/cmake" cmake
sb_bin "$_p/bin/ctest" ctest
sb_bin "$_p/bin/cpack" cpack
mkdir -p "$SB_STAGE/share"
cp -R "$_p/share/cmake-$SB_VERSION" "$SB_STAGE/share/"

SB_PATHS="bin"
SB_ENTRY="bin/cmake"
SB_ENV='"CMAKE_ROOT": "${ROOT}/share/cmake-'"$SB_VERSION"'"'
sb_layer "share/cmake-$SB_VERSION"
sb_finish
