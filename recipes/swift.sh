#!/bin/sh
# deps: libncurses6 libsqlite3-0 libcurl4 libxml2 libedit2 libz3-dev libpython3-dev zlib1g-dev
# Swift 6 on Linux, plus the Static Linux SDK.
#
# Two corrections to the obvious recipe, both load-bearing:
#  * the download path repeats the version: .../swift-6.0.3-release/ubuntu2204/
#    swift-6.0.3-RELEASE/swift-6.0.3-RELEASE-ubuntu22.04.tar.gz
#  * the toolchain is glibc-only. It does not run on Alpine, so the manifest
#    builds this one in ubuntu, and the bundle is a vendored toolchain (`layer`),
#    not a static executable. swiftc can *emit* fully static binaries — the
#    Static Linux SDK in this bundle is what does that — but swiftc itself links
#    libLLVM and libswiftCore dynamically. No upstream static swiftc exists.
. "$(dirname "$0")/_common.sh"
sb_init

case "$SB_TARGET" in
  linux-arm64)  _dist=ubuntu2204; _plat=ubuntu22.04 ;;
  macos-arm64)  die "use the Apple toolchain on macOS; this bundle is Linux-only" ;;
  *) die "swift: no upstream build for $SB_TARGET" ;;
esac

_f="swift-$SB_VERSION-RELEASE-$_plat.tar.gz"
src=$(sb_fetch "https://download.swift.org/swift-$SB_VERSION-release/$_dist/swift-$SB_VERSION-RELEASE/$_f")
sb_unpack "$src" "$SB_WORK/src/swift"
_root=$(find "$SB_WORK/src/swift" -maxdepth 1 -type d -name 'swift-*' | head -1)
[ -n "$_root" ] || die "swift: unexpected tarball layout"
[ -x "$_root/usr/bin/swiftc" ] || die "swift: tarball has no usr/bin/swiftc"

mkdir -p "$SB_STAGE/bin" "$SB_STAGE/lib"

# -a keeps the driver's symlink farm (swiftc -> swift, swift-build -> swift-build-tool…)
# intact; a plain cp turns every one of them into a 300 MiB copy of the driver.
cp -a "$_root/usr/bin/"swift* "$SB_STAGE/bin/" 2>/dev/null || true
for _b in sourcekit-lsp swift-format; do
  [ -e "$_root/usr/bin/$_b" ] && cp -a "$_root/usr/bin/$_b" "$SB_STAGE/bin/" || true
done

cp -a "$_root/usr/lib/swift" "$SB_STAGE/lib/swift"
[ -d "$_root/usr/lib/swift_static" ] && cp -a "$_root/usr/lib/swift_static" "$SB_STAGE/lib/swift_static"
# The driver shells out to its own clang for the C family and for linking.
[ -d "$_root/usr/lib/clang" ] && cp -a "$_root/usr/lib/clang" "$SB_STAGE/lib/clang"
[ -d "$_root/usr/include" ] && cp -a "$_root/usr/include" "$SB_STAGE/usr/include"

# Static Linux SDK: the reason `swiftc -static-stdlib -swift-sdk aarch64-musl`
# produces a binary with zero DT_NEEDED. Installed as an artifact bundle.
if [ ! -d "$SB_STAGE/lib/swift/static-linux" ]; then
  _sdk="swift-$SB_VERSION-RELEASE_static-linux-0.0.1.artifactbundle.tar.gz"
  if _p=$(sb_fetch "https://download.swift.org/swift-$SB_VERSION-release/static-sdk/$_sdk" 2>/dev/null); then
    sb_unpack "$_p" "$SB_WORK/src/swift-static-sdk"
    _ab=$(find "$SB_WORK/src/swift-static-sdk" -maxdepth 2 -name '*.artifactbundle' -type d | head -1)
    [ -n "$_ab" ] && cp -a "$_ab" "$SB_STAGE/lib/swift/static-linux"
  else
    warn "static-linux SDK not published for $SB_VERSION; dynamic-stdlib output only"
  fi
fi

# A toolchain, not a single file: report what it actually links so the size and
# the tier claim stay honest.
_needed=$(readelf -d "$SB_STAGE/bin/swift-frontend" 2>/dev/null | sed -n 's/.*NEEDED.*\[\(.*\)\]/\1/p' | tr '\n' ' ')
log "swift-frontend links: ${_needed:-none}"

export SB_PATHS="bin usr/bin"
export SB_ENTRY="bin/swiftc"
export SB_ENV='"SWIFT_BACKTRACE": "enable=no"'
sb_layer lib/swift
[ -d "$SB_STAGE/lib/swift_static" ] && sb_layer lib/swift_static || true
[ -d "$SB_STAGE/lib/clang" ] && sb_layer lib/clang || true
sb_finish
