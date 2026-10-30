#!/bin/sh
# deps: (none)
# Kotlin compiler, on the JRE layer it shares with tools/java.
#
# The upstream kotlinc script execs $KOTLIN_HOME/jre/bin/java, which is a
# directory JetBrains expects you to have installed. The bundle instead builds
# the same jlink runtime java.sh builds — identical content, identical layer
# hash — so installing java, kotlin and gradle stores one JRE.
. "$(dirname "$0")/_common.sh"
. "$(dirname "$0")/_jre.sh"
sb_init

src=$(sb_fetch "https://github.com/JetBrains/kotlin/releases/download/v$SB_VERSION/kotlin-compiler-$SB_VERSION.zip")
sb_unpack "$src" "$SB_WORK/src/kotlin"
_k=$(find "$SB_WORK/src/kotlin" -maxdepth 2 -type d -name kotlinc | head -1)
[ -n "$_k" ] || die "kotlin: unexpected archive layout"

sb_make_jre "$SB_STAGE/jre"

mkdir -p "$SB_STAGE/bin" "$SB_STAGE/lib"
cp -R "$_k/lib" "$SB_STAGE/lib/kotlinc-lib"

# Wildcard classpath: the jar set changes between Kotlin releases (2.x added
# kotlin-daemon-embeddable and the scripting jars), and a fixed list silently
# breaks on the next version bump.
sb_wrapper kotlinc <<'WRAP'
#!/bin/sh
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
exec "$HERE/jre/bin/java" -Xmx2g -Xss1m -Djava.awt.headless=true \
  -cp "$HERE/lib/kotlinc-lib/*" \
  org.jetbrains.kotlin.cli.jvm.K2JVMCompiler "$@"
WRAP
sb_alias "kotlin=bin/kotlinc"

export SB_PATHS="bin"
export SB_ENTRY="bin/kotlinc"
export SB_ENV='"KOTLIN_HOME": "${ROOT}/lib"'
sb_layer jre
sb_layer lib/kotlinc-lib
sb_finish
