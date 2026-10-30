#!/bin/sh
# deps: build-base perl
# OpenSSL CLI, everything in one binary: no-shared, no-module, no-legacy.
# The failure mode this avoids: `openssl req` works but `openssl x509` cannot find
# a provider file that the bundle does not carry.
. "$(dirname "$0")/_common.sh"
sb_init

src=$(sb_fetch "https://github.com/openssl/openssl/releases/download/openssl-$SB_VERSION/openssl-$SB_VERSION.tar.gz")
sb_unpack "$src" "$SB_WORK/src/openssl"
cd "$SB_WORK/src/openssl/openssl-$SB_VERSION"

case "$SB_FAMILY" in
  elf)
    case "$SB_TARGET" in
      linux-arm64) _t=linux-aarch64 ;;
      *)           _t=linux-x86_64 ;;
    esac
    ./Configure "$_t" no-shared no-module no-tests no-docs no-legacy no-engine \
      --prefix="$SB_WORK/openssl" --openssldir=/etc/ssl --libdir=lib \
      -static -fPIC
    ;;
  macho)
    ./Configure ios64-arm64-cross no-shared no-module no-tests no-docs no-legacy \
      --prefix="$SB_WORK/openssl" --openssldir=/etc/ssl --libdir=lib \
      -isysroot "$(xcrun --sdk iphoneos --show-sdk-path)" -miphoneos-version-min=15.0
    ;;
esac

make -j "$SB_JOBS"
make install_sw install_ssldirs

sb_bin "$SB_WORK/openssl/bin/openssl" openssl
SB_PATHS="bin"
SB_ENTRY="bin/openssl"
sb_finish
