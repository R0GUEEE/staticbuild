#!/bin/sh
# Shared static-CPython builder for tools/python and tools/meson. Sourced.
#
# The single fact that makes one-file python possible: a statically linked
# interpreter cannot dlopen, so every extension module it might import has to be
# linked in. CPython honours that with one line in Modules/Setup.local:
#
#     *static*
#
# which tells the build system to link every module listed in Setup.stdlib into
# the binary instead of emitting lib-dynload/*.so. Without it you get a static
# `python3` that dies on `import ssl`, which is the failure mode everyone hits.

SB_PY_VERSION=${SB_PY_VERSION:-3.12.7}
# The install tree is lib/python3.12 while the binary is python3.12.7; conflating
# the two is how `cp -R .../python3.3.12.7` happened.
SB_PY_MM=${SB_PY_MM:-$(printf '%s' "$SB_PY_VERSION" | cut -d. -f1,2)}
SB_PY_PREFIX=${SB_PY_PREFIX:-$SB_WORK/python-static}

# sb_build_python [ensurepip]  -> $SB_PY_PREFIX/{bin/python3,lib/python3.X}
sb_build_python() {
  _pip=${1:-no}
  if [ -x "$SB_PY_PREFIX/bin/python3" ] && [ -d "$SB_PY_PREFIX/lib/python3.$SB_PY_MM" ]; then
    return 0
  fi
  src=$(sb_fetch "https://www.python.org/ftp/python/$SB_PY_VERSION/Python-$SB_PY_VERSION.tgz")
  sb_unpack "$src" "$SB_WORK/src/python"
  sb_cd "$SB_WORK/src/python/Python-$SB_PY_VERSION"

  printf '*static*\n' > Modules/Setup.local

  case "$_pip" in
    ensurepip) _ep=--with-ensurepip=install ;;
    *)         _ep=--without-ensurepip ;;
  esac
  # ensurepip boots the interpreter we just built and installs pip from a
  # bundled wheel; that fails while the tree is still in build/, so the python
  # bundle ships without pip and meson does not ask for it.
  [ "$_pip" = ensurepip ] && _ep=--without-ensurepip

  log "configure python $SB_PY_VERSION (static, all extensions linked in)"
  sb_configure --prefix=/usr --without-shared --disable-test-modules \
      --without-doc-strings --disable-ipv6 $_ep \
      CFLAGS="-O2 -fPIC" LDFLAGS="$(sb_ldflags) -s" \
      > "$SB_WORK/python-configure.log" 2>&1 || {
        tail -40 "$SB_WORK/python-configure.log" >&2
        die "python configure failed"
      }

  # `*static*` in Setup.local only sets the default for modules that file
  # defines. The generated Modules/Setup.stdlib carries an explicit *shared*
  # marker per module, and that marker wins — which is why the first attempt
  # still produced lib-dynload/*.so and then failed to link them with -static.
  # Rewriting the generated file is what actually links the modules in.
  for _f in Modules/Setup.stdlib Modules/Setup; do
    [ -f "$_f" ] && sed -i 's/^\*shared\*/*static*/' "$_f" || true
  done
  log "extension modules: $(grep -c '^\*static\*' Modules/Setup.stdlib 2>/dev/null || echo 0) static groups"

  make -j "$SB_JOBS" > "$SB_WORK/python-make.log" 2>&1 || {
    tail -60 "$SB_WORK/python-make.log" >&2
    die "python build failed"
  }
  make install DESTDIR="$SB_WORK/python-dist" > "$SB_WORK/python-install.log" 2>&1 || {
    tail -40 "$SB_WORK/python-install.log" >&2
    die "python install failed"
  }

  rm -rf "$SB_PY_PREFIX"
  mkdir -p "$SB_PY_PREFIX/bin" "$SB_PY_PREFIX/lib"
  _b=$(find "$SB_WORK/python-dist/usr/bin" -maxdepth 1 -name 'python3.*' -type f | head -1)
  [ -n "$_b" ] || die "python: no interpreter was installed"
  cp "$_b" "$SB_PY_PREFIX/bin/python3"
  chmod 755 "$SB_PY_PREFIX/bin/python3"
  cp -R "$SB_WORK/python-dist/usr/lib/python3.$SB_PY_MM" "$SB_PY_PREFIX/lib/"

  # Tests, IDLE and tkinter are between a third and a half of the stdlib and no
  # build tool on this device imports them.
  _lib=$SB_PY_PREFIX/lib/python3.$SB_PY_MM
  rm -rf "$_lib/test" "$_lib/idlelib" "$_lib/tkinter" "$_lib/turtledemo" \
         "$_lib/lib2to3" "$_lib/ensurepip" "$_lib/pydoc_data"
  find "$_lib" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true
  find "$_lib/lib-dynload" -name '*.so' -delete 2>/dev/null || true
  rmdir "$_lib/lib-dynload" 2>/dev/null || true

  if [ "$_pip" = ensurepip ] && [ -d "$SB_WORK/python-dist/usr/lib/python3.$SB_PY_MM/site-packages/pip" ]; then
    mkdir -p "$_lib/site-packages"
    cp -R "$SB_WORK/python-dist/usr/lib/python3.$SB_PY_MM/site-packages/pip" \
          "$SB_WORK/python-dist/usr/lib/python3.$SB_PY_MM/site-packages/pip-".* \
          "$_lib/site-packages/" 2>/dev/null || true
  fi

  # Proof, not hope: this is the check that catches a missing *static* marker.
  _out=$("$SB_PY_PREFIX/bin/python3" -c 'import ssl,zlib,sqlite3,hashlib,_ctypes;print("ok")' 2>&1) || {
    printf '%s\n' "$_out" >&2
    die "static python cannot import its own modules (check Modules/Setup.local)"
  }
  [ "$_out" = ok ] || die "static python self-test said: $_out"
  log "python $SB_PY_VERSION static, extensions linked in"
}
