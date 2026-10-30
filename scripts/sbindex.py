#!/usr/bin/env python3
"""Inspect or unpack an SBX2 bundle from any host (the stub does it on target).

    sbindex.py info     dist/clang-20.1.8-universal
    sbindex.py payloads dist/clang-20.1.8-universal
    sbindex.py meta     dist/... --select windows-arm64
    sbindex.py extract  dist/... --select windows-arm64 --into /tmp/tree
    sbindex.py check    dist/...
"""
from __future__ import annotations

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sbx  # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["info", "payloads", "meta", "extract", "check", "index"])
    ap.add_argument("bundle")
    ap.add_argument("--select", default="")
    ap.add_argument("--into", default="")
    args = ap.parse_args()

    try:
        if args.cmd == "check":
            problems = sbx.check(args.bundle)
            for p in problems:
                print("FAIL:", p)
            print("%s: %s" % (os.path.basename(args.bundle),
                              "broken" if problems else "ok"))
            return 1 if problems else 0
        doc = sbx.load(args.bundle)
        idx, tr = doc["index"], doc["trailer"]
    except (ValueError, KeyError, OSError, sbx.ZstdError) as exc:
        print("sbindex: %s" % exc, file=sys.stderr)
        return 1

    if args.cmd == "index":
        print(json.dumps(idx, indent=2))
    elif args.cmd == "payloads":
        for p in idx["payloads"]:
            print("\t".join([p.get("id", ""), "%s/%s" % (p.get("os"), p.get("arch")),
                             p.get("entry", ""), str(p.get("bytes", 0))]))
    elif args.cmd == "meta":
        p = sbx.select(doc, args.select)
        print(json.dumps({k: v for k, v in p.items() if k != "files"}, indent=2,
                         sort_keys=True))
    elif args.cmd == "extract":
        if not args.into:
            print("sbindex: --into is required", file=sys.stderr)
            return 2
        print(sbx.extract(doc, sbx.select(doc, args.select), args.into))
    else:
        print(json.dumps({
            "file": os.path.basename(args.bundle), "bytes": tr["total"],
            "magic": tr["magic"], "version": tr["version"],
            "multi": bool(tr["flags"] & sbx.FLAG_MULTI),
            "layered": bool(tr["flags"] & sbx.FLAG_LAYERED),
            "tool": idx.get("tool"), "version_str": idx.get("version"),
            "blobs": len(idx.get("blobs", {})),
            "blob_bytes": sum(v[1] for v in idx.get("blobs", {}).values()),
            "payloads": [{"id": p.get("id"), "os": p.get("os"), "arch": p.get("arch"),
                          "entry": p.get("entry"), "bytes": p.get("bytes"),
                          "files": len(p.get("files", []))} for p in idx["payloads"]],
        }, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
