#!/usr/bin/env python3
"""Compose a universal bundle out of per-slice bundles.

    compose.py --target macos-universal --tool clang --version 20.1.8 \
        --stub build/stub/sb-stub-macos-universal --out dist/clang-...-macos-universal \
        dist/clang-...-macos-arm64 dist/clang-...-macos-x86_64

  macos-universal    fat Mach-O carrier (lipo of both stub slices). dyld picks
                     the slice, each slice runs its own payload.
  windows-universal  x86_64 PE carrier that also carries the arm64 payload. It
                     runs natively on x64 and under emulation on ARM64 Windows,
                     where the stub reads PROCESSOR_ARCHITEW6432 and runs the
                     native arm64 tree.

Nothing is rebuilt: each input's payload is extracted and re-packed, and the
packer stores identical files once across payloads.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import sbx  # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--target", required=True)
    ap.add_argument("--tool", required=True)
    ap.add_argument("--version", default="0.0.0")
    ap.add_argument("--stub", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--manifest", default=os.path.join(os.path.dirname(HERE),
                                                       "manifest", "tools.json"))
    ap.add_argument("inputs", nargs="+")
    args = ap.parse_args()

    with open(args.manifest) as fh:
        targets = json.load(fh)["targets"]
    with open(args.stub, "rb") as fh:
        stub = fh.read()
    import pack  # noqa: E402  (payload normalisation lives in the packer)

    class Args:
        tier = "sfx"
        entry = "bin/" + args.tool

    specs, tmpdir = [], tempfile.mkdtemp(prefix="sb-compose-")
    try:
        for path in args.inputs:
            base = os.path.basename(path)
            slice_id = next((n for n in sorted(targets, key=len, reverse=True)
                             if base.endswith("-" + n)), None)
            if slice_id is None:
                print("compose: cannot tell which slice %s is" % base, file=sys.stderr)
                return 1
            spec = targets[slice_id]
            root = os.path.join(tmpdir, slice_id)
            try:
                doc = sbx.load(path)
                doc["path"] = path
                sbx.extract(doc, doc["index"]["payloads"][0], root)
            except (ValueError, KeyError):
                entry = "bin/" + base + (".exe" if spec.get("family") == "pe" else "")
                os.makedirs(os.path.join(root, "bin"), exist_ok=True)
                shutil.copy2(path, os.path.join(root, entry))
                os.remove(os.path.join(root, "bin", base)) if entry.endswith(".exe") else None
                os.makedirs(os.path.join(root, ".sb"), exist_ok=True)
                with open(os.path.join(root, ".sb", "meta.json"), "w") as fh:
                    json.dump({"entry": entry, "paths": ["bin"], "env": {}, "aliases": {},
                               "layers": [], "tier": "static", "family": spec["family"]}, fh)
            specs.append(pack.payload_from(slice_id, root, targets, Args()))
        os.makedirs(os.path.dirname(os.path.abspath(args.out)) or ".", exist_ok=True)
        info = sbx.write_bundle(args.out, stub, specs, args.tool, args.version,
                                epoch=int(os.environ.get("SOURCE_DATE_EPOCH") or 1700000000))
        info["out"] = args.out
        print(json.dumps(info))
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
