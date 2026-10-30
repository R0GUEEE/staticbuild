#!/bin/sh
# shellcheck shell=sh
# Helpers for tools that ship a per-platform archive upstream (Go, Zig, Node,
# Rust, the JDK). Sourced on top of _common.sh, never executed.
#
# A recipe then stays a table: one line per target, no branching on os/arch
# beyond the table, and the same code path produces an ELF, a PE and a Mach-O.
. "$(dirname "$0")/_common.sh"

# sb_pick "target=value ..." — first match wins; dies when the target is absent,
# so a recipe can never silently build the wrong platform.
sb_pick() {
  for _kv in $1; do
    case "$_kv" in
      "$SB_TARGET="*) printf '%s\n' "${_kv#*=}"; return 0 ;;
    esac
  done
  return 1
}

# sb_rel URL — substitute the tokens release hosts use.
sb_rel() {
  _u=$1
  _u=$(printf '%s' "$_u" | sed "s/@V@/$SB_VERSION/g")
  _u=$(printf '%s' "$_u" | sed "s/@ARCH@/${REL_ARCH:-$SB_ARCH}/g")
  _u=$(printf '%s' "$_u" | sed "s/@OS@/${REL_OS:-$SB_OS}/g")
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
