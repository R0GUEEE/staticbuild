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

sb_cd "$SB_WORK/src/go/go/src"
GOROOT_BOOTSTRAP="$BOOT" ./make.bash --no-banner

GOROOT="$SB_WORK/src/go/go"
mkdir -p "$SB_STAGE/go"
( cd "$GOROOT" && tar -cf - --exclude='pkg/obj' --exclude='pkg/bootstrap' . ) | \
  ( cd "$SB_STAGE/go" && tar -xf - )

# Trim the test corpus and the C sources used only to bootstrap: nothing
# downstream compiles them, and together they are most of the payload.
rm -rf "$SB_STAGE/go/test" "$SB_STAGE/go/pkg/obj" "$SB_STAGE/go/api" \
       "$SB_STAGE/go/doc" "$SB_STAGE/go/misc"
find "$SB_STAGE/go/src" -name 'testdata' -type d -prune -exec rm -rf {} + 2>/dev/null || true
find "$SB_STAGE/go/src" -name '*_test.go' -delete 2>/dev/null || true
find "$SB_STAGE/go/pkg" -name '*_test*' -delete 2>/dev/null || true

mkdir -p "$SB_STAGE/bin"
ln -s ../go/bin/go "$SB_STAGE/bin/go"
ln -s ../go/bin/gofmt "$SB_STAGE/bin/gofmt"
sb_alias "gofmt=bin/gofmt"

export SB_ENV='"GOROOT": "${ROOT}/go", "GOTOOLCHAIN": "local"'
export SB_PATHS="bin"
export SB_ENTRY="bin/go"
sb_finish
