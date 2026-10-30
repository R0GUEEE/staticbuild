#!/bin/sh
# deps: (none)
# Zig — one tarball, one binary, and the libc provider the other recipes use
# for `zig cc -target aarch64-ios`.
. "$(dirname "$0")/_common.sh"
sb_init

# The tarball is zig-<os>-<arch>-<version>.tar.xz; note the order, it is the
# reverse of the triple everybody writes first.
case "$SB_TARGET" in
  linux-arm64)  _os=linux;  _arch=aarch64 ;;
  linux-x86_64) _os=linux;  _arch=x86_64 ;;
  macos-arm64)  _os=macos;  _arch=aarch64 ;;
  *) die "zig: no host tarball for $SB_TARGET" ;;
esac

_url="https://ziglang.org/download/$SB_VERSION/zig-$_os-$_arch-$SB_VERSION.tar.xz"
src=$(sb_fetch "$_url")
sb_unpack "$src" "$SB_WORK/src/zig"
_root="$SB_WORK/src/zig/zig-$_os-$_arch-$SB_VERSION"
[ -x "$_root/zig" ] || die "zig: unexpected tarball layout"

# Ship the compiler and its std sources; drop the docs and the C headers we do
# not need for the targets we ship. `zig env` still works: it reads the layout.
mkdir -p "$SB_STAGE/lib"
cp "$_root/zig" "$SB_STAGE/bin/zig"
chmod 755 "$SB_STAGE/bin/zig"
( cd "$_root/lib" && tar -cf - --exclude='docs' --exclude='*.html' . ) | \
  ( cd "$SB_STAGE/lib" && tar -xf - )
cp "$_root/LICENSE" "$SB_STAGE/.sb/LICENSE" 2>/dev/null || true

export SB_PATHS="bin"
export SB_ENTRY="bin/zig"
sb_layer lib
sb_finish
