#!/bin/sh
# deps: (none for the linux bundle) / macOS: Xcode SDKs for the iOS slice
# Node.js. Two different builds behind one id:
#   linux  — upstream arm64 tarball, trimmed to bin/node + npm
#   ios    — nodejs-mobile sources with V8 in jitless mode (iOS forbids W^X)
. "$(dirname "$0")/_common.sh"
sb_init

if [ "$SB_TARGET" != ios-arm64 ]; then
  case "$SB_TARGET" in
    linux-arm64)  _t=linux-arm64 ;;
    linux-x86_64) _t=linux-x64 ;;
    macos-arm64)  _t=darwin-arm64 ;;
    *) die "node: no prebuilt for $SB_TARGET" ;;
  esac
  src=$(sb_fetch "https://nodejs.org/dist/v$SB_VERSION/node-v$SB_VERSION-$_t.tar.xz")
  sb_unpack "$src" "$SB_WORK/src/node"
  _root="$SB_WORK/src/node/node-v$SB_VERSION-$_t"

  cp "$_root/bin/node" "$SB_STAGE/bin/node"
  chmod 755 "$SB_STAGE/bin/node"
  mkdir -p "$SB_STAGE/lib/node_modules"
  cp -R "$_root/lib/node_modules/npm" "$SB_STAGE/lib/node_modules/npm"
  mkdir -p "$SB_STAGE/bin"
  ln -sf ../lib/node_modules/npm/bin/npm-cli.js "$SB_STAGE/bin/npm"
  ln -sf ../lib/node_modules/npm/bin/npx-cli.js "$SB_STAGE/bin/npx"
else
  command -v git >/dev/null || die "git required for the nodejs-mobile build"
  [ -d "$SB_WORK/src/nodejs-mobile" ] || \
    git clone --depth 1 --branch "nodejs-mobile-v$SB_VERSION" \
      https://github.com/JaneaSystems/nodejs-mobile.git "$SB_WORK/src/nodejs-mobile"

  cd "$SB_WORK/src/nodejs-mobile"
  ./configure --without-snapshot --with-intl=none --without-ssl \
    --openssl-no-asm --dest-os=ios --dest-cpu=arm64 \
    --v8-options="-DV8_ENABLE_WEBASSEMBLY=0 -DV8_TARGET_ARCH_ARM64=1 -D__arm64__"
  make -j "$SB_JOBS" LDFLAGS="-arch arm64 -isysroot $(xcrun --sdk iphoneos --show-sdk-path)"

  sb_bin out/Release/node node
fi

SB_PATHS="bin"
SB_ENTRY="bin/node"
SB_ENV='"NODE_PATH": "${ROOT}/lib/node_modules"'
sb_finish
