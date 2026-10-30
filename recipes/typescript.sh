#!/bin/sh
# deps: (none)
# TypeScript as a Node single-executable application: tsc and tsserver become
# one file each, with the compiler bundle embedded in a node binary.
#
# Three facts make this work and each one cost a round trip somewhere:
#  * SEA embeds exactly one JS file, so the compiler has to be bundled first —
#    lib/tsc.js is a loader over a dozen requires, not a self-contained script;
#  * the blob is injected with postject against a sentinel fuse, and the fuse
#    must match the node version's string exactly;
#  * the output is a copy of node with a payload, so it is glibc-dynamic and
#    the bundle is one bare file, not an sfx.
. "$(dirname "$0")/_common.sh"
sb_init

case "$SB_TARGET" in
  linux-arm64)  _t=linux-arm64 ;;
  linux-x86_64) _t=linux-x64 ;;
  *) die "typescript: no node host for $SB_TARGET" ;;
esac

_node_src=$(sb_fetch "https://nodejs.org/dist/v${SB_NODE_VERSION:-22.11.0}/node-v${SB_NODE_VERSION:-22.11.0}-$_t.tar.xz")
sb_unpack "$_node_src" "$SB_WORK/src/node-for-ts"
_node=$(find "$SB_WORK/src/node-for-ts" -maxdepth 3 -name node -type f | head -1)
[ -x "$_node" ] || die "typescript: no node binary in the tarball"
_node_dir=$(dirname "$_node")
PATH="$_node_dir:$PATH"
export PATH

_np=$(sb_fetch "https://registry.npmjs.org/typescript/-/typescript-$SB_VERSION.tgz")
mkdir -p "$SB_WORK/src/ts"
tar -xzf "$_np" -C "$SB_WORK/src/ts"
_pkg="$SB_WORK/src/ts/package"

mkdir -p "$SB_WORK/sea"
# esbuild turns the CommonJS graph into one file; it is the only bundler that
# runs as a single static binary on the build host.
( cd "$SB_WORK/sea" && npm --no-audit --no-fund --silent exec --yes -- \
    esbuild@0.24.0 "$_pkg/lib/tsc.js" --bundle --platform=node --format=cjs \
    --outfile=tsc.bundle.js ) > "$SB_WORK/sea/bundle.log" 2>&1 || {
      tail -20 "$SB_WORK/sea/bundle.log" >&2
      die "typescript: esbuild bundling failed"
    }
( cd "$SB_WORK/sea" && npm --no-audit --no-fund --silent exec --yes -- \
    esbuild@0.24.0 "$_pkg/lib/tsserver.js" --bundle --platform=node --format=cjs \
    --outfile=tsserver.bundle.js ) >> "$SB_WORK/sea/bundle.log" 2>&1 || \
    warn "typescript: tsserver bundle failed (tsc still ships)"

cat > "$SB_WORK/sea/sea-config.json" <<'JSON'
{
  "main": "tsc.bundle.js",
  "output": "tsc.blob",
  "disableExperimentalSEAWarning": true,
  "useSnapshot": false,
  "useCodeCache": false
}
JSON
( cd "$SB_WORK/sea" && "$_node" --experimental-sea-config sea-config.json ) \
  || die "typescript: node SEA generation failed"

mkdir -p "$SB_STAGE/bin"
cp "$_node" "$SB_STAGE/bin/tsc"
chmod 755 "$SB_STAGE/bin/tsc"
( cd "$SB_WORK/sea" && npm --no-audit --no-fund --silent exec --yes -- \
    postject "$SB_STAGE/bin/tsc" NODE_SEA_BLOB tsc.blob \
    --sentinel-fuse NODE_SEA_FUSE_fce680ab2cc467b6e072b8b5df1996b2 ) \
  || die "typescript: postject failed"

if [ -f "$SB_WORK/sea/tsserver.bundle.js" ]; then
  sed 's|tsc.bundle.js|tsserver.bundle.js|; s|tsc.blob|tsserver.blob|' \
    "$SB_WORK/sea/sea-config.json" > "$SB_WORK/sea/sea-tsserver.json"
  ( cd "$SB_WORK/sea" && "$_node" --experimental-sea-config sea-tsserver.json ) && \
  cp "$_node" "$SB_STAGE/bin/tsserver" && chmod 755 "$SB_STAGE/bin/tsserver" && \
  ( cd "$SB_WORK/sea" && npm --no-audit --no-fund --silent exec --yes -- \
      postject "$SB_STAGE/bin/tsserver" NODE_SEA_BLOB tsserver.blob \
      --sentinel-fuse NODE_SEA_FUSE_fce680ab2cc467b6e072b8b5df1996b2 ) || \
    warn "typescript: tsserver SEA skipped"
fi

# The injected binary is the whole tool; the stage carries only meta.json next
# to it, so sb_finish copies it out as a bare executable.
export SB_PATHS="bin"
export SB_ENTRY="bin/tsc"
export SB_ALIASES=""
sb_alias "tsserver=bin/tsserver"
sb_finish
