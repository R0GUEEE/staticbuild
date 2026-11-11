#!/usr/bin/env python3
"""Turn the manifest into a GitHub Actions matrix — no workflow-side logic.

    matrix.py --list-targets
    matrix.py --target linux-arm64                 # buildable cells, as include[]
    matrix.py --target windows-arm64 --ids go,zig
    matrix.py --targets ios-arm64,ios-arm64-sim     # a subset of targets
    matrix.py --compose                            # one entry per universal target
    matrix.py --check                              # manifest + recipes consistency

Everything that varies per cell (runner, container, toolchain flags) comes from
the manifest target table, so adding an architecture is one edit in
tools/gen_manifest.py and no change to the workflow.
"""
from __future__ import annotations

import argparse
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MANIFEST = os.path.join(ROOT, "manifest", "tools.json")
BUILDABLE = ("ga", "experimental")


def load():
    with open(MANIFEST) as fh:
        return json.load(fh)


def cell_include(tool, target, spec, block):
    inc = {
        "tool": tool["id"],
        "target": target,
        "version": block.get("version") or tool["version"],
        "tier": block.get("tier", "sfx"),
        "status": block.get("status", "ga"),
        "entry": block.get("entry", ""),
        "runs_on": spec.get("runs_on", "ubuntu-24.04"),
        "container": spec.get("container") or "",
        "os": spec.get("os"),
        "arch": spec.get("arch"),
        "family": spec.get("family"),
        "goos": spec.get("goos"),
        "goarch": spec.get("goarch"),
        "smoke": block.get("smoke", ""),
        "budget": block.get("size_budget_mb", 0),
        "recipe": "recipes/%s.sh" % tool["id"],
        "name": "%s-%s" % (tool["id"], target),
    }
    if block.get("image"):
        inc["image"] = block["image"]
    return inc


def buildable(doc, target, ids, statuses=BUILDABLE):
    spec = doc["targets"].get(target)
    if spec is None:
        sys.exit("matrix: unknown target %r (see --list-targets)" % target)
    out = []
    for tool in doc["tools"]:
        if ids and tool["id"] not in ids:
            continue
        block = tool.get("targets", {}).get(target)
        if not block or block.get("status", "ga") not in statuses:
            continue
        out.append(cell_include(tool, target, spec, block))
    return out


def compose_entries(doc, ids, statuses=BUILDABLE):
    out = []
    for name, spec in doc["targets"].items():
        if not spec.get("fat"):
            continue
        tools = []
        for tool in doc["tools"]:
            if ids and tool["id"] not in ids:
                continue
            block = tool.get("targets", {}).get(name) or {}
            if block.get("status", "ga") not in statuses:
                continue
            tools.append(tool["id"])
        if tools:
            out.append({"target": name, "slices": spec["fat"], "tools": ",".join(tools),
                        "runs_on": spec.get("runs_on", "macos-14")})
    return out


def check(doc):
    problems, ids = [], set()
    for tool in doc["tools"]:
        tid = tool["id"]
        if tid in ids:
            problems.append("duplicate tool id %s" % tid)
        ids.add(tid)
        recipe = os.path.join(ROOT, "recipes", tid + ".sh")
        if not os.path.isfile(recipe):
            problems.append("%s: missing recipes/%s.sh" % (tid, tid))
        for target, block in tool.get("targets", {}).items():
            if target not in doc["targets"]:
                problems.append("%s/%s: unknown target" % (tid, target))
                continue
            status = block.get("status", "ga")
            if status not in ("ga", "experimental", "planned", "not-supported"):
                problems.append("%s/%s: bad status %s" % (tid, target, status))
            if status in BUILDABLE and not block.get("entry"):
                problems.append("%s/%s: buildable without an entry" % (tid, target))
            if status == "not-supported" and not block.get("notes"):
                problems.append("%s/%s: not-supported without a reason" % (tid, target))
            if block.get("image") and doc["targets"][target].get("container"):
                continue
            if block.get("image") and not doc["targets"][target].get("container"):
                problems.append("%s/%s: image override on a non-container target" % (tid, target))
    for p in problems:
        print("FAIL:", p)
    n = sum(1 for t in doc["tools"] for b in t["targets"].values()
            if b.get("status") in BUILDABLE)
    print("matrix: %d tools, %d targets, %d buildable cells" %
          (len(doc["tools"]), len(doc["targets"]), n))
    return 1 if problems else 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--target")
    ap.add_argument("--targets", help="comma-separated subset of targets (--all minus the rest)")
    ap.add_argument("--ids")
    ap.add_argument("--list-targets", action="store_true")
    ap.add_argument("--compose", action="store_true")
    ap.add_argument("--all", action="store_true", help="every buildable cell, universal excluded")
    ap.add_argument("--status", default="ga",
                    help="comma-separated statuses to emit (default ga; use ga,experimental)")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--pretty", action="store_true")
    args = ap.parse_args()
    doc = load()
    ids = set(x.strip() for x in (args.ids or "").split(",") if x.strip())
    statuses = tuple(x.strip() for x in args.status.split(",") if x.strip())

    if args.check:
        return check(doc)
    if args.list_targets:
        for name, spec in doc["targets"].items():
            n = sum(1 for t in doc["tools"]
                    if t.get("targets", {}).get(name, {}).get("status") in BUILDABLE)
            print("%-18s %-8s %-8s %-20s %2d tools  %s" %
                  (name, spec.get("os"), spec.get("arch"), spec.get("runs_on", ""), n,
                   spec.get("abi", "")))
        return 0
    if args.all:
        # --targets narrows --all. Iterating one column (ios-arm64) instead of
        # all fifteen is the difference between a 12-job run and a 200-job run
        # when the thing being debugged only exists on one platform.
        only = [t.strip() for t in (args.targets or "").split(",") if t.strip()]
        unknown = [t for t in only if t not in doc["targets"]]
        if unknown:
            sys.exit("matrix: unknown target(s): %s" % ", ".join(unknown))
        inc = []
        for name in doc["targets"]:
            if doc["targets"][name].get("fat"):
                continue
            if only and name not in only:
                continue
            inc.extend(buildable(doc, name, ids, statuses))
        print(json.dumps({"include": inc}))
        return 0
    if args.compose:
        print(json.dumps({"include": compose_entries(doc, ids, statuses)}))
        return 0
    if not args.target:
        ap.error("--target is required (or --list-targets / --compose / --check)")
    inc = buildable(doc, args.target, ids, statuses)
    print(json.dumps({"include": inc}, indent=2 if args.pretty else None))
    return 0


if __name__ == "__main__":
    sys.exit(main())
