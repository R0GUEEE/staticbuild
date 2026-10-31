#!/bin/sh
# deps: curl xz unzip
# Zig — one tarball, one static binary, and the C/C++ cross compiler the ELF
# recipes use (`zig cc -target aarch64-w64-mingw32`).
. "$(dirname "$0")/_release.sh"
sb_init

case "$SB_TARGET" in
  *-universal) log "zig: universal composition happens in scripts/compose.py"; exit 0 ;;
esac

# zig-<os>-<arch>-<ver>: os first, arch second — the reverse of the triple.
REL=$(sb_pick "linux-x86_64=linux-x86_64 linux-arm64=linux-aarch64 \
windows-x86_64=windows-x86_64 windows-arm64=windows-aarch64 \
macos-arm64=macos-aarch64 macos-x86_64=macos-x86_64") || {
  log "zig: no $SB_TARGET host build upstream"; exit 0; }

case "$REL" in windows-*) ext=zip ;; *) ext=tar.xz ;; esac

src=$(sb_fetch "https://ziglang.org/download/$SB_VERSION/zig-$REL-$SB_VERSION.$ext")
work=$SB_WORK/src/zig-$SB_TARGET
rm -rf "$work"
sb_unpack_any "$src" "$work"
# mindepth matters: $work itself is named zig-<target>, which would match.
root=$(find "$work" -mindepth 1 -maxdepth 1 -type d | head -1)
[ -n "$root" ] || die "zig: unexpected tarball layout"

mkdir -p "$SB_STAGE/bin" "$SB_STAGE/lib"
if [ "$SB_FAMILY" = pe ]; then
  cp "$root/zig.exe" "$SB_STAGE/bin/zig.exe"
else
  cp "$root/zig" "$SB_STAGE/bin/zig"
  chmod 755 "$SB_STAGE/bin/zig"
fi
# lib/ is std, libc headers and compiler_rt: without it zig compiles nothing.
( cd "$root/lib" && tar -cf - --exclude='docs' --exclude='*.html' . ) | \
  ( cd "$SB_STAGE/lib" && tar -xf - )
cp "$root/LICENSE" "$SB_STAGE/.sb/LICENSE" 2>/dev/null || true

export SB_PATHS="bin"
export SB_ENTRY="bin/zig"
sb_layer lib
sb_finish
