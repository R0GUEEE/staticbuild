#!/bin/sh
# deps: build-base autoconf automake libtool
# patchelf — rewrites RPATH/NEEDED on ELF. Needed by every downstream project
# that packages a dynamic tool into an app bundle.
. "$(dirname "$0")/_common.sh"
sb_init

src=$(sb_fetch "https://github.com/NixOS/patchelf/releases/download/$SB_VERSION/patchelf-$SB_VERSION.tar.gz")
sb_unpack "$src" "$SB_WORK/src/patchelf"
cd "$SB_WORK/src/patchelf/patchelf-$SB_VERSION"

./bootstrap.sh 2>/dev/null || autoreconf -fi
./configure --prefix=/usr CXXFLAGS="$(sb_cflags) $([ "$SB_FAMILY" = elf ] && echo -static)" \
  LDFLAGS="$([ "$SB_FAMILY" = elf ] && echo -static) -s"
make -j "$SB_JOBS"

sb_bin src/patchelf patchelf
SB_PATHS="bin"
SB_ENTRY="bin/patchelf"
sb_finish
