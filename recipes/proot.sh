#!/bin/sh
# shellcheck disable=SC2046 # sb_cmake_args/sb_cflags are flag lists
# deps: build-base git
# proot — ptrace-based chroot without root. The reason a sandboxed app can run a
# full Alpine rootfs it did not install.
. "$(dirname "$0")/_common.sh"
sb_init

sb_git https://github.com/termux/proot.git "v$SB_VERSION" proot
sb_cd "$SB_WORK/src/proot/src"

make -j "$SB_JOBS" CC="${CC:-cc}" \
  CFLAGS="$(sb_cflags) $([ "$SB_FAMILY" = elf ] && echo -static) -DPROOT_VERSION=\\\"$SB_VERSION\\\"" \
  LDFLAGS="$([ "$SB_FAMILY" = elf ] && echo -static) -s"

sb_bin proot proot
export SB_PATHS="bin"
export SB_ENTRY="bin/proot"
export SB_ENV='"PROOT_NO_SECCOMP": "1"'
sb_finish
