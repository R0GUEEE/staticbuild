#!/bin/sh
# deps: build-base go (bootstrap)
# Go toolchain — the only recipe here that compiles a compiler with itself.
# The result is a GOROOT tree in the payload, so `go build` works with no
# environment: meta.json sets GOROOT=$SB_BUNDLE_ROOT/go and PATH+=bin.
. "$(dirname "$0")/_common.sh"
sb_init

src=$(sb_fetch "https://go.dev/dl/go$SB_VERSION.src.tar.gz")
sb_unpack "$src" "$SB_WORK/src/go"

BOOT=$(go env GOROOT 2>/dev/null || true)
[ -n "$BOOT" ] && [ -d "$BOOT" ] || die "no bootstrap Go found; install one (apk add go) or set GOROOT_BOOTSTRAP"

export GOROOT_BOOTSTRAP="$BOOT"
export GOROOT_FINAL=/go
export CGO_ENABLED=0

cd "$SB_WORK/src/go/go/src"
GOROOT_BOOTSTRAP="$BOOT" ./make.bash --no-banner

GOROOT="$SB_WORK/src/go/go"
mkdir -p "$SB_STAGE/go"
( cd "$GOROOT" && tar -cf - --exclude='pkg/obj' --exclude='pkg/bootstrap' . ) | \
  ( cd "$SB_STAGE/go" && tar -xf - )

# Trim the test corpus: it is 40% of the tree and nothing downstream compiles it.
rm -rf "$SB_STAGE/go/test" "$SB_STAGE/go/pkg/obj"
find "$SB_STAGE/go/pkg" -name '*_test*' -delete 2>/dev/null || true

mkdir -p "$SB_STAGE/bin"
ln -s ../go/bin/go "$SB_STAGE/bin/go"
ln -s ../go/bin/gofmt "$SB_STAGE/bin/gofmt"

SB_ENV='"GOROOT": "${ROOT}/go", "GOTOOLCHAIN": "local"'
SB_PATHS="bin"
SB_ENTRY="bin/go"
sb_finish
