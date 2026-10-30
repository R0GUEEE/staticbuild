#!/bin/sh
# deps: build-base autoconf automake libtool
# jq — the tool every packaging script reaches for, and a good static-musl canary.
. "$(dirname "$0")/_common.sh"
sb_init

src=$(sb_fetch "https://github.com/jqlang/jq/releases/download/jq-$SB_VERSION/jq-$SB_VERSION.tar.gz")
sb_unpack "$src" "$SB_WORK/src/jq"
cd "$SB_WORK/src/jq/jq-$SB_VERSION"

./configure --disable-maintainer-mode --disable-docs --with-oniguruma=builtin \
  CFLAGS="$(sb_cflags)" LDFLAGS="-static -s"
make -j "$SB_JOBS"
sb_bin jq jq
SB_PATHS=bin
sb_finish
