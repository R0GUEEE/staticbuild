#!/bin/sh
# deps: build-base
# zstd — the payload format of every bundle in this repo, so it ships first.
. "$(dirname "$0")/_common.sh"
sb_init

src=$(sb_fetch "https://github.com/facebook/zstd/archive/refs/tags/v$SB_VERSION.tar.gz")
sb_unpack "$src" "$SB_WORK/src/zstd"
cd "$SB_WORK/src/zstd/zstd-$SB_VERSION"

case "$SB_FAMILY" in
  elf)   _ld="-static" ;;
  macho) _ld="" ;;
esac

make -C lib -j "$SB_JOBS" libzstd.a CFLAGS="$(sb_cflags)"
make -C programs -j "$SB_JOBS" zstd MOREFLAGS="$(sb_cflags) $_ld -DZSTD_MULTITHREAD"

sb_bin programs/zstd zstd
sb_symlinks zstdcat unzstd zstdmt
SB_PATHS=bin
sb_finish
