#!/bin/sh
# Verify a bundle's tier claim, its size budget and that it actually runs.
#
#   verify.sh dist/ninja-1.12.1-linux-arm64
#   verify.sh --all
#
# Checks, in order:
#   1. format     — ELF vs Mach-O vs SFX stub, by reading the first bytes and the trailer
#   2. tier       — ELF: no DT_NEEDED at all. Mach-O: every imported dylib is under
#                   /usr/lib or /System/Library (the dyld shared cache).
#   3. no leakage — no build paths (/home/runner, /Users/runner, /nix/store) in strings
#   4. budget     — size <= size_budget_mb from the manifest
#   5. smoke      — the manifest's smoke command, run with a clean environment
#
# Exit codes: 0 ok, 1 any check failed. A failed check prints the bundle, the check
# and the evidence, so CI logs say which of the five broke.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DIST=${DIST:-$ROOT/dist}
MANIFEST=$ROOT/manifest/tools.json
TMP=$(mktemp -d "${TMPDIR:-/tmp}/sb-verify.XXXXXX")
trap 'rm -rf "$TMP"' EXIT INT TERM

fail=0
ok()   { printf '  \033[32mok\033[0m   %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fail=1; }
head_() { printf '\n\033[1m%s\033[0m\n' "$*"; }

file_kind() {
  # 0 = ELF, 1 = Mach-O, 2 = SFX bundle
  b=$(od -An -tx1 -N4 "$1" | tr -d ' \n')
  case "$b" in
    7f454c46) echo elf ;;
    cffaedfe|cefaedfe|cafebabe) echo macho ;;
    *) echo other ;;
  esac
}

read_trailer() {
  python3 - "$1" <<'PY'
import struct, sys, os
p = sys.argv[1]
size = os.path.getsize(p)
if size < 64:
    sys.exit(1)
with open(p, "rb") as f:
    f.seek(size - 64)
    magic, ver, flags, off, plen, digest, epoch = struct.unpack("<4sHHQQ32sQ", f.read(64))
if magic != b"SBX1" or off + plen + 64 != size:
    sys.exit(1)
print(f"{ver} {flags} {off} {plen} {digest.hex()} {epoch}")
PY
}

extract_payload() {  # bundle -> dir
  _line=$(read_trailer "$1") || return 1
  _off=$(echo "$_line" | cut -d' ' -f3)
  _len=$(echo "$_line" | cut -d' ' -f4)
  dd if="$1" of="$TMP/payload.tar.zst" bs=1 skip="$_off" count="$_len" 2>/dev/null
  zstd -dc "$TMP/payload.tar.zst" | tar -xf - -C "$2"
}

# The executable inside a bundle (SFX stub or bare binary).
tool_binary() {  # bundle -> prints path to an executable entry
  _dest=$TMP/root
  rm -rf "$_dest"; mkdir -p "$_dest"
  if read_trailer "$1" >/dev/null 2>&1; then
    extract_payload "$1" "$_dest" || return 1
    _entry=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["entry"])' "$_dest/.sb/meta.json")
    printf '%s\n' "$_dest/$_entry"
  else
    printf '%s\n' "$1"
  fi
}

check_elf() {
  _bin=$1
  if ! readelf -d "$_bin" 2>/dev/null | grep -q NEEDED; then
    ok "static: no DT_NEEDED entries"
  else
    _libs=$(readelf -d "$_bin" | grep NEEDED | sed 's/.*\[//; s/\].*//' | tr '\n' ' ')
    bad "ELF is dynamically linked: $_libs"
  fi
  if readelf -h "$_bin" | grep -q 'DYN (Position-Independent Executable'; then
    ok "PIE (required by iOS 11+ and preferred everywhere)"
  fi
}

check_macho() {
  _bin=$1
  _bad=$(otool -L "$_bin" | tail -n +2 | awk '{print $1}' | grep -vE '^/usr/lib/|^/System/Library/|^@rpath/libswift|^$' || true)
  if [ -z "$_bad" ]; then
    ok "imports only OS libraries (dyld shared cache)"
  else
    bad "imports non-system dylibs: $(echo $_bad | tr '\n' ' ')"
  fi
  _arch=$(lipo -archs "$_bin" 2>/dev/null || echo unknown)
  case "$_arch" in
    arm64*) ok "arch $_arch" ;;
    *) bad "unexpected arch '$_arch'" ;;
  esac
}

check_leaks() {
  _dir=$1
  _hits=$TMP/leaks
  case "$(uname -s)" in
    Darwin) grep -rIl -E '/(home|Users)/runner|/nix/store|/build/sb-' "$_dir" 2>/dev/null | head -5 > "$_hits" || true ;;
    *)      grep -rIl -E '/(home|Users)/runner|/nix/store|/build/sb-' "$_dir" 2>/dev/null | head -5 > "$_hits" || true ;;
  esac
  if [ -s "$_hits" ]; then
    bad "build paths leaked into: $(tr '\n' ' ' < "$_hits")"
  else
    ok "no build paths in strings"
  fi
}

verify_one() {
  _artifact=$1
  _name=$(basename "$_artifact")
  head_ "$_name ($(wc -c < "$_artifact" | tr -d ' ') B)"

  _budget=$(python3 - "$MANIFEST" "$_name" <<'SBLOOKUP'
import json, sys
m = json.load(open(sys.argv[1]))
name = sys.argv[2]
# clang-20.1.8-linux-arm64 -> id clang, target linux-arm64
for t in m["tools"]:
    for tgt, blk in t.get("targets", {}).items():
        if name.startswith(t["id"] + "-") and name.endswith("-" + tgt):
            print(t["id"], blk.get("size_budget_mb", 0), blk.get("smoke", ""), tgt, sep="\t")
            sys.exit(0)
print("\t0\t\t")
SBLOOKUP
)
  _id=$(echo "$_budget" | cut -f1)
  _mb=$(echo "$_budget" | cut -f2)
  _smoke=$(echo "$_budget" | cut -f3)
  _tgt=$(echo "$_budget" | cut -f4)

  # A bundle's first four bytes are the ELF/Mach-O magic of its stub, so the
  # trailer is the only reliable discriminator.
  if read_trailer "$_artifact" >/dev/null 2>&1; then
    ok "SFX bundle (static stub + zstd payload)"
    _root=$TMP/root; rm -rf "$_root"; mkdir -p "$_root"
    if ! extract_payload "$_artifact" "$_root"; then
      bad "payload does not extract"
      return
    fi
    _entry=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["entry"])' "$_root/.sb/meta.json")
    _bin=$_root/$_entry
    [ -x "$_bin" ] && ok "entrypoint $_entry is executable" || bad "entrypoint $_entry is not executable"
    check_leaks "$_root"
    case "$(file -b "$_bin")" in
      *Mach-O*) check_macho "$_bin" ;;
      *ELF*)    check_elf "$_bin" ;;
      *)        bad "entrypoint is neither ELF nor Mach-O" ;;
    esac
  else
    _kind=$(file_kind "$_artifact")
    case "$_kind" in
      elf|macho) ;;
      *) bad "not an ELF, not a Mach-O and not a bundle"; return ;;
    esac
    check_leaks "$_artifact"
    if [ "$_kind" = elf ]; then check_elf "$_artifact"; else check_macho "$_artifact"; fi
    _bin=$_artifact
  fi

  if [ "${_mb:-0}" != 0 ] && [ -n "${_mb:-}" ]; then
    _actual=$(wc -c < "$_artifact" | tr -d ' ')
    if [ "$_actual" -le $((_mb * 1048576)) ]; then
      ok "size ${_actual} B <= ${_mb} MiB budget"
    else
      bad "size ${_actual} B over ${_mb} MiB budget"
    fi
  fi

  if [ -n "${_smoke:-}" ]; then
    _exec=${_bin:-$_artifact}
    # The artifact is named <tool>-<version>-<target>; the smoke command calls the
    # tool by its real name. A symlink bridge keeps both honest.
    mkdir -p "$TMP/run"
    ln -sf "$(cd "$(dirname "$_exec")" && pwd)/$(basename "$_exec")" "$TMP/run/${_id:-$(basename "$_artifact")}"
    _bindir=$TMP/run
    if ( cd "$TMP" && env -i PATH="$_bindir:/usr/bin:/bin" HOME="$TMP" TMPDIR="$TMP" \
           SB_CACHE="$TMP/cache" sh -c "$_smoke" ) >"$TMP/smoke.log" 2>&1; then
      ok "smoke: $_smoke"
    else
      bad "smoke failed: $_smoke"
      tail -15 "$TMP/smoke.log" | sed 's/^/       /'
    fi
  fi
}

if [ "${1:-}" = --all ]; then
  set --
  for f in "$DIST"/*; do
    case "$(basename "$f")" in
      SHA256SUMS|*.sha256|*.json|*.sig) continue ;;
    esac
    [ -f "$f" ] && set -- "$@" "$f"
  done
fi

[ $# -gt 0 ] || { echo "usage: verify.sh ARTIFACT... | --all" >&2; exit 2; }

for a in "$@"; do
  verify_one "$a"
done

if [ "$fail" -ne 0 ]; then
  printf '\n\033[31mverification failed\033[0m\n'
  exit 1
fi
printf '\n\033[32mall checks passed\033[0m\n'
