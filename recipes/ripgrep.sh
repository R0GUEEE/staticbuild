#!/bin/sh
# deps: cargo (or the rust bundle)
# ripgrep — the fastest way to prove a bundle can spawn threads, mmap and read regexes.
. "$(dirname "$0")/_common.sh"
sb_init

case "$SB_TARGET" in
  linux-arm64)  _t=aarch64-unknown-linux-musl; export RUSTFLAGS="-C target-feature=+crt-static" ;;
  linux-x86_64) _t=x86_64-unknown-linux-musl;  export RUSTFLAGS="-C target-feature=+crt-static" ;;
  ios-arm64)    _t=aarch64-apple-ios ;;
  macos-arm64)  _t=aarch64-apple-darwin ;;
  *) die "no rust target for $SB_TARGET" ;;
esac

command -v cargo >/dev/null || die "cargo not found (install the rust bundle first, or apk add cargo)"

src=$(sb_fetch "https://github.com/BurntSushi/ripgrep/archive/refs/tags/$SB_VERSION.tar.gz")
sb_unpack "$src" "$SB_WORK/src/rg"
cd "$SB_WORK/src/rg/ripgrep-$SB_VERSION"

cargo build --release --target "$_t" --locked

sb_bin "target/$_t/release/rg" rg
SB_PATHS=bin
sb_finish
