#!/bin/sh
# deps: (none)
# Zig — one tarball, one binary, and the libc provider the other recipes use
# for `zig cc -target aarch64-ios`.
. "$(dirname "$0")/_common.sh"
sb_init

case "$SB_TARGET" in
  linux-arm64)  _t=aarch64-linux ;;
  linux-x86_64) _t=x86_64-linux ;;
  macos-arm64)  _t=aarch64-macos ;;
  *) die "zig: no host tarball for $SB_TARGET" ;;
esac

_url="https://ziglang.org/download/$SB_VERSION/zig-$_t-$SB_VERSION.tar.xz"
src=$(sb_fetch "$_url")
sb_unpack "$src" "$SB_WORK/src/zig"
_root="$SB_WORK/src/zig/zig-$_t-$SB_VERSION"

# Ship the compiler and its std sources; drop the docs and the C headers we do
# not need for the targets we ship. `zig env` still works: it reads the layout.
mkdir -p "$SB_STAGE/lib"
cp "$_root/zig" "$SB_STAGE/bin/zig"
chmod 755 "$SB_STAGE/bin/zig"
( cd "$_root/lib" && tar -cf - --exclude='docs' --exclude='*.html' . ) | \
  ( cd "$SB_STAGE/lib" && tar -xf - )
cp "$_root/LICENSE" "$SB_STAGE/.sb/LICENSE" 2>/dev/null || true

SB_PATHS="bin"
SB_ENTRY="bin/zig"
sb_layer lib
sb_finish
