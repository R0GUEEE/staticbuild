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
sb_cd "$SB_WORK/src/rg/ripgrep-$SB_VERSION"

# Alpine's rustc is a musl build but its host triple is aarch64-alpine-linux-musl,
# so comparing triples is not enough. What matters is whether rust-std for the
# requested target is installed: if it is not, build natively instead of failing
# with "can't find crate for core".
_sysroot=$(rustc --print sysroot)
if [ -d "$_sysroot/lib/rustlib/$_t/lib" ]; then
  cargo build --release --locked
  _out="target/release/rg"
else
  cargo build --release --target "$_t" --locked
  _out="target/$_t/release/rg"
fi

sb_bin "$_out" rg
export SB_PATHS=bin
sb_finish
