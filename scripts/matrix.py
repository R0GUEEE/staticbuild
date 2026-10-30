#!/usr/bin/env python3
"""Turn a manifest into a GitHub Actions build matrix.

    matrix.py --target linux-arm64            # -> {"include": [...]}
    matrix.py --target linux-arm64 --ids clang,zig
    matrix.py --list-targets
    matrix.py --check                        # validate manifest + recipes exist

Only entries whose target block is buildable (status != "not-supported") are
emitted. `runs-on` comes from the target table so the workflow needs no logic.
"""
import argparse
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MANIFEST = os.path.join(ROOT, "manifest", "tools.json")

TARGETS = {
    "linux-arm64": {"runs-on": "ubuntu-24.04-arm", "container": "alpine:3.21", "family": "elf"},
    "linux-x86_64": {"runs-on": "ubuntu-24.04", "container": "alpine:3.21", "family": "elf"},
    "ios-arm64": {"runs-on": "macos-14", "container": None, "family": "macho"},
    "ios-arm64-sim": {"runs-on": "macos-14", "container": None, "family": "macho"},
    "macos-arm64": {"runs-on": "macos-14", "container": None, "family": "macho"},
    "macos-x86_64": {"runs-on": "macos-13", "container": None, "family": "macho"},
}


def load():
    with open(MANIFEST) as fh:
        return json.load(fh)


def buildable(tool, target):
    t = tool.get("targets", {}).get(target)
    if not t:
        return False
    return t.get("status", "ga") not in ("not-supported", "planned")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--target")
    ap.add_argument("--ids")
    ap.add_argument("--list-targets", action="store_true")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--pretty", action="store_true")
    args = ap.parse_args()

    if args.list_targets:
        print(json.dumps(TARGETS, indent=2))
        return

    data = load()
    tools = data["tools"]

    if args.check:
        problems = []
        ids = set()
        for t in tools:
            if t["id"] in ids:
                problems.append(f"duplicate id {t['id']}")
            ids.add(t["id"])
            recipe = os.path.join(ROOT, "recipes", t["id"] + ".sh")
            if not os.path.isfile(recipe):
                problems.append(f"{t['id']}: missing recipes/{t['id']}.sh")
            for name, blk in t.get("targets", {}).items():
                if name not in TARGETS:
                    problems.append(f"{t['id']}: unknown target {name}")
                if blk.get("status", "ga") not in ("ga", "experimental", "not-supported", "planned"):
                    problems.append(f"{t['id']}/{name}: bad status {blk['status']}")
                if blk.get("status", "ga") in ("ga", "experimental") and not blk.get("entry"):
                    problems.append(f"{t['id']}/{name}: buildable but no entry")
        for p in problems:
            print("FAIL:", p)
        sys.exit(1 if problems else 0)

    if not args.target:
        ap.error("--target is required unless --check/--list-targets")

    tid = args.target
    if tid not in TARGETS:
        sys.exit(f"unknown target {tid} (known: {', '.join(TARGETS)})")
    only = set(args.ids.split(",")) if args.ids else None

    include = []
    for t in tools:
        if only and t["id"] not in only:
            continue
        if not buildable(t, tid):
            continue
        blk = t["targets"][tid]
        include.append({
            "id": t["id"],
            "target": tid,
            "version": blk.get("version") or t.get("version", ""),
            "tier": blk.get("tier", "sfx"),
            "runs-on": TARGETS[tid]["runs-on"],
            "container": TARGETS[tid]["container"] or "",
            "family": TARGETS[tid]["family"],
            "budget_mb": blk.get("size_budget_mb", 0),
            "smoke": blk.get("smoke", ""),
        })

    out = {"include": include}
    print(json.dumps(out, indent=None if not args.pretty else 2))


if __name__ == "__main__":
    main()
