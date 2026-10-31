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

# Theos versions itself by git tag (2.x); it has no 2024.11. Logos only tags
# 1.0.0 and then moves on master, so it is pinned by commit.
sb_git https://github.com/theos/theos.git "$SB_VERSION" theos || die "theos clone failed"
SB_THEOS_COMMIT=$(git -C "$SB_WORK/src/theos" rev-parse HEAD)

if [ ! -d "$SB_WORK/src/theos/bin/logos" ]; then
  sb_git https://github.com/theos/logos.git "${SB_LOGOS_COMMIT:-365a4e7028234e90bc2cbc724e5c87607130d3b3}" \
    theos-logos || die "logos clone failed"
  mkdir -p "$SB_WORK/src/theos/bin"
  rm -rf "$SB_WORK/src/theos/bin/logos"
  mv "$SB_WORK/src/theos-logos" "$SB_WORK/src/theos/bin/logos"
fi
SB_LOGOS_SHA=$(git -C "$SB_WORK/src/theos/bin/logos" rev-parse HEAD)

mkdir -p "$SB_STAGE/theos"
( cd "$SB_WORK/src/theos" && tar -cf - \
    --exclude='.git' --exclude='docs' --exclude='*.md' . ) | \
  ( cd "$SB_STAGE/theos" && tar -xf - )

mkdir -p "$SB_STAGE/bin"
# The front door is a shell script, which iOS cannot exec directly - the verifier
# caught it as "entry is script, expected macho". On a Darwin target the script
# lives in the payload and bin/theos is a native shim that execs /bin/sh with it;
# on the Linux/macOS columns a shebang script is fine and is what users expect.
cat > "$SB_STAGE/theos/theos.sh" <<'SH'
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
chmod 755 "$SB_STAGE/theos/theos.sh"

case "$SB_FAMILY" in
  macho) sb_sh_shim theos theos/theos.sh ;;
  *)     cp "$SB_STAGE/theos/theos.sh" "$SB_STAGE/bin/theos"
         chmod 755 "$SB_STAGE/bin/theos" ;;
esac

# Logos ships as Perl; make it callable without a PATH edit.
if [ -f "$SB_STAGE/theos/bin/logos.pl" ]; then
  ln -sf ../theos/bin/logos.pl "$SB_STAGE/bin/logos.pl"
fi

export SB_PATHS="bin"
export SB_ENTRY="bin/theos"
export SB_REQUIRE="clang make ldid dpkg-deb perl"
export SB_ENV='"THEOS": "${ROOT}/theos"'

# The artifact name carries the theos tag; what actually runs is two commits.
printf 'theos %s\nlogos %s\n' "$SB_THEOS_COMMIT" "$SB_LOGOS_SHA" > "$SB_STAGE/theos/.provenance"
sb_finish
