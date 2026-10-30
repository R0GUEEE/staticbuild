#!/bin/sh
# deps: build-base pkgconf zlib-dev libffi-dev openssl-dev sqlite-dev xz-dev bzip2-dev ncurses-dev readline-dev gdbm-dev
# CPython, statically linked, every extension module linked in.
#
# python.sh and meson.sh share recipes/_python.sh, so the interpreter is built
# the same way whether you asked for python or for the build system that runs
# on top of it.
. "$(dirname "$0")/_common.sh"
. "$(dirname "$0")/_python.sh"
sb_init

sb_build_python ensurepip

mkdir -p "$SB_STAGE/bin" "$SB_STAGE/lib"
cp "$SB_PY_PREFIX/bin/python3" "$SB_STAGE/bin/python3"
ln -sf python3 "$SB_STAGE/bin/python"
ln -sf python3 "$SB_STAGE/bin/python3.$SB_PY_VERSION"
cp -R "$SB_PY_PREFIX/lib/python3.$SB_PY_VERSION" "$SB_STAGE/lib/"
sb_alias "python=bin/python" "python3.$SB_PY_VERSION=bin/python3.$SB_PY_VERSION"

if [ -x "$SB_PY_PREFIX/bin/pip3" ] || [ -f "$SB_STAGE/lib/python3.$SB_PY_VERSION/site-packages/pip/__main__.py" ]; then
  sb_wrapper pip3 <<'WRAP'
#!/bin/sh
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
exec "$HERE/bin/python3" -m pip "$@"
WRAP
  sb_alias "pip=bin/pip3"
fi

export SB_PATHS="bin"
export SB_ENTRY="bin/python3"
export SB_ENV='"PYTHONHOME": "${ROOT}", "PYTHONNOUSERSITE": "1", "PYTHONDONTWRITEBYTECODE": "1"'
sb_layer "lib/python3.$SB_PY_VERSION"
sb_finish
