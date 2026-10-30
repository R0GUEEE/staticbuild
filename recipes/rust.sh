#!/bin/sh
# deps: (none — upstream binaries)
# rustc + cargo, plus the iOS std so the same bundle cross-compiles
# staticlibs/cdylibs for aarch64-apple-ios.
. "$(dirname "$0")/_common.sh"
sb_init

case "$SB_TARGET" in
  linux-arm64)  _host=aarch64-unknown-linux-musl ;;
  linux-x86_64) _host=x86_64-unknown-linux-musl ;;
  macos-arm64)  _host=aarch64-apple-darwin ;;
  *) die "rust: no upstream toolchain for $SB_TARGET" ;;
esac

_pfx="rust-$SB_VERSION-$_host"
src=$(sb_fetch "https://static.rust-lang.org/dist/$_pfx.tar.xz")
sb_unpack "$src" "$SB_WORK/src/rust"

cd "$SB_WORK/src/rust/$_pfx"
./install.sh --prefix="$SB_STAGE/rust" --disable-ldconfig --without=rust-docs

# rust-std for the iOS target (and the simulator slice, which is a different rustc target)
for _t in aarch64-apple-ios aarch64-apple-ios-sim; do
  _f="rust-std-$SB_VERSION-$_t.tar.xz"
  if _p=$(sb_fetch "https://static.rust-lang.org/dist/$_f" 2>/dev/null); then
    sb_unpack "$_p" "$SB_WORK/src/rust-std-$_t"
    ( cd "$SB_WORK/src/rust-std-$_t/rust-std-$SB_VERSION-$_t" && \
      ./install.sh --prefix="$SB_STAGE/rust" --disable-ldconfig )
  else
    warn "rust-std for $_t unavailable at $SB_VERSION (skipped)"
  fi
done

mkdir -p "$SB_STAGE/bin"
for b in rustc cargo rustdoc rustfmt clippy-driver cargo-clippy rust-lld; do
  [ -f "$SB_STAGE/rust/bin/$b" ] && ln -sf "../rust/bin/$b" "$SB_STAGE/bin/$b"
done

SB_PATHS="bin"
SB_ENTRY="bin/cargo"
SB_ENV='"CARGO_HOME": "${ROOT}/cargo", "RUSTUP_TOOLCHAIN": "staticbuild"'
sb_layer rust/lib
sb_finish
