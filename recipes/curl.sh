#!/bin/sh
# deps: build-base openssl-dev (or OPENSSL_STATIC=1)
# curl — the only way most downstream projects fetch a bundle, so it must be small
# and must not depend on the host's TLS stack.
. "$(dirname "$0")/_common.sh"
sb_init

src=$(sb_fetch "https://curl.se/download/curl-$SB_VERSION.tar.xz")
sb_unpack "$src" "$SB_WORK/src/curl"
cd "$SB_WORK/src/curl/curl-$SB_VERSION"

_ssl=openssl
[ "${BUILD_OPENSSL:-0}" = 1 ] && _ssl=openssl
[ "$SB_TARGET" = ios-arm64 ] && [ "${BUILD_OPENSSL:-0}" != 1 ] && _ssl=secure-transport

if [ "$_ssl" = openssl ] && [ ! -f "$SB_WORK/openssl/lib/libssl.a" ]; then
  die "static OpenSSL missing: run \`make tools/openssl\` first (or BUILD_OPENSSL=1 to build it here)"
fi

./configure --prefix=/usr --disable-shared --enable-static \
  --without-libidn2 --without-nghttp2 --without-ngtcp2 --without-brotli \
  --without-zstd --without-libpsl --disable-ldap --disable-ldaps --disable-manual \
  --with-ssl="${OPENSSL_PREFIX:-$SB_WORK/openssl}" \
  --with-ca-bundle=/etc/ssl/certs/ca-certificates.crt \
  CFLAGS="$(sb_cflags) -I${OPENSSL_PREFIX:-$SB_WORK/openssl}/include" \
  LDFLAGS="$([ "$SB_FAMILY" = elf ] && echo -static) -L${OPENSSL_PREFIX:-$SB_WORK/openssl}/lib"

make -j "$SB_JOBS"
sb_bin src/curl curl
SB_PATHS=bin
sb_finish
