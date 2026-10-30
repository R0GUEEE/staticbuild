#!/bin/sh
# deps: perl make (for running, not building)
# Theos + Logos. $THEOS is a tree of makefiles and scripts; the "compiler" is
# whatever clang the host has, which is why this bundle declares requires
# instead of pretending to be self-contained.
#
# Layout the bundle reproduces:
#   theos/               $THEOS
#   theos/bin/logos.pl   Logos preprocessor (perl)
#   theos/toolchain/bin  wrappers that find the real clang/ldid/dpkg-deb
. "$(dirname "$0")/_common.sh"
sb_init

sb_git https://github.com/theos/theos.git "$SB_VERSION" theos || die "theos clone failed"

# Logos lives in its own repo and is vendored under bin/
if [ ! -d "$SB_WORK/src/theos/bin/logos" ]; then
  git clone --depth 1 --branch "$SB_VERSION" https://github.com/theos/logos.git \
    "$SB_WORK/src/theos/bin/logos" 2>/dev/null || \
  git clone --depth 1 https://github.com/theos/logos.git "$SB_WORK/src/theos/bin/logos"
fi

mkdir -p "$SB_STAGE/theos"
( cd "$SB_WORK/src/theos" && tar -cf - \
    --exclude='.git' --exclude='docs' --exclude='*.md' . ) | \
  ( cd "$SB_STAGE/theos" && tar -xf - )

mkdir -p "$SB_STAGE/bin"
cat > "$SB_STAGE/bin/theos" <<'SH'
#!/bin/sh
# Thin front door: prints the layout, sets up a shell with $THEOS exported.
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
case "${1:-}" in
  --version) sed -n 's/^THEOS_VERSION=//p' "$HERE/theos/makefiles/common.mk" 2>/dev/null || echo unknown ;;
  --path)    echo "$HERE/theos" ;;
  env)       THEOS="$HERE/theos" "$SHELL" -l ;;
  *)         THEOS="$HERE/theos" make -f "$HERE/theos/makefiles/instance/rules.mk" "$@" 2>/dev/null || \
             printf 'usage: theos [--version|--path|env]\n' ;;
esac
SH
chmod 755 "$SB_STAGE/bin/theos"

# Logos ships as Perl; make it callable without a PATH edit.
if [ -f "$SB_STAGE/theos/bin/logos.pl" ]; then
  ln -sf ../theos/bin/logos.pl "$SB_STAGE/bin/logos.pl"
fi

export SB_PATHS="bin"
export SB_ENTRY="bin/theos"
export SB_REQUIRE="clang make ldid dpkg-deb perl"
export SB_ENV='"THEOS": "${ROOT}/theos"'
sb_finish
