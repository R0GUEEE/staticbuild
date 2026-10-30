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

# When the host *is* the target (Alpine's rustc is already musl), passing
# --target would look for a rust-std component that the distro package does not
# ship. Build natively in that case.
_host=$(rustc -vV | sed -n 's/^host: //p')
if [ "$_host" = "$_t" ]; then
  cargo build --release --locked
  _out="target/release/rg"
else
  cargo build --release --target "$_t" --locked
  _out="target/$_t/release/rg"
fi

sb_bin "$_out" rg
export SB_PATHS=bin
sb_finish
