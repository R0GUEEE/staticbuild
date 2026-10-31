#!/usr/bin/env python3
"""Pack one or more staged trees into a single SBX2 bundle.

    pack.py --stub build/stub/sb-stub-linux-arm64 --out dist/ninja-1.12.1-linux-arm64 \
            --payload linux-arm64=build/stage/ninja-linux-arm64

    pack.py --stub build/stub/sb-stub-macos-universal --out dist/clang-...-macos-universal \
            --payload macos-arm64=... --payload macos-x86_64=...

Each payload root carries its own `.sb/meta.json` (written by `sb_meta` in
recipes/_common.sh): entry, PATH additions, env, aliases and layer hashes. The
target name supplies os/arch, looked up in manifest/tools.json so the target
table stays single-sourced.

Deterministic: entries sorted, modes normalised, blobs in digest order, index
with sorted keys. Same inputs + same SOURCE_DATE_EPOCH = byte-identical file.
"""
from __future__ import annotations

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sbx  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def load_targets(manifest_path: str) -> dict:
    try:
        with open(manifest_path) as fh:
            return json.load(fh).get("targets", {})
    except OSError:
        return {}


def payload_from(target: str, root: str, targets: dict, args) -> dict:
    meta_path = os.path.join(root, ".sb", "meta.json")
    if not os.path.isfile(meta_path):
        sys.exit("pack: %s has no .sb/meta.json (run sb_meta first)" % root)
    with open(meta_path) as fh:
        meta = json.load(fh)
    spec = targets.get(target, {})
    os_name = spec.get("os") or meta.get("os") or target.split("-")[0]
    arch = (spec.get("arch") or meta.get("arch")
            or (target.split("-")[1] if "-" in target else "unknown"))
    return {"id": target, "os": os_name, "arch": arch,
            "family": spec.get("family") or meta.get("family") or "elf",
            "tier": meta.get("tier") or args.tier or "sfx",
            "entry": meta.get("entry") or args.entry,
            "paths": meta.get("paths") or ["bin"],
            "env": meta.get("env") or {},
            "aliases": meta.get("aliases") or {},
            "layers": meta.get("layers") or [], "root": root}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--stub", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--payload", action="append", default=[], metavar="TARGET=DIR")
    ap.add_argument("--root", help="legacy single-payload form")
    ap.add_argument("--target", default=os.environ.get("SB_TARGET", "linux-arm64"))
    ap.add_argument("--manifest", default=os.path.join(ROOT, "manifest", "tools.json"))
    ap.add_argument("--tool")
    ap.add_argument("--version", default="0.0.0")
    ap.add_argument("--entry", default="bin/tool")
    ap.add_argument("--tier", default="sfx")
    ap.add_argument("--level", type=int, default=19)
    ap.add_argument("--epoch", type=int,
                    default=int(os.environ.get("SOURCE_DATE_EPOCH") or 1700000000))
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    targets = load_targets(args.manifest)
    specs = []
    for item in args.payload:
        target, _, root = item.partition("=")
        if not root:
            sys.exit("pack: --payload wants TARGET=DIR, got %r" % item)
        specs.append(payload_from(target, root, targets, args))
    if args.root:
        specs.append(payload_from(args.target, args.root, targets, args))
    if not specs:
        sys.exit("pack: nothing to pack (use --payload TARGET=DIR)")

    with open(args.stub, "rb") as fh:
        stub = fh.read()
    magic4 = stub[:4]
    if not (magic4 == b"\x7fELF" or stub[:2] == b"MZ"
            or magic4 in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe",
                          b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf")):
        sys.exit("pack: %s is not an ELF/Mach-O/PE executable (starts %r)" %
                 (args.stub, stub[:8]))

    tool = args.tool or specs[0]["entry"].rsplit("/", 1)[-1]
    os.makedirs(os.path.dirname(os.path.abspath(args.out)) or ".", exist_ok=True)
    try:
        info = sbx.write_bundle(args.out, stub, specs, tool, args.version,
                                epoch=args.epoch, level=args.level)
    except sbx.ZstdError as exc:
        sys.exit("pack: %s" % exc)
    info["out"] = args.out
    if not args.quiet:
        print(json.dumps(info))
    return 0


if __name__ == "__main__":
    sys.exit(main())
