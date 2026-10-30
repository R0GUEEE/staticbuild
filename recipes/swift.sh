#!/bin/sh
# deps: (none — upstream tarball; the recipe only relocates it)
# Swift. The upstream aarch64 Linux toolchain, trimmed, plus the Static Linux
# SDK so `swiftc -static-stdlib` produces fully static musl binaries.
. "$(dirname "$0")/_common.sh"
sb_init

case "$SB_TARGET" in
  linux-arm64)  _os=ubuntu22.04; _plat="ubuntu22.04-aarch64" ;;
  macos-arm64)  _os=xcode; _plat="xcode" ;;
  *) die "swift: no upstream build for $SB_TARGET" ;;
esac

case "$SB_TARGET" in
  linux-arm64) _f="swift-$SB_VERSION-RELEASE-$_plat.tar.gz" ;;
  macos-arm64) die "use the Apple-provided toolchain on macOS; this bundle is Linux-only" ;;
esac

src=$(sb_fetch "https://download.swift.org/swift-$SB_VERSION-release/$_os/$_f")
sb_unpack "$src" "$SB_WORK/src/swift"
_root=$(find "$SB_WORK/src/swift" -maxdepth 1 -type d -name 'swift-*' | head -1)
[ -n "$_root" ] || die "unexpected swift tarball layout"

# Keep: bin/ (driver + frontend), lib/swift/ (stdlib, host + static-linux),
# lib/clang (the clang the driver embeds). Drop: docs, examples, python bindings.
mkdir -p "$SB_STAGE/bin" "$SB_STAGE/lib" "$SB_STAGE/usr"
cp "$_root/usr/bin/"swift* "$SB_STAGE/bin/" 2>/dev/null || true
cp "$_root/usr/bin/sourcekit-lsp" "$SB_STAGE/bin/" 2>/dev/null || true
cp -R "$_root/usr/lib/swift" "$SB_STAGE/lib/swift"
cp -R "$_root/usr/lib/clang" "$SB_STAGE/lib/clang" 2>/dev/null || true
cp -R "$_root/usr/lib/swift_static" "$SB_STAGE/lib/swift_static" 2>/dev/null || true
cp -R "$_root/usr/include" "$SB_STAGE/usr/include" 2>/dev/null || true

# Static Linux SDK (aarch64-musl), installed where swiftc looks for it.
if ! ls "$SB_STAGE/lib/swift/static-linux" >/dev/null 2>&1; then
  _sdk="swift-$SB_VERSION-RELEASE_static-linux-0.0.1.artifactbundle.tar.gz"
  if _p=$(sb_fetch "https://download.swift.org/swift-$SB_VERSION-release/static-sdk/$_sdk" 2>/dev/null); then
    sb_unpack "$_p" "$SB_WORK/src/swift-static-sdk"
    _ab=$(find "$SB_WORK/src/swift-static-sdk" -maxdepth 2 -name '*.artifactbundle' | head -1)
    [ -n "$_ab" ] && cp -R "$_ab" "$SB_STAGE/lib/swift/static-linux"
  else
    warn "static-linux SDK not published for $SB_VERSION; dynamic-stdlib output only"
  fi
fi

SB_PATHS="bin usr/bin"
SB_ENTRY="bin/swiftc"
SB_ENV='"SWIFT_BACKTRACE": "enable=no"'
sb_layer lib/swift
sb_finish
