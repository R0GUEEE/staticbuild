#!/bin/sh
# deps: curl xz
# Zig — one tarball, one binary, and the C/C++ cross compiler the rest of this
# repository uses (`zig cc -target aarch64-w64-mingw32`). Zig is already a
# static executable upstream, so the bundle stays tier `static` on every host
# and the lib/std tree is shipped as a layer.
. "$(dirname "$0")/_release.sh"
sb_init

case "$SB_TARGET" in
  *-universal)
    log "zig: universal composition happens in scripts/compose.sh"
    exit 0 ;;
esac

# The tarball is zig-<os>-<arch>-<ver>.tar.xz: os first, arch second, which is
# the reverse of the triple everyone writes.
REL=$(sb_pick "linux-x86_64=linux-x86_64 linux-arm64=linux-aarch64 \
windows-x86_64=windows-x86_64 windows-arm64=windows-aarch64 \
macos-arm64=macos-aarch64 macos-x86_64=macos-x86_64" 2>/dev/null || true)
if [ -z "$REL" ]; then
  log "zig: no $SB_TARGET host build upstream (cross-target with another arch's zig)"
  exit 0
fi

case "$REL" in
  windows-*) ext=zip ;;
  *) ext=tar.xz ;;
esac

src=$(sb_fetch "https://ziglang.org/download/$SB_VERSION/zig-$REL-$SB_VERSION.$ext")
work=$SB_WORK/src/zig-$SB_TARGET
rm -rf "$work"
sb_unpack_any "$src" "$work"
root=$(find "$work" -maxdepth 1 -type d -name 'zig-*' | head -1)
[ -n "$root" ] || die "zig: unexpected tarball layout"

mkdir -p "$SB_STAGE/bin" "$SB_STAGE/lib"
if [ "$SB_FAMILY" = pe ]; then
  cp "$root/zig.exe" "$SB_STAGE/bin/zig.exe"
else
  cp "$root/zig" "$SB_STAGE/bin/zig"
  chmod 755 "$SB_STAGE/bin/zig"
fi
# lib/ carries std, libc headers and the compiler_rt objects: without it zig
# cannot compile anything, and `zig env` would point at a directory that is not
# there.
( cd "$root/lib" && tar -cf - --exclude='docs' --exclude='*.html' . ) | \
  ( cd "$SB_STAGE/lib" && tar -xf - )
cp "$root/LICENSE" "$SB_STAGE/.sb/LICENSE" 2>/dev/null || true

export SB_PATHS="bin"
export SB_ENTRY="bin/zig"
sb_layer lib
sb_finish
