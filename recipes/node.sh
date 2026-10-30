#!/bin/sh
# deps: curl unzip / git + Xcode for the iOS slice
# Node.js with npm, npx and corepack as multi-call aliases of one bundle.
#
# Upstream builds are glibc on Linux and a plain PE on Windows, so the bundle is
# tier `layer` on those targets: a vendored runtime, not a single static ELF.
# The manifest gives node the ubuntu image on Linux so the smoke test runs in
# the same libc the payload ships against.
. "$(dirname "$0")/_release.sh"
sb_init

if [ "$SB_TARGET" = ios-arm64 ]; then
  command -v git >/dev/null || die "git required for the nodejs-mobile build"
  [ -d "$SB_WORK/src/nodejs-mobile" ] || \
    git clone --depth 1 --branch "nodejs-mobile-v$SB_VERSION" \
      https://github.com/JaneaSystems/nodejs-mobile.git "$SB_WORK/src/nodejs-mobile"
  sb_cd "$SB_WORK/src/nodejs-mobile"
  sb_configure --without-snapshot --with-intl=none --without-ssl \
    --openssl-no-asm --dest-os=ios --dest-cpu=arm64 \
    --v8-options="-DV8_ENABLE_WEBASSEMBLY=0 -DV8_TARGET_ARCH_ARM64=1 -D__arm64__"
  make -j "$SB_JOBS" LDFLAGS="-arch arm64 -isysroot $(xcrun --sdk iphoneos --show-sdk-path)"
  sb_stage_dir out/Release .
  sb_symlinks node
  export SB_PATHS=bin SB_ENTRY=bin/node
  sb_finish
  exit 0
fi

case "$SB_TARGET" in
  *-universal)
    log "node: universal composition happens in scripts/compose.sh"
    exit 0 ;;
esac

REL=$(sb_pick "linux-x86_64=linux-x64 linux-arm64=linux-arm64 linux-armv7=linux-armv7l \
linux-riscv64=linux-riscv64 windows-x86_64=win-x64 windows-arm64=win-arm64 \
macos-arm64=darwin-arm64 macos-x86_64=darwin-x64" 2>/dev/null || true)
[ -n "$REL" ] || die "node: no upstream build for $SB_TARGET"

case "$REL" in
  win-*) ext=zip; dir="node-v$SB_VERSION-$REL" ;;
  *)     ext=tar.gz; dir="node-v$SB_VERSION-$REL" ;;
esac

src=$(sb_fetch "https://nodejs.org/dist/v$SB_VERSION/$dir.$ext")
work=$SB_WORK/src/node-$SB_TARGET
rm -rf "$work"
sb_unpack_any "$src" "$work"
root="$work/$dir"
[ -d "$root" ] || root=$(find "$work" -maxdepth 1 -type d -name "node-v*" | head -1)
[ -n "$root" ] || die "node: unexpected archive layout"

# Trim: headers and the bundled test runner are dead weight in a runtime bundle.
rm -rf "$root/include" "$root/share" 2>/dev/null || true
sb_stage_dir "$root" .

if [ "$SB_FAMILY" = pe ]; then
  mkdir -p "$SB_STAGE/bin"
  mv "$SB_STAGE/node.exe" "$SB_STAGE/bin/node.exe"
  [ -f "$SB_STAGE/npm.cmd" ] && mv "$SB_STAGE/npm.cmd" "$SB_STAGE/bin/npm.cmd"
  if [ -d "$SB_STAGE/node_modules" ]; then
    mkdir -p "$SB_STAGE/lib"
    mv "$SB_STAGE/node_modules" "$SB_STAGE/lib/node_modules"
  fi
  export SB_ENTRY="bin/node.exe"
  sb_alias "npm=bin/npm.cmd"
else
  # bin/npm and bin/npx already exist upstream and are scripts that re-exec
  # node; replacing them with symlinks to node would break that.
  export SB_ENTRY="bin/node"
  sb_alias "npm=bin/npm" "npx=bin/npx"
fi
export SB_PATHS="bin"
export SB_ENV='"NODE_PATH": "${ROOT}/lib/node_modules"'
sb_layer lib/node_modules
sb_finish
