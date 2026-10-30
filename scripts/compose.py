#!/usr/bin/env python3
"""Compose a universal bundle from per-slice bundles.

    compose.py --target macos-universal --tool clang --version 20.1.8 \
        --stub build/stub/sb-stub-macos-universal --out dist/clang-20.1.8-macos-universal \
        dist/clang-20.1.8-macos-arm64 dist/clang-20.1.8-macos-x86_64

Each input is an existing bundle (or a bare binary). Its payload tree is
extracted and re-packed under one carrier:

  macos-universal   fat Mach-O carrier (lipo of both stub slices). dyld picks the
                    slice, each slice runs its own payload.
  windows-universal x86_64 PE carrier. It runs natively on x64 and under
                    emulation on ARM64 Windows, where the stub reads
                    PROCESSOR_ARCHITEW6432 and runs the native arm64 payload.

The point is one download that is native everywhere, with shared files stored
once: the packer dedupes by content digest across payloads.
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
                payload = doc["index"]["payloads"][0]
                sbx.extract(doc, payload, root)
            except ValueError:
                # Bare binary: a static/macho artefact with no container.
                os.makedirs(os.path.join(root, "bin"), exist_ok=True)
                entry = "bin/" + os.path.basename(path)
                if not entry.endswith(".exe") and spec.get("family") == "pe":
                    entry += ".exe"
                shutil.copy2(path, os.path.join(root, entry))
                meta = {"entry": entry, "paths": ["bin"], "env": {}, "aliases": {},
                        "layers": [], "tier": "static", "family": spec["family"]}
                os.makedirs(os.path.join(root, ".sb"), exist_ok=True)
                with open(os.path.join(root, ".sb", "meta.json"), "w") as fh:
                    json.dump(meta, fh)
            specs.append({"id": slice_id, "os": spec["os"], "arch": spec["arch"],
                          "family": spec["family"], "root": root})

        # Reuse pack.py's payload/meta normalisation by importing it.
        import pack  # noqa: E402

        class Args:
            tier = "sfx"
            entry = "bin/" + args.tool

        payload_specs = [pack.payload_from(s["id"], s["root"], targets, Args()) for s in specs]
        os.makedirs(os.path.dirname(os.path.abspath(args.out)) or ".", exist_ok=True)
        info = sbx.write_bundle(args.out, stub, payload_specs, args.tool, args.version,
                                epoch=int(os.environ.get("SOURCE_DATE_EPOCH") or 1700000000))
        info["out"] = args.out
        print(json.dumps(info))
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
