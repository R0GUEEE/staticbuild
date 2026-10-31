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
# Zig renamed its tarballs in 0.14: zig-<arch>-<os>-<ver> now, where every
# release up to 0.13 said zig-<os>-<arch>-<ver>. Both are supported, and the
# layout check below is what catches a release that changes it again.
REL_NEW=$(sb_pick "linux-x86_64=x86_64-linux linux-arm64=aarch64-linux \
windows-x86_64=x86_64-windows windows-arm64=aarch64-windows \
macos-arm64=aarch64-macos macos-x86_64=x86_64-macos" 2>/dev/null || true)
[ -n "$REL_NEW" ] || die "zig: no upstream host build for $SB_TARGET (cross-target from another arch)"

_arch=${REL_NEW%%-*}
_os=${REL_NEW##*-}
case "$_os" in
  windows) ext=zip ;;
  *) ext=tar.xz ;;
esac

# The rename landed in 0.14.1, not 0.14.0, so neither name can be assumed:
# probe both with a HEAD request and download whichever exists.
REL_OLD="$_os-$_arch"
REL=""
for _cand in "$REL_NEW" "$REL_OLD"; do
  _url="https://ziglang.org/download/$SB_VERSION/zig-$_cand-$SB_VERSION.$ext"
  if curl -fsIL --retry 2 --max-time 30 "$_url" >/dev/null 2>&1; then
    REL=$_cand
    break
  fi
done
[ -n "$REL" ] || die "zig $SB_VERSION: neither zig-$REL_NEW-$SB_VERSION.$ext nor zig-$REL_OLD-$SB_VERSION.$ext exists"

src=$(sb_fetch "https://ziglang.org/download/$SB_VERSION/zig-$REL-$SB_VERSION.$ext")
work=$SB_WORK/src/zig-$SB_TARGET
rm -rf "$work"
sb_unpack_any "$src" "$work"
root=$(find "$work" -maxdepth 1 -type d -name 'zig-*' | head -1)
[ -n "$root" ] || die "zig: unexpected archive layout in $src"
[ -x "$root/zig" ] || [ -f "$root/zig.exe" ] || die "zig: $root has no zig binary"

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
