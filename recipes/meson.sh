#!/bin/sh
# deps: (none) + the python bundle
# Meson. It is Python, so the whole recipe is: take the wheel, put it in the
# payload, rewrite the shebang to the bundled interpreter. No venv, no pip
# resolution at run time.
. "$(dirname "$0")/_common.sh"
sb_init

_py="$SB_DIST/python-3.12.7-$([ "$SB_TARGET" = ios-arm64 ] && echo ios-arm64 || echo linux-arm64)"
_meson="https://files.pythonhosted.org/packages/source/m/meson/meson-$SB_VERSION.tar.gz"
src=$(sb_fetch "$_meson")
sb_unpack "$src" "$SB_WORK/src/meson"
_m=$(find "$SB_WORK/src/meson" -maxdepth 1 -type d -name 'meson-*' | head -1)

mkdir -p "$SB_STAGE/lib"
cp -R "$_m/mesonbuild" "$SB_STAGE/lib/mesonbuild"
cp -R "$_m/meson.py" "$SB_STAGE/lib/meson.py" 2>/dev/null || true
mkdir -p "$SB_STAGE/bin"
cat > "$SB_STAGE/bin/meson" <<'SH'
#!/bin/sh
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
exec "$HERE/bin/python3" -S "$HERE/lib/meson.py" "$@"
SH
chmod 755 "$SB_STAGE/bin/meson"

# samu: the ninja-compatible build driver, ~60 KiB vs ninja's 2 MiB payload
if src_samu=$(sb_fetch "https://github.com/michaelforney/samurai/releases/download/$SB_VERSION/samurai-$SB_VERSION.tar.gz" 2>/dev/null); then
  sb_unpack "$src_samu" "$SB_WORK/src/samurai"
  ( cd "$SB_WORK/src/samurai/samurai-$SB_VERSION" && \
    make -j "$SB_JOBS" CFLAGS="$(sb_cflags) $([ "$SB_FAMILY" = elf ] && echo -static)" )
  sb_bin "$SB_WORK/src/samurai/samurai-$SB_VERSION/samu" samu
  ln -sf samu "$SB_STAGE/bin/ninja"
fi

export SB_PATHS="bin"
export SB_REQUIRE="python3"
export SB_ENTRY="bin/meson"
sb_finish
