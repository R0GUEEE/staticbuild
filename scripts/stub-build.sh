#!/bin/sh
# Build the carrier stub for every target this host can emit.
#
#   scripts/stub-build.sh                  # everything possible here
#   scripts/stub-build.sh linux-arm64 ...  # named targets
#
# The stub is pure Go, CGO off, so one host cross-builds ELF and PE carriers for
# every architecture Go supports. Mach-O slices need a macOS host; the macOS
# universal carrier is lipo of the two slices. iOS needs cgo and an Apple SDK.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${SB_STUB_OUT:-$ROOT/build/stub}
VERSION=${STUB_VERSION:-2.0.0}
mkdir -p "$OUT"

# target:goos:goarch
ALL="linux-x86_64:linux:amd64
linux-arm64:linux:arm64
linux-armv7:linux:arm
linux-386:linux:386
linux-riscv64:linux:riscv64
windows-x86_64:windows:amd64
windows-arm64:windows:arm64
windows-386:windows:386
macos-x86_64:darwin:amd64
macos-arm64:darwin:arm64
ios-arm64:ios:arm64"

log() { printf '==> %s\n' "$*" >&2; }

find_triple() {
  for row in $ALL; do
    case "$row" in "$1:"*) printf '%s\n' "$row"; return 0 ;; esac
  done
  return 1
}

build_one() {
  row=$1
  t=${row%%:*}; rest=${row#*:}; goos=${rest%%:*}; goarch=${rest##*:}
  case "$goos" in
    darwin|ios) [ "$(uname -s)" = Darwin ] || { log "skip $t (Apple toolchain needed)"; return 0; } ;;
    windows) : ;;
  esac
  out=$OUT/sb-stub-$t
  log "stub $t ($goos/$goarch)"
  # The one dependency is vendored, so this builds with no module proxy: a
  # container that cannot reach proxy.golang.org still produces carriers.
  GOFLAGS="-mod=vendor"
  export GOFLAGS
  if [ "$goos" = ios ]; then
    ( cd "$ROOT/stub" && CGO_ENABLED=1 GOOS=ios GOARCH=arm64 go build \
        -buildvcs=false -trimpath -buildmode=pie \
        -ldflags "-s -w -X main.stubVersion=$VERSION" -o "$out" . ) \
      || { log "skip $t (iOS needs cgo + SDK)"; return 0; }
  else
    ( cd "$ROOT/stub" && CGO_ENABLED=0 GOOS=$goos GOARCH=$goarch go build \
        -buildvcs=false -trimpath -ldflags "-s -w -X main.stubVersion=$VERSION" \
        -o "$out" . )
  fi
}

if [ "$#" -gt 0 ]; then
  for t in "$@"; do
    case "$t" in
      *-universal) continue ;;
    esac
    row=$(find_triple "$t") || { log "unknown target $t"; exit 1; }
    build_one "$row"
  done
else
  for row in $ALL; do build_one "$row"; done
  if [ "$(uname -s)" = Darwin ] && command -v lipo >/dev/null 2>&1 \
     && [ -f "$OUT/sb-stub-macos-arm64" ] && [ -f "$OUT/sb-stub-macos-x86_64" ]; then
    log "lipo → macos-universal"
    lipo -create -output "$OUT/sb-stub-macos-universal" \
      "$OUT/sb-stub-macos-arm64" "$OUT/sb-stub-macos-x86_64"
  fi
fi
ls -l "$OUT" >&2
