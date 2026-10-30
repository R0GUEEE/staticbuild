#!/bin/sh
# deps: curl xz bash
# Rust — the official dist tarball per host triple, installed with its own
# install.sh so rustlib, the target JSONs and the Cargo skeleton land where
# rustc expects them.
#
# The compiler is libc/CRT-linked, so this is a layer bundle; the *output* can
# still be fully static: --target x86_64-unknown-linux-musl, or
# RUSTFLAGS=-Ctarget-feature=+crt-static on the Windows GNU triples.
. "$(dirname "$0")/_release.sh"
sb_init

REL=$(sb_pick "linux-x86_64=x86_64-unknown-linux-gnu linux-arm64=aarch64-unknown-linux-gnu \
linux-armv7=armv7-unknown-linux-gnueabihf linux-riscv64=riscv64gc-unknown-linux-gnu \
windows-x86_64=x86_64-pc-windows-gnu windows-arm64=aarch64-pc-windows-msvc \
macos-arm64=aarch64-apple-darwin macos-x86_64=x86_64-apple-darwin") || \
  die "rust: no dist for $SB_TARGET"

src=$(sb_fetch "https://static.rust-lang.org/dist/rust-$SB_VERSION-$REL.tar.xz")
work=$SB_WORK/src/rust-$SB_TARGET
prefix=$SB_WORK/rust-prefix-$SB_TARGET
rm -rf "$work" "$prefix"
sb_unpack_any "$src" "$work"
root=$(find "$work" -maxdepth 1 -type d -name "rust-$SB_VERSION-*" | head -1)
[ -n "$root" ] || die "rust: unexpected tarball layout"

( cd "$root" && bash ./install.sh --prefix="$prefix" --disable-ldconfig \
    --components=rustc,cargo,rust-std ) > "$SB_WORK/rust-install.log" 2>&1 || {
      tail -30 "$SB_WORK/rust-install.log" >&2; die "rust install.sh failed"; }

sb_stage_dir "$prefix" rust
mkdir -p "$SB_STAGE/bin"
for b in rustc cargo rustdoc; do
  if [ "$SB_FAMILY" = pe ]; then
    cp "$SB_STAGE/rust/bin/$b.exe" "$SB_STAGE/bin/$b.exe" 2>/dev/null || true
  else
    ln -sf ../rust/bin/$b "$SB_STAGE/bin/$b"
  fi
done
[ "$SB_FAMILY" = pe ] || sb_alias "cargo=bin/cargo" "rustdoc=bin/rustdoc"

export SB_ENV='"CARGO_HOME": "${ROOT}/cargo"'
export SB_PATHS="bin"
export SB_ENTRY="bin/rustc"
sb_layer rust
sb_finish
