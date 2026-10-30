#!/bin/sh
# deps: libncurses6 libfreetype6 libfontconfig1
# OpenJDK 21 (Temurin) jlink'd down to the modules a compiler needs.
#
# A JVM is never a static binary: libjvm.so dlopens libnio, libzip, libnet and
# libextnet at startup. The honest bundle is `layer` — a vendored runtime tree
# plus alias wrappers — and the JRE layer is shared byte-for-byte with kotlin
# (and with anything else built on recipes/_jre.sh).
. "$(dirname "$0")/_common.sh"
. "$(dirname "$0")/_jre.sh"
sb_init

sb_make_jre "$SB_STAGE/jre"

mkdir -p "$SB_STAGE/bin"
for b in java javac jar jlink jdeps javap jshell keytool; do
  [ -x "$SB_STAGE/jre/bin/$b" ] || continue
  sb_wrapper "$b" <<WRAP
#!/bin/sh
set -eu
HERE=\$(cd "\$(dirname "\$0")/.." && pwd)
exec "\$HERE/jre/bin/$b" "\$@"
WRAP
done

export SB_PATHS="bin"
export SB_ENTRY="bin/javac"
export SB_ENV='"JAVA_HOME": "${ROOT}/jre"'
sb_layer jre
sb_finish
