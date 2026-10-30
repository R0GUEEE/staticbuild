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

sb_cd "$SB_WORK/src/rust/$_pfx"
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

# Docs and man pages are ~40 MiB of nothing a compiler reads.
rm -rf "$SB_STAGE/rust/share/doc" "$SB_STAGE/rust/share/man" "$SB_STAGE/rust/lib/rustlib/etc"
# The musl host toolchain is already static, but release binaries carry ~30 MiB
# of symbols each; strip() is the difference between 420 MiB and 300 MiB.
if command -v strip >/dev/null 2>&1; then
  for f in "$SB_STAGE/rust/bin"/*; do
    [ -f "$f" ] && strip -x "$f" 2>/dev/null || true
  done
fi

mkdir -p "$SB_STAGE/bin"
for b in rustc cargo rustdoc rustfmt clippy-driver cargo-clippy rust-lld rust-gdb; do
  [ -f "$SB_STAGE/rust/bin/$b" ] && ln -sf "../rust/bin/$b" "$SB_STAGE/bin/$b"
done

export SB_PATHS="bin"
export SB_ENTRY="bin/cargo"
export SB_ENV='"CARGO_HOME": "${ROOT}/cargo", "RUSTUP_TOOLCHAIN": "staticbuild"'
sb_layer rust/lib
sb_finish
