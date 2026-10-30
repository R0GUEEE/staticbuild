#!/bin/sh
# deps: (none) — macOS host only
# xtool: SwiftPM-based iOS app builder that does not need Xcode.
# The SDK is the elephant: `--bake-sdk` puts the Darwin Swift SDK inside the
# bundle (adds ~800 MiB), otherwise xtool downloads it on first `xtool setup`.
. "$(dirname "$0")/_common.sh"
sb_init

case "$SB_TARGET" in
  macos-arm64) _t=macos-arm64 ;;
  *) die "xtool: macOS host only (it drives an Apple linker)" ;;
esac

src=$(sb_fetch "https://github.com/xtool-org/xtool/releases/download/v$SB_VERSION/xtool-$_t.tar.gz")
sb_unpack "$src" "$SB_WORK/src/xtool"
_root=$(find "$SB_WORK/src/xtool" -maxdepth 2 -type f -name xtool | head -1)
[ -n "$_root" ] || die "unexpected xtool release layout"

sb_bin "$_root" xtool
mkdir -p "$SB_STAGE/lib"
[ -d "$(dirname "$_root")/lib" ] && cp -R "$(dirname "$_root")/lib/." "$SB_STAGE/lib/" || true

if [ "${BAKE_SDK:-0}" = 1 ]; then
  log "baking the Darwin Swift SDK into the bundle"
  mkdir -p "$SB_STAGE/sdk"
  "$SB_STAGE/bin/xtool" setup --sdk-path "$SB_STAGE/sdk" >/dev/null 2>&1 || \
    warn "xtool setup failed; bundle ships without the SDK"
fi

SB_PATHS="bin"
SB_ENTRY="bin/xtool"
SB_ENV='"XTOOL_HOME": "${ROOT}"'
sb_finish
