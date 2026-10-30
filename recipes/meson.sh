#!/bin/sh
# deps: build-base pkgconf zlib-dev libffi-dev openssl-dev sqlite-dev xz-dev bzip2-dev
# Meson, as one file that is its own interpreter.
#
# Meson is Python. Shipping it as a wheel plus a system python3 is what everyone
# does and it is why a "meson" install is 40 MB of someone else's problem. This
# bundle carries the static interpreter from recipes/_python.sh and the build
# system next to it; `meson --version` works with no python on PATH at all.
. "$(dirname "$0")/_common.sh"
. "$(dirname "$0")/_python.sh"
sb_init

sb_build_python

src=$(sb_fetch "https://files.pythonhosted.org/packages/source/m/meson/meson-$SB_VERSION.tar.gz")
sb_unpack "$src" "$SB_WORK/src/meson"
_m=$(find "$SB_WORK/src/meson" -maxdepth 1 -type d -name 'meson-*' | head -1)
[ -n "$_m" ] || die "meson: unexpected sdist layout"

mkdir -p "$SB_STAGE/bin" "$SB_STAGE/lib"
cp "$SB_PY_PREFIX/bin/python3" "$SB_STAGE/bin/python3"
cp -R "$SB_PY_PREFIX/lib/python3.$SB_PY_MM" "$SB_STAGE/lib/"
cp -R "$_m/mesonbuild" "$SB_STAGE/lib/mesonbuild"

# meson's entry point is mesonbuild/mesonmain.py:main, called through runpy so
# nothing depends on a console_script shim or on the current directory.
sb_wrapper meson <<'WRAP'
#!/bin/sh
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
exec "$HERE/bin/python3" -c 'import sys; sys.path.insert(0, sys.argv.pop(1)); from mesonbuild.mesonmain import main; sys.exit(main())' "$HERE/lib" "$@"
WRAP

export SB_PATHS="bin"
export SB_ENTRY="bin/meson"
export SB_REQUIRE=""
export SB_ENV='"PYTHONHOME": "${ROOT}", "PYTHONNOUSERSITE": "1", "PYTHONDONTWRITEBYTECODE": "1"'
sb_layer "lib/python3.$SB_PY_MM"
sb_finish
