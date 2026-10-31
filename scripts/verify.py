#!/usr/bin/env python3
"""Verify what a bundle claims: format, tier, budget, and that it runs.

    verify.py dist/ninja-1.12.1-linux-arm64 [more...]
    verify.py --all
    verify.py --tier-only dist/...        # skip smoke on a foreign host

Every payload in a bundle is checked, so a macos-universal file is held to both
slices and a Windows file to both PE trees even when this runs on Linux.
"""
from __future__ import annotations

import json
import os
import platform
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import checkbin  # noqa: E402
import sbx       # noqa: E402

SYSTEM_MACHO = ("/usr/lib/", "/System/Library/", "@rpath/libswift")
BUILD_PATHS = (b"/home/runner", b"/Users/runner", b"/nix/store")
SYS_ELF = {"libc.so.6", "libm.so.6", "libdl.so.2", "libpthread.so.0", "librt.so.1",
           "libutil.so.1", "libresolv.so.2", "libgcc_s.so.1", "libstdc++.so.6"}


def colour():
    if sys.stdout.isatty() and not os.environ.get("NO_COLOR"):
        return "\033[1m", "\033[32m", "\033[31m", "\033[33m", "\033[0m"
    return "", "", "", "", ""


BOLD, GREEN, RED, YELLOW, RESET = colour()


class Report:
    def __init__(self):
        self.failed = False

    def ok(self, t):
        print("  %sok%s   %s" % (GREEN, RESET, t))

    def bad(self, t):
        self.failed = True
        print("  %sFAIL%s %s" % (RED, RESET, t))

    def warn(self, t):
        print("  %swarn%s %s" % (YELLOW, RESET, t))


def host_like(spec):
    osname = {"darwin": "macos", "linux": "linux", "windows": "windows",
              "ios": "ios"}.get(platform.system().lower(), platform.system().lower())
    return (osname == spec.get("os")
            and sbx.norm_arch(platform.machine()) == sbx.norm_arch(spec.get("arch")))


def non_system(needed, family):
    out = []
    for lib in needed:
        if family == "pe":
            # api-ms-win-* / ext-ms-win-* are API sets resolved by the OS to
            # KernelBase and the Universal CRT; they are not redistributables.
            if (lib.lower() in checkbin.SYSTEM_PE
                    or low.startswith(("api-ms-win-", "ext-ms-win-"))):
                continue
        elif family == "macho":
            if any(lib.startswith(p) for p in SYSTEM_MACHO):
                continue
        else:
            if lib in SYS_ELF or lib.startswith("ld-linux") or lib.startswith("libc.so"):
                continue
        out.append(lib)
    return out


def tree_has(tree, lib):
    base = os.path.basename(lib)
    for _, _, files in os.walk(tree):
        if base in files:
            return True
    return False


def scan_paths(binary, rep):
    try:
        with open(binary, "rb") as fh:
            data = fh.read(64 << 20)
    except OSError:
        return
    hits = [p.decode() for p in BUILD_PATHS if p in data]
    if hits:
        rep.warn("build paths baked into the entry: %s" % ", ".join(hits))
    else:
        rep.ok("no build-machine paths in the entry")


def run_smoke(exe, cmd, rep):
    tmp = tempfile.mkdtemp(prefix="sb-smoke-")
    try:
        for name in {os.path.basename(exe), "tool"}:
            try:
                os.symlink(exe, os.path.join(tmp, name))
            except OSError:
                pass
        env = dict(os.environ)
        env["PATH"] = tmp + os.pathsep + os.path.dirname(exe) + os.pathsep + env.get("PATH", "")
        env.setdefault("SB_CACHE", os.path.join(tmp, "cache"))
        env.pop("SB_PAYLOAD", None)
        p = subprocess.run(cmd, shell=True, cwd=tmp, env=env, timeout=1800,
                           capture_output=True, text=True)
        if p.returncode == 0:
            rep.ok("smoke: %s" % cmd)
        else:
            tail = (p.stderr or p.stdout).strip().splitlines()[-3:]
            rep.bad("smoke failed (%d): %s | %s" % (p.returncode, cmd, " ".join(tail)))
    except subprocess.TimeoutExpired:
        rep.bad("smoke timed out: %s" % cmd)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def check_entry(rep, spec, tree, entry, tier, do_smoke, smoke_cmd):
    family = spec.get("family", "elf")
    info = checkbin.inspect(entry)
    got = info.get("format")
    expect = {"elf": ("elf", "script"), "pe": ("pe",), "macho": ("macho",)}.get(family, ())
    if expect and got not in expect:
        rep.bad("%s/%s: entry is %s, expected %s" % (spec.get("os"), spec.get("arch"),
                                                     got, family))
        return
    rep.ok("%s/%s -> %s %s" % (spec.get("os"), spec.get("arch"), got, info.get("arch", "")))
    missing = non_system(info.get("needed", []), family)
    if tier in ("static", "macho"):
        if missing:
            rep.bad("tier=%s but imports %s" % (tier, ", ".join(missing[:6])))
        else:
            rep.ok("tier=%s: zero non-system imports" % tier)
    else:
        absent = [m for m in missing if not tree_has(tree, m)]
        if absent:
            rep.bad("tier=%s imports %s, not carried by the payload" %
                    (tier, ", ".join(absent[:6])))
        else:
            rep.ok("tier=%s: %d imports, all inside the payload" % (tier, len(missing)))
    scan_paths(entry, rep)
    if do_smoke and smoke_cmd:
        run_smoke(entry, smoke_cmd, rep)


def locate(manifest, base):
    tool_id = base.split("-")[0]
    tool = next((t for t in manifest["tools"] if t["id"] == tool_id), None)
    block, spec = {}, {}
    if tool:
        for name in sorted(tool["targets"], key=len, reverse=True):
            if base.endswith("-" + name) or ("-" + name + ".") in base:
                block = tool["targets"][name]
                spec = dict(manifest["targets"][name])
                break
    return tool, block, spec


def verify_one(path, manifest, tier_only):
    rep = Report()
    base = os.path.basename(path)
    print("\n%s%s%s" % (BOLD, path, RESET))
    if not os.path.isfile(path):
        rep.bad("no such file")
        return rep
    if base.endswith((".sha256", ".json", ".md")):
        rep.ok("not an artefact (checksum/manifest), skipped")
        return rep
    size_mb = os.path.getsize(path) / (1024 * 1024)
    tool, block, spec = locate(manifest, base)
    try:
        doc = sbx.load(path)
    except ValueError:
        info = checkbin.inspect(path)
        if not spec:
            spec = {"family": info.get("format"), "os": "?", "arch": "?"}
        spec = dict(spec)
        spec["family"] = info.get("format")
        rep.ok("bare %s %s, %.1f MiB" % (info.get("format"), info.get("arch", ""), size_mb))
        tier = block.get("tier", "static")
        missing = non_system(info.get("needed", []), spec["family"])
        if tier in ("static", "macho") and missing:
            rep.bad("tier=%s imports %s" % (tier, ", ".join(missing[:6])))
        else:
            rep.ok("tier=%s: %d non-system imports" % (tier, len(missing)))
        if not os.access(path, os.X_OK):
            rep.bad("not executable")
        if host_like(spec) and block.get("smoke") and not tier_only:
            run_smoke(path, block["smoke"], rep)
        return rep

    tr = doc["trailer"]
    payloads = doc["index"]["payloads"]
    rep.ok("%s v%d, %d payload(s), %.1f MiB" %
           (tr["magic"], tr["version"], len(payloads), size_mb))
    problems = sbx.check(path)
    if problems:
        rep.bad("container: %s" % "; ".join(problems[:3]))
    else:
        rep.ok("container structure")

    budget = 0
    for p in payloads:
        tspec = manifest["targets"].get(p["id"], {})
        tblock = (tool or {}).get("targets", {}).get(p["id"], {})
        budget = max(budget, tblock.get("size_budget_mb") or 0)
        tmp = tempfile.mkdtemp(prefix="sb-verify-")
        try:
            tree = sbx.extract(doc, p, os.path.join(tmp, "t"))
            entry = os.path.join(tree, p["entry"])
            if not os.path.exists(entry) and os.path.exists(entry + ".exe"):
                entry += ".exe"
            if not os.path.exists(entry):
                rep.bad("%s: entry %s missing" % (p["id"], p["entry"]))
                continue
            check_entry(rep, tspec, tree, entry,
                        tblock.get("tier", p.get("tier", "sfx")),
                        do_smoke=host_like(tspec) and not tier_only,
                        smoke_cmd=tblock.get("smoke", ""))
        except (ValueError, OSError, sbx.ZstdError) as exc:
            rep.bad("%s: %s" % (p["id"], exc))
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    if budget and size_mb > budget * 1.02:
        rep.bad("size %.1f MiB over the %d MiB budget" % (size_mb, budget))
    elif budget:
        rep.ok("size %.1f MiB within the %d MiB budget" % (size_mb, budget))
    return rep


def main():
    argv = sys.argv[1:]
    tier_only = "--tier-only" in argv
    args = [a for a in argv if not a.startswith("--")]
    if "--all" in argv:
        dist = os.environ.get("DIST", os.path.join(ROOT, "dist"))
        args = [os.path.join(dist, f) for f in sorted(os.listdir(dist))
                if not f.endswith((".sha256", "SHA256SUMS"))]
    if not args:
        print(__doc__)
        return 2
    with open(os.path.join(ROOT, "manifest", "tools.json")) as fh:
        manifest = json.load(fh)
    failed = sum(1 for p in args if verify_one(p, manifest, tier_only).failed)
    print("\n%d artifact(s), %d failing" % (len(args), failed))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
