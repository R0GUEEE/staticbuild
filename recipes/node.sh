#!/bin/sh
# deps: (none for the linux bundle) / git + Xcode SDKs for the iOS slice
# Node.js, plus npm and npx as multi-call aliases of the same file.
#
# The upstream linux-arm64 build is glibc, not musl. That is a fact about node,
# not a build failure: the bundle is tier `layer` (a vendored runtime), not
# tier `static`, and it declares ubuntu as its build/payload image in the
# manifest so the smoke test runs in the same libc it ships against.
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
  [ -x "$_root/bin/node" ] || die "node: unexpected tarball layout"

  sb_bin "$_root/bin/node" node
  mkdir -p "$SB_STAGE/lib/node_modules"
  cp -R "$_root/lib/node_modules/npm" "$SB_STAGE/lib/node_modules/npm"
  [ -d "$_root/lib/node_modules/corepack" ] && \
    cp -R "$_root/lib/node_modules/corepack" "$SB_STAGE/lib/node_modules/corepack"
else
  command -v git >/dev/null || die "git required for the nodejs-mobile build"
  [ -d "$SB_WORK/src/nodejs-mobile" ] || \
    git clone --depth 1 --branch "nodejs-mobile-v$SB_VERSION" \
      https://github.com/JaneaSystems/nodejs-mobile.git "$SB_WORK/src/nodejs-mobile"

  sb_cd "$SB_WORK/src/nodejs-mobile"
  sb_configure --without-snapshot --with-intl=none --without-ssl \
    --openssl-no-asm --dest-os=ios --dest-cpu=arm64 \
    --v8-options="-DV8_ENABLE_WEBASSEMBLY=0 -DV8_TARGET_ARCH_ARM64=1 -D__arm64__"
  make -j "$SB_JOBS" LDFLAGS="-arch arm64 -isysroot $(xcrun --sdk iphoneos --show-sdk-path)"

  sb_bin out/Release/node node
  mkdir -p "$SB_STAGE/lib/node_modules"
fi

# npm/npx are JS entry points; the wrappers call the bundled node explicitly so
# they work with no node on PATH and no `#!/usr/bin/env node` resolution.
sb_wrapper npm <<'WRAP'
#!/bin/sh
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
exec "$HERE/bin/node" "$HERE/lib/node_modules/npm/bin/npm-cli.js" "$@"
WRAP
sb_wrapper npx <<'WRAP'
#!/bin/sh
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
exec "$HERE/bin/node" "$HERE/lib/node_modules/npm/bin/npx-cli.js" "$@"
WRAP

export SB_PATHS="bin"
export SB_ENTRY="bin/node"
export SB_ENV='"NODE_PATH": "${ROOT}/lib/node_modules"'
sb_layer lib/node_modules
sb_finish
