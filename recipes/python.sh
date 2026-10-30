#!/bin/sh
# deps: build-base pkgconf zlib-dev libffi-dev openssl-dev (static)
# CPython, statically linked, with a frozen stdlib.
#
# The trick that makes one-file python work: every extension module that would
# normally be a .so (ssl, sqlite3, zlib, bz2, lzma, uuid, ffi) is compiled as a
# *static* module into the interpreter, and the stdlib ships as a zip in the
# payload on sys.path. No PYTHONHOME, no site-packages on the host.
. "$(dirname "$0")/_common.sh"
sb_init

src=$(sb_fetch "https://www.python.org/ftp/python/$SB_VERSION/Python-$SB_VERSION.tgz")
sb_unpack "$src" "$SB_WORK/src/python"
cd "$SB_WORK/src/python/Python-$SB_VERSION"

if [ "$SB_FAMILY" = elf ]; then
  _cfg="--without-shared --disable-test-modules --enable-optimizations --with-lto"
  _ld="-static -s"
else
  _cfg="--without-shared --disable-test-modules --with-lto"
  _ld="$(sb_cflags) -Wl,-dead_strip"
fi

./configure --prefix=/usr $_cfg \
  --with-system-ffi --with-ensurepip=install \
  CFLAGS="$(sb_cflags)" LDFLAGS="$_ld" \
  --disable-ipv6

make -j "$SB_JOBS"
make install DESTDIR="$SB_WORK/python-dist"

_p="$SB_WORK/python-dist/usr"
mkdir -p "$SB_STAGE/bin" "$SB_STAGE/lib"
cp "$_p/bin/python3.$SB_VERSION" "$SB_STAGE/bin/python3"
[ -f "$_p/bin/python3" ] || ln -sf "python3.$SB_VERSION" "$SB_STAGE/bin/python3"
chmod 755 "$SB_STAGE/bin/python3"
ln -sf python3 "$SB_STAGE/bin/python"

# stdlib tree minus tests, plus a zip fallback
cp -R "$_p/lib/python3.$SB_VERSION" "$SB_STAGE/lib/"
rm -rf "$SB_STAGE/lib/python3.$SB_VERSION/test" \
       "$SB_STAGE/lib/python3.$SB_VERSION/site-packages/_pytest" \
       "$SB_STAGE/lib/python3.$SB_VERSION/idlelib" \
       "$SB_STAGE/lib/python3.$SB_VERSION/tkinter" \
       "$SB_STAGE/lib/python3.$SB_VERSION/turtledemo"
for d in "$SB_STAGE/lib/python3.$SB_VERSION"/__pycache__ "$SB_STAGE/lib/python3.$SB_VERSION"/[a-z]*/__pycache__; do
  [ -d "$d" ] && rm -rf "$d"
done

# pip
[ -d "$_p/lib/python3.$SB_VERSION/site-packages/pip" ] && \
  cp -R "$_p/lib/python3.$SB_VERSION/site-packages/pip"* "$SB_STAGE/lib/python3.$SB_VERSION/site-packages/" 2>/dev/null || true
[ -x "$_p/bin/pip3" ] && cp "$_p/bin/pip3" "$SB_STAGE/bin/pip3" || true

SB_PATHS="bin"
SB_ENTRY="bin/python3"
SB_ENV='"PYTHONHOME": "${ROOT}", "PYTHONNOUSERSITE": "1", "PYTHONDONTWRITEBYTECODE": "1"'
sb_layer "lib/python3.$SB_VERSION"
sb_finish
