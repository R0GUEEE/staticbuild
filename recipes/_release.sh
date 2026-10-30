#!/bin/sh
# shellcheck shell=sh
# Helpers for tools that ship a per-platform archive upstream (Go, Zig, Node,
# Python, Rust, the JDK, Swift). Sourced on top of _common.sh, never executed.
#
# The point is that a recipe stays a table: one line per target, no branching
# on os/arch beyond the table itself, and the same code path produces an ELF,
# a PE and a Mach-O bundle.
#
#   sb_pick "linux-x86_64=amd64 linux-arm64=arm64"      -> echoes amd64
#   sb_rel https://go.dev/dl/go@V@.@OS@-@ARCH@.tar.gz    -> resolves @V@, @OS@, @ARCH@
#   sb_unpack_any <file> <dir>                           -> tar/zip/tar.zst/tar.xz
#   sb_stage_dir <srcdir> <relpath>                       -> copy a tree into the stage

. "$(dirname "$0")/_common.sh"

# sb_pick "target=value ..." — first match wins; dies when the target is absent
# from the table, so a recipe can never silently build the wrong platform.
sb_pick() {
  _table=$1
  for _kv in $_table; do
    case "$_kv" in
      "$SB_TARGET="*) printf '%s\n' "${_kv#*=}"; return 0 ;;
    esac
  done
  die "$SB_TOOL: no entry for $SB_TARGET in: $_table"
}

# sb_has "target=value ..." — non-fatal variant, for tables that legitimately
# skip a platform (the recipe then prints a reason and exits 0).
sb_has() {
  _table=$1
  for _kv in $_table; do
    case "$_kv" in
      "$SB_TARGET="*) return 0 ;;
    esac
  done
  return 1
}

# sb_rel URL — substitute the tokens every release host uses.
sb_rel() {
  _u=$1
  _u=$(printf '%s' "$_u" | sed "s/@V@/$SB_VERSION/g")
  _u=$(printf '%s' "$_u" | sed "s/@ARCH@/${REL_ARCH:-$SB_ARCH}/g")
  _u=$(printf '%s' "$_u" | sed "s/@OS@/${REL_OS:-$SB_OS}/g")
  if [ -n "${REL_TRIPLE:-}" ]; then
    _u=$(printf '%s' "$_u" | sed "s/@TRIPLE@/$REL_TRIPLE/g")
  fi
  printf '%s\n' "$_u"
}

# sb_unpack_any FILE DIR — tar/zip in any compression a release host ships.
sb_unpack_any() {
  _f=$1; _d=$2
  mkdir -p "$_d"
  case "$_f" in
    *.zip) sb_unpack "$_f" "$_d" ;;
    *.tar.gz|*.tgz) tar -xzf "$_f" -C "$_d" ;;
    *.tar.xz) tar -xJf "$_f" -C "$_d" ;;
    *.tar.bz2) tar -xjf "$_f" -C "$_d" ;;
    *.tar.zst) zstd -dc "$_f" | tar -xf - -C "$_d" ;;
    *) die "unknown archive: $_f" ;;
  esac
}

# sb_stage_dir SRC DEST_REL — copy a tree into the bundle payload.
sb_stage_dir() {
  mkdir -p "$SB_STAGE/$2"
  ( cd "$1" && tar -cf - . ) | ( cd "$SB_STAGE/$2" && tar -xf - )
}

# sb_wrap NAME — a 3-line launcher inside the payload, for tools whose entry is
# a script (npm, tsc, tsc.cmd, kotlinc, meson) that needs its own directory.
sb_wrap() {
  _n=$1
  shift
  mkdir -p "$SB_STAGE/bin"
  printf '%s\n' "$@" > "$SB_STAGE/bin/$_n"
  chmod 755 "$SB_STAGE/bin/$_n"
  sb_alias "$_n=bin/$_n"
}
