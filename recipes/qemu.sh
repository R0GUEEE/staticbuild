#!/bin/sh
# deps: build-base python3 glib-dev pixman-dev
# qemu-user-static — one static binary per guest arch. This is how a phone runs
# an x86_64 CI artifact, and how the iSH guest gets a second architecture.
. "$(dirname "$0")/_common.sh"
sb_init

src=$(sb_fetch "https://download.qemu.org/qemu-$SB_VERSION.tar.xz")
sb_unpack "$src" "$SB_WORK/src/qemu"
sb_cd "$SB_WORK/src/qemu/qemu-$SB_VERSION"

sb_configure --static --prefix=/usr \
  --target-list="aarch64-linux-user arm-linux-user i386-linux-user x86_64-linux-user riscv64-linux-user" \
  --disable-system --disable-docs --disable-tools --disable-guest-agent \
  --disable-capstone --disable-vnc --disable-gtk --disable-sdl --disable-opengl \
  --disable-curl --disable-libssh --disable-glusterfs --disable-bzip2 \
  --disable-debug-tcg

make -j "$SB_JOBS"

for q in qemu-aarch64 qemu-arm qemu-i386 qemu-x86_64 qemu-riscv64; do
  [ -x "build/$q" ] && sb_bin "build/$q" "$q"
done

export SB_PATHS="bin"
export SB_ENTRY="bin/qemu-x86_64"
sb_finish
