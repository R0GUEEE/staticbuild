#!/bin/sh
# deps: (none)
# OpenJDK 21 (Temurin), jlink'd down to the modules a compiler needs.
#
# The JVM dlopens libjvm, libnio, libzip, libnet — so this is an sfx bundle by
# construction. jlink removes ~120 MiB of modules no build tool touches.
. "$(dirname "$0")/_common.sh"
sb_init

case "$SB_TARGET" in
  linux-arm64) _t=aarch64_linux ;;
  linux-x86_64) _t=x64_linux ;;
  macos-arm64) _t=aarch64_mac ;;
  *) die "java: no Temurin build for $SB_TARGET" ;;
esac
SB_JAVA_MAJOR=${SB_JAVA_MAJOR:-21}

src=$(sb_fetch "https://api.adoptium.net/v3/binary/latest/$SB_JAVA_MAJOR/ga/linux/${_t%%_*}/jdk/hotspot/normal/eclipse")
sb_unpack "$src" "$SB_WORK/src/jdk"
_jdk=$(find "$SB_WORK/src/jdk" -maxdepth 2 -type d -name 'jdk-*' | head -1)
[ -d "$_jdk" ] || die "unexpected Temurin layout"

# jlink a runtime carrying exactly the toolchain modules.
"$_jdk/bin/jlink" \
  --add-modules java.base,java.compiler,java.desktop,java.logging,java.management,\
java.naming,java.net.http,java.prefs,java.security.jgss,java.security.sasl,java.sql,\
java.xml,jdk.compiler,jdk.javadoc,jdk.jdeps,jdk.zipfs,jdk.unsupported,jdk.charsets \
  --strip-debug --no-man-pages --no-header-files --compress=zip-6 \
  --output "$SB_STAGE/jre"

mkdir -p "$SB_STAGE/bin"
for b in java javac jar jlink jdeps javap jshell keytool; do
  [ -x "$SB_STAGE/jre/bin/$b" ] && ln -sf "../jre/bin/$b" "$SB_STAGE/bin/$b"
done

export SB_PATHS="bin jre/bin"
export SB_ENTRY="bin/javac"
export SB_ENV='"JAVA_HOME": "${ROOT}/jre"'
sb_layer jre
sb_finish
