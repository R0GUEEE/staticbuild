#!/bin/sh
# shellcheck shell=sh
# Shared helpers for every recipe. Sourced, never executed.
#
# Inputs (set by make/ CI):
#   SB_TOOL     tool id, must match manifest/tools.json
#   SB_VERSION  version being built
#   SB_TARGET   linux-arm64 | linux-x86_64 | ios-arm64 | macos-arm64 | ...
#   SB_TIER     static | sfx | layer | macho
# Outputs:
#   $SB_STAGE   staged tree (becomes the bundle payload)
#   $SB_DIST    final artifacts
#
# Everything is POSIX sh. Recipes run on Alpine (busybox ash) and on macOS
# (bash 3.2 / sh), so no arrays, no [[ ]], no local -n, no GNU-only flags
# outside of a case on uname.

set -eu

# A recipe may be run directly (`sh recipes/ninja.sh`) or through make; in both
# cases $0 is the recipe, so the tool id can always be derived from it.
SB_TOOL=${SB_TOOL:-$(basename "$0" .sh)}
SB_VERSION=${SB_VERSION:-0.0.0}
SB_TARGET=${SB_TARGET:-}

SB_ROOT=${SB_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
SB_WORK=${SB_WORK:-$SB_ROOT/build}
SB_CACHE=${SB_CACHE:-$SB_WORK/cache}
SB_DIST=${SB_DIST:-$SB_ROOT/dist}
SB_STAGE=${SB_STAGE:-$SB_WORK/stage/$SB_TOOL-$SB_TARGET}
SB_EPOCH=${SOURCE_DATE_EPOCH:-1700000000}
SB_JOBS=${SB_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)}

export LC_ALL=C
export TZ=UTC
export SOURCE_DATE_EPOCH=$SB_EPOCH

[ -n "$SB_TARGET" ] || { echo "sb: SB_TARGET is required (linux-arm64, linux-x86_64, ios-arm64, macos-arm64)" >&2; exit 2; }

case "$SB_TARGET" in
  # name             os        arch      goarch    triple                       family
  linux-x86_64)   SB_OS=linux   SB_ARCH=x86_64  SB_GOARCH=amd64   SB_TRIPLE=x86_64-linux-musl            SB_FAMILY=elf ;;
  linux-arm64)    SB_OS=linux   SB_ARCH=aarch64 SB_GOARCH=arm64   SB_TRIPLE=aarch64-linux-musl           SB_FAMILY=elf ;;
  linux-armv7)    SB_OS=linux   SB_ARCH=armv7   SB_GOARCH=arm     SB_TRIPLE=armv7-linux-musleabihf       SB_FAMILY=elf ;;
  linux-386)      SB_OS=linux   SB_ARCH=386     SB_GOARCH=386     SB_TRIPLE=i386-linux-musl              SB_FAMILY=elf ;;
  linux-riscv64)  SB_OS=linux   SB_ARCH=riscv64 SB_GOARCH=riscv64 SB_TRIPLE=riscv64-linux-musl           SB_FAMILY=elf ;;
  windows-x86_64) SB_OS=windows SB_ARCH=x86_64  SB_GOARCH=amd64   SB_TRIPLE=x86_64-w64-mingw32           SB_FAMILY=pe ;;
  windows-arm64)  SB_OS=windows SB_ARCH=arm64   SB_GOARCH=arm64   SB_TRIPLE=aarch64-w64-mingw32          SB_FAMILY=pe ;;
  windows-386)    SB_OS=windows SB_ARCH=386     SB_GOARCH=386     SB_TRIPLE=i686-w64-mingw32             SB_FAMILY=pe ;;
  macos-arm64)    SB_OS=macos   SB_ARCH=arm64   SB_GOARCH=arm64   SB_TRIPLE=arm64-apple-darwin           SB_FAMILY=macho ;;
  macos-x86_64)   SB_OS=macos   SB_ARCH=x86_64  SB_GOARCH=amd64   SB_TRIPLE=x86_64-apple-darwin          SB_FAMILY=macho ;;
  macos-universal) SB_OS=macos  SB_ARCH=universal SB_GOARCH=universal SB_TRIPLE=universal-apple-darwin   SB_FAMILY=macho ;;
  ios-arm64)      SB_OS=ios     SB_ARCH=arm64   SB_GOARCH=arm64   SB_TRIPLE=arm64-apple-ios              SB_FAMILY=macho ;;
  ios-arm64-sim)  SB_OS=ios     SB_ARCH=arm64   SB_GOARCH=arm64   SB_TRIPLE=arm64-apple-ios-simulator    SB_FAMILY=macho ;;
  windows-universal) SB_OS=windows SB_ARCH=universal SB_GOARCH=amd64 SB_TRIPLE=universal-windows SB_FAMILY=pe ;;
  linux-universal) SB_OS=linux  SB_ARCH=x86_64  SB_GOARCH=amd64   SB_TRIPLE=x86_64-linux-musl            SB_FAMILY=elf ;;
  *) echo "sb: unknown SB_TARGET '$SB_TARGET'" >&2; exit 2 ;;
esac

# Executable suffix and CRT flags for the target family.
case "$SB_FAMILY" in
  pe) SB_EXE=.exe ;;
  *)  SB_EXE= ;;
esac
export SB_EXE

SB_EFFECTIVE_TIER=${SB_TIER:-sfx}
export SB_ARCH SB_TRIPLE SB_FAMILY SB_EFFECTIVE_TIER

# Progress goes to stderr: recipes capture function output in $( ) to get paths
# (src=$(sb_fetch ...)), so a chatty stdout corrupts the value. This bit CI once.
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
  log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
  warn() { printf '\033[1;33m!!!\033[0m %s\n' "$*" >&2; }
  die()  { printf '\033[1;31mERR\033[0m %s\n' "$*" >&2; exit 1; }
else
  log()  { printf '==> %s\n' "$*" >&2; }
  warn() { printf '!!! %s\n' "$*" >&2; }
  die()  { printf 'ERR %s\n' "$*" >&2; exit 1; }
fi
die()  { printf '\033[1;31mERR\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- environment

sb_init() {
  mkdir -p "$SB_CACHE" "$SB_DIST" "$SB_STAGE"
  rm -rf "$SB_STAGE"
  mkdir -p "$SB_STAGE/bin" "$SB_STAGE/.sb"

  SB_ENTRY=${SB_ENTRY:-bin/$SB_TOOL}
  SB_PATHS=${SB_PATHS:-bin}
  SB_ENV=${SB_ENV:-}
  SB_REQUIRE=${SB_REQUIRE:-}
  SB_ALIASES=${SB_ALIASES:-}

  log "$SB_TOOL $SB_VERSION → $SB_TARGET ($SB_EFFECTIVE_TIER, $SB_TRIPLE)"
  if [ "$SB_FAMILY" = elf ] && [ "$(uname -s)" = Darwin ]; then
    warn "cross-building static ELF on Darwin needs zig or an aarch64-musl clang; recipes use \`zig cc\` when SB_CC is unset"
  fi
}

# Host cc: on Linux the system compiler (musl), on macOS a zig-based cross cc.
sb_cc() {
  if [ -n "${SB_CC:-}" ]; then echo "$SB_CC"; return; fi
  case "$SB_FAMILY" in
    elf) echo "${CROSS_CC:-cc}" ;;
    pe)
      if [ -n "${MINGW_CC:-}" ]; then echo "$MINGW_CC"
      elif command -v "$SB_TRIPLE-gcc" >/dev/null 2>&1; then echo "$SB_TRIPLE-gcc"
      elif command -v zig >/dev/null 2>&1; then echo "zig cc -target $SB_TRIPLE"
      else die "no Windows cross compiler: install mingw-w64 or zig, or set MINGW_CC"; fi ;;
    macho)
      if [ -n "${IOS_CC:-}" ] && { [ "$SB_OS" = ios ] || [ -n "${IOS_HOST:-}" ]; }; then echo "$IOS_CC"
      elif [ "$(uname -s)" = Darwin ]; then echo xcrun -sdk "${SB_SDK:-macosx}" clang
      else die "no Mach-O host compiler: set IOS_CC"; fi ;;
  esac
}

# Extra flags every recipe appends: arch, sysroot, static CRT.
sb_cflags() {
  case "$SB_FAMILY" in
    elf) echo "-O2 -fPIC -static-libgcc" ;;
    pe)
      echo "-O2 -static -static-libgcc -static-libstdc++ -D_WIN32_WINNT=0x0601"
      if [ "$SB_ARCH" = arm64 ]; then echo "-D_ARM64_;-D_WIN32_WINNT=0x0601"; fi ;;
    macho)
      case "$SB_TARGET" in
        ios-arm64|ios-arm64-sim)
          echo "-O2 -arch $SB_ARCH -isysroot $(xcrun --sdk iphoneos --show-sdk-path) -miphoneos-version-min=${SB_MIN_OS:-15.0}" ;;
        *) echo "-O2 -arch $SB_ARCH -isysroot $(xcrun --sdk macosx --show-sdk-path) -mmacosx-version-min=${SB_MACOS_MIN:-11.0}" ;;
      esac ;;
  esac
}

# Windows/MSVC-style flags some recipes need: sb_ldflags is what the linker gets.
sb_ldflags() {
  case "$SB_FAMILY" in
    pe) echo "-static -static-libgcc -static-libstdc++ -Wl,--no-insert-timestamp" ;;
    elf) echo "-static" ;;
    *) echo "" ;;
  esac
}

# ------------------------------------------------------------------ fetching

# sb_fetch URL [SHA256] -> prints the cached file path
sb_fetch() {
  _url=$1
  _sum=${2:-}
  _name=$(basename "${_url%%\?*}")
  _out=$SB_CACHE/$_name
  if [ ! -f "$_out" ]; then
    log "fetch $_name"
    curl -fsSL --retry 3 --retry-delay 2 -o "$_out.part" "$_url" || die "download failed: $_url"
    mv "$_out.part" "$_out"
  fi
  if [ -n "$_sum" ]; then
    _got=$(sb_sha256 "$_out")
    [ "$_got" = "$_sum" ] || die "checksum mismatch for $_name
  want $_sum
  got  $_got"
  fi
  printf '%s\n' "$_out"
}

sb_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

sb_unpack() {
  _tar=$1; _dst=$2
  mkdir -p "$_dst"
  log "unpack $(basename "$_tar")"
  case "$_tar" in
    *.tar.zst) zstd -dc "$_tar" | tar -xf - -C "$_dst" ;;
    *.tar.xz)  tar -xf "$_tar" -C "$_dst" ;;
    *.tar.gz|*.tgz) tar -xzf "$_tar" -C "$_dst" ;;
    *.tar.bz2|*.tbz2) tar -xjf "$_tar" -C "$_dst" ;;
    *.zip)     unzip -q "$_tar" -d "$_dst" ;;
    *) die "unknown archive type: $_tar" ;;
  esac
}

# A cd that cannot silently fail: recipes are run with set -e, but a failed cd
# inside a pipeline does not abort, and the build then compiles the wrong tree.
sb_cd() { cd "$1" || die "cannot cd to $1"; }

# ------------------------------------------------------------------ staging

sb_bin() {  # sb_bin SRC [NAME]
  _name=${2:-$(basename "$1")}
  mkdir -p "$SB_STAGE/bin"
  cp "$1" "$SB_STAGE/bin/$_name"
  chmod 755 "$SB_STAGE/bin/$_name"
}

sb_tree() {  # sb_tree SRC_DIR DEST_REL -- copy a tree into the stage
  mkdir -p "$SB_STAGE/$2"
  ( cd "$1" && tar -cf - . ) | ( cd "$SB_STAGE/$2" && tar -xf - )
}

sb_symlinks() {  # sb_symlinks BIN... -- link every name to the bundle's bin/<SB_TOOL>
  for _n in "$@"; do
    (
      cd "$SB_STAGE/bin"
      [ "$_n" = "$SB_TOOL" ] || ln -sf "$SB_TOOL" "$_n"
    )
  done
}

# Declare extra command names this bundle answers to: sb_alias npm=bin/npm ...
# The stub dispatches `<bundle> --sb-run npm` and a symlink named `npm`.
sb_alias() {
  for _a in "$@"; do
    case "$_a" in
      *=*) SB_ALIASES="${SB_ALIASES}${_a}
" ;;
      *) die "sb_alias expects name=path, got '$_a'" ;;
    esac
  done
}

# A wrapper script in bin/ plus an alias for it.
sb_wrapper() {  # sb_wrapper NAME < script-body
  _name=$1
  mkdir -p "$SB_STAGE/bin"
  cat > "$SB_STAGE/bin/$_name"
  chmod 755 "$SB_STAGE/bin/$_name"
  sb_alias "$_name=bin/$_name"
}

# Turn $SB_STAGE/<rel> into a hash-addressed layer shared across bundles.
# The stub rewrites the @@SB_LAYER@@ token to an absolute path under the cache.
sb_layer() {
  _rel=$1
  [ -d "$SB_STAGE/$_rel" ] || die "sb_layer: $SB_STAGE/$_rel does not exist"
  _sha=$(python3 - "$SB_STAGE/$_rel" <<'PYHASH'
import hashlib, os, sys
root = sys.argv[1]
h = hashlib.sha256()
for dirpath, dirnames, filenames in os.walk(root):
    dirnames.sort()
    for name in sorted(filenames):
        path = os.path.join(dirpath, name)
        rel = os.path.relpath(path, root)
        h.update(rel.encode() + b"\0")
        if os.path.islink(path):
            h.update(os.readlink(path).encode())
            continue
        with open(path, "rb") as fh:
            for chunk in iter(lambda: fh.read(1 << 20), b""):
                h.update(chunk)
print(h.hexdigest()[:16])
PYHASH
)
  log "layer $_rel → $_sha"
  mkdir -p "$SB_STAGE/layers"
  rm -rf "$SB_STAGE/layers/$_sha"
  mv "$SB_STAGE/$_rel" "$SB_STAGE/layers/$_sha"
  _target=@@SB_LAYER@@/$_sha
  ln -s "$_target" "$SB_STAGE/$_rel"
  SB_LAYERS="${SB_LAYERS:-} $_sha"
}

# Strip everything in bin/ before packing. A release cargo/rust binary carries
# ~30 MiB of symbols: ripgrep shipped at 35 MiB until this ran. Set SB_NO_STRIP=1
# when a tool needs its symbols (none does today).
sb_strip_stage() {
  [ "${SB_NO_STRIP:-0}" = 1 ] && return 0
  _strip=""
  for c in strip llvm-strip; do
    command -v "$c" >/dev/null 2>&1 && { _strip=$c; break; }
  done
  [ -n "$_strip" ] || { warn "no strip found; bundles will be larger"; return 0; }
  for f in "$SB_STAGE"/bin/*; do
    [ -f "$f" ] || continue
    case "$(file -b "$f" 2>/dev/null)" in
      *ELF*|*Mach-O*) "$_strip" -x "$f" 2>/dev/null || "$_strip" --strip-all "$f" 2>/dev/null || true ;;
    esac
  done
}

sb_meta() {
  {
    printf '{\n'
    printf '  "tool": "%s",\n' "$SB_TOOL"
    printf '  "version": "%s",\n' "$SB_VERSION"
    printf '  "entry": "%s",\n' "$SB_ENTRY"
    printf '  "family": "%s",\n' "$SB_FAMILY"
    printf '  "triple": "%s",\n' "$SB_TRIPLE"
    printf '  "paths": [%s],\n' "$(sb_json_list "$SB_PATHS")"
    printf '  "require": [%s],\n' "$(sb_json_list "$SB_REQUIRE")"
    printf '  "env": {%s},\n' "${SB_ENV:-}"
    printf '  "aliases": {%s},\n' "$(sb_json_map "${SB_ALIASES:-}")"
    printf '  "layers": [%s],\n' "$(sb_json_list "${SB_LAYERS:-}")"
    printf '  "built": %s\n' "$SB_EPOCH"
    printf '}\n'
  } > "$SB_STAGE/.sb/meta.json"
  python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$SB_STAGE/.sb/meta.json" \
    || die "generated meta.json is not valid JSON"
}

sb_json_map() {  # newline-separated name=path -> "name": "path", ...
  python3 - "$@" <<'PY'
import json, sys
pairs = []
for chunk in sys.argv[1:]:
    for line in chunk.splitlines():
        line = line.strip()
        if not line:
            continue
        k, _, v = line.partition("=")
        if k and v:
            pairs.append((k, v))
print(", ".join(json.dumps(k) + ": " + json.dumps(v) for k, v in pairs))
PY
}

sb_json_list() {
  python3 - "$@" <<'PY'
import json, sys
items = [x for a in sys.argv[1:] for x in a.split() if x]
print(", ".join(json.dumps(i) for i in items))
PY
}

# ---------------------------------------------------------------- finishing

# The carrier stub for this target. Built on demand and cached in build/stub so
# a matrix job builds it once and every recipe in that job reuses it.
sb_stub() {
  _stub=$SB_WORK/stub/sb-stub-$SB_TARGET
  if [ ! -x "$_stub" ]; then
    log "building carrier stub for $SB_TARGET"
    sh "$SB_ROOT/scripts/stub-build.sh" "$SB_TARGET" >/dev/null 2>&1 || true
  fi
  [ -x "$_stub" ] || die "no carrier stub for $SB_TARGET (scripts/stub-build.sh)"
  printf '%s\n' "$_stub"
}

# A tree that is already a single executable needs no container: shipping a
# 2.4 MB stub around a 600 KiB ninja would be worse than the thing it wraps.
sb_is_bare() {
  [ "${SB_BARE:-auto}" = 1 ] && return 0
  [ "${SB_BARE:-auto}" = 0 ] && return 1
  case "$SB_EFFECTIVE_TIER" in static|macho) : ;; *) return 1 ;; esac
  [ -z "${SB_ALIASES:-}" ] || return 1
  [ -z "${SB_LAYERS:-}" ] || return 1
  [ -z "${SB_ENV:-}" ] || return 1
  [ "$(find "$SB_STAGE" -type f | wc -l)" -le 2 ] || return 1
}

sb_finish() {
  sb_strip_stage
  sb_meta

  _out=$SB_DIST/$SB_TOOL-$SB_VERSION-$SB_TARGET
  case "$SB_FAMILY" in pe) _out=$_out.exe ;; esac

  if sb_is_bare; then
    cp "$SB_STAGE/$SB_ENTRY" "$_out"
    chmod 755 "$_out"
    log "bare binary → $(basename "$_out")"
  else
    _stub=$(sb_stub)
    _extra=""
    # SB_EXTRA_PAYLOADS="macos-x86_64=/path/to/stage" folds more carrier
    # payloads into the same file (a recipe that built both slices in one job).
    for _p in ${SB_EXTRA_PAYLOADS:-}; do _extra="$_extra --payload $_p"; done
    python3 "$SB_ROOT/scripts/pack.py"       --stub "$_stub" --out "$_out"       --tool "$SB_TOOL" --version "$SB_VERSION"       --payload "$SB_TARGET=$SB_STAGE" $_extra \
      || die "pack failed for $(basename "$_out")"
  fi

  _size=$(wc -c < "$_out" | tr -d ' ')
  _sum=$(sb_sha256 "$_out")
  printf '%s  %s\n' "$_sum" "$(basename "$_out")" >> "$SB_DIST/SHA256SUMS"
  log "artifact $(basename "$_out") $((_size / 1024)) KiB"
  printf '%s\n' "$_sum  $(basename "$_out")" > "$_out.sha256"

  if [ -x "$SB_ROOT/scripts/verify.sh" ] && [ "${SB_SKIP_VERIFY:-0}" != 1 ]; then
    "$SB_ROOT/scripts/verify.sh" "$_out" || die "verify failed for $(basename "$_out")"
  fi
}

# Clone with a shallow, tag-pinned checkout (keeps SOURCE_DATE_EPOCH builds small).
# Clone a repo into the work tree, preferring a tag that matches the manifest
# version and falling back to the default branch with a warning. Projects rename
# tags constantly (ldid ships 2.1.5-procursus7, not 2.1.5), and a hard failure
# there is a build outage for no good reason.
sb_git() {  # sb_git URL TAG DEST [--recurse]
  _url=$1; _tag=$2; _dest=$SB_WORK/src/$3; _sub=""
  [ "${4:-}" = --recurse ] && _sub="--recurse-submodules --shallow-submodules"
  rm -rf "$_dest"
  mkdir -p "$SB_WORK/src"
  log "git clone $3 @ $_tag"
  if git clone --depth 1 --branch "$_tag" $_sub "$_url" "$_dest" 2>/dev/null; then
    return 0
  fi
  warn "tag $_tag not found in $_url; building the default branch"
  rm -rf "$_dest"
  git clone --depth 1 $_sub "$_url" "$_dest"
}
