#!/bin/sh
# Shared JRE builder for tools/java and tools/kotlin. Sourced, never executed.
#
# Both bundles call sb_make_jre with the same arguments, produce a byte-identical
# tree, hash to the same layer, and therefore store one JRE on a machine that
# carries java, kotlin and gradle.
#
# Why jlink and not the full JDK: a compiler needs java.compiler + jdk.compiler
# + jdk.jdeps + zipfs; the rest of the JDK is ~180 MiB of modules nothing in a
# build ever touches.

SB_JAVA_MAJOR=${SB_JAVA_MAJOR:-21}

sb_jre_modules() {
  printf '%s' 'java.base,java.compiler,java.datatransfer,java.desktop,java.instrument,java.logging,java.management,java.naming,java.net.http,java.prefs,java.security.jgss,java.security.sasl,java.sql,java.xml,jdk.compiler,jdk.javadoc,jdk.jdeps,jdk.zipfs,jdk.unsupported,jdk.charsets'
}

# sb_jdk_root -> prints the cached, unpacked Temurin JDK root
sb_jdk_root() {
  case "$SB_ARCH" in
    aarch64|arm64) _a=aarch64 ;;
    x86_64)        _a=x64 ;;
    *) die "temurin: no $SB_ARCH build (arm32/386/riscv have no current JDK)" ;;
  esac
  case "$SB_TARGET" in
    macos-*)   _os=mac ;;
    windows-*) _os=windows ;;
    *)         _os=linux ;;
  esac
  case "$_os" in
    windows) _ext=zip ;;
    *)       _ext=tar.gz ;;
  esac
  _f=$SB_CACHE/temurin-$SB_JAVA_MAJOR-$_os-$_a.$_ext
  if [ ! -f "$_f" ]; then
    log "fetch temurin $SB_JAVA_MAJOR ($_os-$_a)"
    curl -fsSL --retry 3 --retry-delay 2 -o "$_f.part" \
      "https://api.adoptium.net/v3/binary/latest/$SB_JAVA_MAJOR/ga/$_os/$_a/jdk/hotspot/normal/eclipse?project=jdk" \
      || die "temurin download failed"
    mv "$_f.part" "$_f"
  fi
  if [ -d "$SB_CACHE/temurin-$SB_JAVA_MAJOR-$_os-$_a" ]; then
    printf '%s\n' "$SB_CACHE/temurin-$SB_JAVA_MAJOR-$_os-$_a"
    return 0
  fi
  sb_unpack "$_f" "$SB_CACHE/temurin-$SB_JAVA_MAJOR-$_os-$_a"
  _r=$(find "$SB_CACHE/temurin-$SB_JAVA_MAJOR-$_os-$_a" -maxdepth 2 -type d -name 'jdk-*' | head -1)
  [ -n "$_r" ] || die "temurin: unexpected archive layout"
  printf '%s\n' "$_r"
}

# sb_make_jre DEST — jlink a runtime into DEST
sb_make_jre() {
  _dest=$1
  [ -x "$_dest/bin/java" ] && return 0
  _jdk=$(sb_jdk_root)
  log "jlink $SB_JAVA_MAJOR → $_dest"
  rm -rf "$_dest"
  "$_jdk/bin/jlink" \
    --add-modules "$(sb_jre_modules)" \
    --strip-debug --no-man-pages --no-header-files \
    --compress=zip-6 --module-info=java.base \
    --output "$_dest" || die "jlink failed"
  # os/arch-specific bits are fine, but the module list must be complete enough
  # to compile: javac without java.compiler fails at startup, not at compile time.
  [ -x "$_dest/bin/javac" ] || die "jlink produced a runtime without javac"
}
