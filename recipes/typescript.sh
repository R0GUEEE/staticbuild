#!/bin/sh
# deps: (none) + the java bundle
# TypeScript as a Node single-executable-application: tsc and tsserver become
# one file each, with the compiler bundle embedded in the node binary.
#
# Why SEA and not `pkg`/`bun`: SEA is upstream, needs no extra runtime, and
# works with the jitless node build the iOS bundle uses.
. "$(dirname "$0")/_common.sh"
sb_init

case "$SB_TARGET" in
  linux-arm64) _node_t=linux-arm64 ;;
  linux-x86_64) _node_t=linux-x64 ;;
  ios-arm64) _node_t=ios-arm64 ;;
  *) die "typescript: no node host for $SB_TARGET" ;;
esac

# Requires the matching node bundle to have been built first.
_node="$SB_DIST/node-$SB_VERSION-$_node_t"
[ -x "$_node" ] || die "build tools/node for $_node_t first (looked for $_node)"

_np=$(sb_fetch "https://registry.npmjs.org/typescript/-/typescript-$SB_VERSION.tgz")
mkdir -p "$SB_WORK/src/ts"
tar -xzf "$_np" -C "$SB_WORK/src/ts"
_pkg="$SB_WORK/src/ts/package"

node --version >/dev/null 2>&1 || die "node not on PATH (needed for the SEA build)"

# 1. bundle the compiler into one script
mkdir -p "$SB_WORK/sea"
node - "$_pkg" "$SB_WORK/sea/tsc.js" <<'JS'
const path = require('path');
const fs = require('fs');
const [pkg, out] = process.argv.slice(2);
const entry = path.join(pkg, 'lib', 'tsc.js');
// TypeScript ships as CommonJS with its own module registry; a thin require
// shim is enough because every lib/*.js file is present in the payload.
const src = fs.readFileSync(entry, 'utf8');
fs.writeFileSync(out, src);
JS

# 2. SEA blob, then inject into a copy of node (postject is the sanctioned tool)
cat > "$SB_WORK/sea/sea-config.json" <<'JSON'
{
  "main": "tsc.js",
  "output": "tsc.blob",
  "disableExperimentalSEAWarning": true,
  "useSnapshot": false,
  "useCodeCache": false
}
JSON
node --experimental-sea-config "$SB_WORK/sea/sea-config.json" 2>/dev/null || \
  die "node SEA is unavailable in this node build"

cp "$_node" "$SB_STAGE/bin/tsc"
chmod 755 "$SB_STAGE/bin/tsc"
npx --yes postject "$SB_STAGE/bin/tsc" NODE_SEA_BLOB "$SB_WORK/sea/tsc.blob" \
  --sentinel-fuse NODE_SEA_FUSE_fce680ab2cc467b6e072b8b5df1996b2 || \
  die "postject failed"

# tsserver: same trick, different entry
sed 's|"main": "tsc.js"|"main": "tsserver.js"|; s|"output": "tsc.blob"|"output": "tsserver.blob"|' \
  "$SB_WORK/sea/sea-config.json" > "$SB_WORK/sea/sea-tsserver.json"
cp "$_pkg/lib/tsserver.js" "$SB_WORK/sea/tsserver.js"
( cd "$SB_WORK/sea" && node --experimental-sea-config sea-tsserver.json ) || warn "tsserver SEA skipped"

SB_PATHS="bin"
SB_ENTRY="bin/tsc"
sb_finish
