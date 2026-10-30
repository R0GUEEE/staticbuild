#!/bin/sh
# Build the carrier stub for every supported target.
#
#   scripts/stub-build.sh                  # everything this host can emit
#   scripts/stub-build.sh linux-arm64 ...  # named targets
#
# The stub is pure Go, CGO off, so one host cross-builds ELF and PE carriers
# for every architecture Go supports. Mach-O slices come from a macOS host;
# a macOS universal carrier is lipo of the two slices. iOS needs cgo against
# the iOS SDK, so that slice is only produced on a macOS runner.
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

build_one() {
  tuplet=$1
  t=${tuplet%%:*}; rest=${tuplet#*:}; goos=${rest%%:*}; goarch=${rest##*:}
  case "$goos:$(uname -s)" in
    darwin:Darwin|linux:Linux|windows:Linux|windows:Darwin) : ;;
    darwin:Linux) log "skip $t (Mach-O needs macOS)"; return 0 ;;
    ios:*) : ;;
    *)
      if [ "$goos" != "$(uname -s | tr 'A-Z' 'a-z')" ] && [ "$goos" = windows ] && [ "$(uname -s)" != Linux ] && [ "$(uname -s)" != Darwin ]; then
        log "skip $t (no cross for $goos from $(uname -s))"; return 0
      fi ;;
  esac
  out=$OUT/sb-stub-$t
  log "stub $t ($goos/$goarch)"
  if [ "$goos" = ios ]; then
    ( cd "$ROOT/stub" && CGO_ENABLED=1 GOOS=ios GOARCH=arm64 \
        go build -buildvcs=false -trimpath -buildmode=pie \
        -ldflags "-s -w -X main.stubVersion=$VERSION" -o "$out" . ) \
      || { log "skip $t (iOS needs cgo + an Apple SDK)"; return 0; }
  else
    ( cd "$ROOT/stub" && CGO_ENABLED=0 GOOS=$goos GOARCH=$goarch \
        go build -buildvcs=false -trimpath \
        -ldflags "-s -w -X main.stubVersion=$VERSION" -o "$out" . )
  fi
  printf '%s\n' "$out"
}

if [ "$#" -gt 0 ]; then
  for t in "$@"; do build_one "$(printf '%s\n' "$ALL" | grep -E "^$t:" || echo "$t")"; done
else
  for t in $ALL; do
    case "$t" in
      darwin:*) [ "$(uname -s)" = Darwin ] || { log "skip ${t%%:*} (Mach-O needs macOS)"; continue; } ;;
    esac
    build_one "$t" >/dev/null || exit 1
  done
  # A macOS universal carrier: dyld picks the slice, so one download runs on
  # Apple Silicon and Intel, and each slice can carry its own payload.
  if [ "$(uname -s)" = Darwin ] && command -v lipo >/dev/null 2>&1 \
     && [ -f "$OUT/sb-stub-macos-arm64" ] && [ -f "$OUT/sb-stub-macos-x86_64" ]; then
    log "lipo → macos-universal"
    lipo -create -output "$OUT/sb-stub-macos-universal" \
      "$OUT/sb-stub-macos-arm64" "$OUT/sb-stub-macos-x86_64"
  fi
fi

ls -l "$OUT" >&2
