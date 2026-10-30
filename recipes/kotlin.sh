#!/bin/sh
# deps: (none) + the java bundle
# Kotlin compiler. It is a JVM program, so this bundle shares the jre21 layer
# with tools/java: shipping java + kotlin + gradle costs one JRE on disk.
. "$(dirname "$0")/_common.sh"
sb_init

_jv="$SB_WORK/cache/java-layer"
if [ -d "$SB_STAGE/jre" ]; then
  _jre="$SB_STAGE/jre"
elif [ -d "$_jv" ]; then
  _jre="$_jv"
else
  die "kotlin: build tools/java first (it produces the jre21 layer), or set SB_JRE=/path/to/jre"
fi

src=$(sb_fetch "https://github.com/JetBrains/kotlin/releases/download/v$SB_VERSION/kotlin-compiler-$SB_VERSION.zip")
sb_unpack "$src" "$SB_WORK/src/kotlin"
_k="$SB_WORK/src/kotlin/kotlinc"
[ -d "$_k" ] || die "unexpected kotlinc layout"

# The wrapper execs $HERE/jre/bin/java, so the JRE has to be in *this* stage.
# Copying it and layering the copy produces the same content hash as tools/java,
# which is exactly what makes the two bundles share one JRE on disk.
if [ ! -d "$SB_STAGE/jre" ]; then
  mkdir -p "$SB_STAGE/jre"
  ( cd "$_jre" && tar -cf - . ) | ( cd "$SB_STAGE/jre" && tar -xf - )
fi

mkdir -p "$SB_STAGE/bin" "$SB_STAGE/lib"
cp -R "$_k/lib" "$SB_STAGE/lib/kotlinc-lib"
cp -R "$_k/bin" "$SB_STAGE/lib/kotlinc-bin"

# Wrapper that calls the *bundled* JVM with the bundled classpath, no JAVA_HOME
# guessing and no $KOTLIN_HOME requirement on the user's side.
cat > "$SB_STAGE/bin/kotlinc" <<'SH'
#!/bin/sh
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
exec "$HERE/jre/bin/java" -Xmx2g -Xss1m \
  -Djava.awt.headless=true \
  -cp "$HERE/lib/kotlinc-lib/kotlin-compiler.jar:$HERE/lib/kotlinc-lib/kotlin-stdlib.jar:$HERE/lib/kotlinc-lib/kotlin-reflect.jar:$HERE/lib/kotlinc-lib/kotlin-script-runtime.jar:$HERE/lib/kotlinc-lib/trove4j.jar:$HERE/lib/kotlinc-lib/annotations-13.0.jar" \
  org.jetbrains.kotlin.cli.jvm.K2JVMCompiler "$@"
SH
chmod 755 "$SB_STAGE/bin/kotlinc"
ln -sf kotlinc "$SB_STAGE/bin/kotlinc-jvm"

SB_PATHS="bin"
SB_ENTRY="bin/kotlinc"
SB_ENV='"KOTLIN_HOME": "${ROOT}/lib"'
sb_layer lib/kotlinc-lib
sb_layer jre
sb_finish
