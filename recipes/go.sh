#!/bin/sh
# deps: curl unzip
# Go toolchain — one GOROOT per target, from the official release.
#
# Building Go from source with a bootstrap compiler only ever yields a
# host-native toolchain, which is why this fetches per-platform archives:
# linux-armv6l for 32-bit ARM boards, windows-arm64 for native Windows on ARM,
# darwin-* for the Mac. CGO_ENABLED=0 output is statically linked by
# construction on every platform, so a program built here is one file anywhere.
. "$(dirname "$0")/_release.sh"
sb_init

case "$SB_TARGET" in
  *-universal) log "go: universal composition is scripts/compose.py's job"; exit 0 ;;
esac

REL=$(sb_pick "linux-x86_64=linux-amd64 linux-arm64=linux-arm64 linux-armv7=linux-armv6l \
linux-386=linux-386 linux-riscv64=linux-riscv64 windows-x86_64=windows-amd64 \
windows-arm64=windows-arm64 windows-386=windows-386 macos-arm64=darwin-arm64 \
macos-x86_64=darwin-amd64") || die "no Go release for $SB_TARGET"

case "$REL" in windows-*) ext=zip ;; *) ext=tar.gz ;; esac

src=$(sb_fetch "https://go.dev/dl/go$SB_VERSION.$REL.$ext")
work=$SB_WORK/src/go-$SB_TARGET
rm -rf "$work"
sb_unpack_any "$src" "$work"

root=$(find "$work" -maxdepth 2 -name VERSION -type f | head -1)
[ -n "$root" ] || die "unpacked Go has no VERSION file"
root=$(dirname "$root")

# The test corpus and docs are most of the bytes and none of the compiler.
rm -rf "$root/test" "$root/doc" "$root/api" "$root/misc"
find "$root/src" -name testdata -type d -prune -exec rm -rf {} + 2>/dev/null || true
find "$root/src" -name '*_test.go' -delete 2>/dev/null || true

sb_stage_dir "$root" go

# Windows has no symlinks without a privilege a payload cannot assume, so the
# entry points are copies there and links everywhere else.
mkdir -p "$SB_STAGE/bin"
if [ "$SB_FAMILY" = pe ]; then
  cp "$SB_STAGE/go/bin/go.exe" "$SB_STAGE/bin/go.exe"
  cp "$SB_STAGE/go/bin/gofmt.exe" "$SB_STAGE/bin/gofmt.exe" 2>/dev/null || true
else
  ln -sf ../go/bin/go "$SB_STAGE/bin/go"
  ln -sf ../go/bin/gofmt "$SB_STAGE/bin/gofmt"
  sb_alias "gofmt=bin/gofmt"
fi

export SB_ENV='"GOROOT": "${ROOT}/go", "GOTOOLCHAIN": "local"'
export SB_PATHS="bin"
export SB_ENTRY="bin/go"
sb_finish
