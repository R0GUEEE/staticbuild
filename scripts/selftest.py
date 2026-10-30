#!/usr/bin/env python3
"""Self-test for the binary readers in checkbin.py.

These readers decide what ships: a wrong parse makes a dynamically linked tool
look static, or an iOS artifact look like a macOS one. They are hand-written
struct code, so they get fixtures rather than trust.

    python3 scripts/selftest.py

Fixtures are synthesised in memory and written to a temp dir; nothing here needs
a compiler, a Mac, or a network.
"""
from __future__ import annotations

import os
import struct
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import checkbin  # noqa: E402

FAIL = 0


def check(cond, what):
    global FAIL
    if cond:
        print("  ok   %s" % what)
    else:
        FAIL += 1
        print("  FAIL %s" % what)


def ver(major, minor, patch=0):
    return (major << 16) | (minor << 8) | patch


def macho_exe(platform=None, minos=(15, 0), dylibs=(), fat=False):
    """A minimal 64-bit little-endian Mach-O with an optional LC_BUILD_VERSION."""
    cmds = b""
    ncmds = 0
    for path in dylibs:
        name = path.encode() + b"\0"
        pad = (8 - len(name) % 8) % 8
        name += b"\0" * pad
        cmdsize = 24 + len(name)
        cmds += struct.pack("<IIIIII", 0xC, cmdsize, 24, 0, 0, 0) + name
        ncmds += 1
    if platform is not None:
        cmds += struct.pack("<IIIIII", 0x32, 24, platform,
                            ver(*minos), ver(18, 0), 0)
        ncmds += 1
    body = struct.pack("<IiiIIIII", 0xFEEDFACF, 0x0100000C, 0, 2,
                       ncmds, len(cmds), 0, 0) + cmds
    if not fat:
        return body
    # fat header with one arm64 slice; offsets are file-absolute, so the slice
    # starts right after the 8-byte header plus one 20-byte fat_arch.
    off = 4096
    head = struct.pack(">II", 0xCAFEBABE, 1) + struct.pack(">iiIII", 0x0100000C, 0, off, len(body), 12)
    return head + b"\0" * (off - len(head)) + body


def elf_exe(needed=(), etype=2):
    """A 64-bit LE ELF with a .dynamic section naming DT_NEEDED strings."""
    strtab = b"\0"
    offsets = {}
    for n in needed:
        offsets[n] = len(strtab)
        strtab += n.encode() + b"\0"
    dyn = b"".join(struct.pack("<qQ", 1, offsets[n]) for n in needed)
    dyn += struct.pack("<qQ", 0, 0)

    ehsize, shentsize, shnum = 64, 64, 3
    dyn_off = ehsize
    str_off = dyn_off + len(dyn)
    data = bytearray()
    data += struct.pack("<4sBBBBB7x", b"\x7fELF", 2, 1, 1, 0, 0)
    data += struct.pack("<HHIQQQIHHHHHH", etype, 0xB7, 1, 0, 0, 0, 0, ehsize, 0, 0,
                        shentsize, shnum, 1)
    data += dyn
    data += strtab
    shoff = len(data)
    data += b"\0" * (shentsize * shnum)
    sh = [None] * shnum
    sh[1] = struct.pack("<IIQQQQIIQQ", 0, 6, 0, 0, dyn_off, len(dyn), 2, 0, 8, 16)   # .dynamic
    sh[2] = struct.pack("<IIQQQQIIQQ", 0, 3, 0, 0, str_off, len(strtab), 0, 0, 1, 0)  # .dynstr
    for i in (1, 2):
        data[shoff + i * shentsize: shoff + (i + 1) * shentsize] = sh[i]
    struct.pack_into("<Q", data, 0x28, shoff)
    struct.pack_into("<H", data, 0x3C, shnum)
    return bytes(data)


def main():
    tmp = tempfile.mkdtemp(prefix="sb-selftest-")

    def write(name, blob):
        p = os.path.join(tmp, name)
        with open(p, "wb") as fh:
            fh.write(blob)
        return checkbin.inspect(p)

    print("mach-o platform")
    ios = write("ios", macho_exe(platform=2, minos=(15, 0)))
    check(ios["format"] == "macho", "format macho")
    check(ios["platform"] == "ios", "LC_BUILD_VERSION platform 2 -> ios")
    check(ios["minos"] == "15.0.0", "minos decoded (%s)" % ios["minos"])
    check(ios["arch"] == "arm64", "arch arm64")
    check(ios["needed"] == [], "no dylibs -> empty needed")

    mac = write("mac", macho_exe(platform=1, minos=(11, 0)))
    check(mac["platform"] == "macos", "platform 1 -> macos")
    check(mac["platform"] != ios["platform"], "ios and macos are distinguishable")

    sim = write("sim", macho_exe(platform=7))
    check(sim["platform"] == "ios-simulator", "platform 7 -> ios-simulator")

    old = write("old", macho_exe(platform=None))
    check(old["platform"] is None, "no build version -> platform unknown, not guessed")

    legacy = struct.pack("<IiiIIIII", 0xFEEDFACF, 0x0100000C, 0, 2, 1, 16, 0, 0) + \
        struct.pack("<IIII", 0x25, 16, ver(12, 0), ver(14, 0))
    check(write("legacy", legacy)["platform"] == "ios", "LC_VERSION_MIN_IPHONEOS -> ios")

    print("mach-o imports")
    dy = write("dylibs", macho_exe(platform=2, dylibs=("/usr/lib/libSystem.B.dylib",
                                                     "/usr/lib/libc++.1.dylib")))
    check(len(dy["needed"]) == 2, "two dylibs parsed")
    check("/usr/lib/libSystem.B.dylib" in dy["needed"], "dylib path decoded")

    print("fat mach-o")
    fat = write("fat", macho_exe(platform=2, fat=True))
    check(fat["arch"] == "universal", "fat -> universal")
    check(len(fat["slices"]) == 1, "one slice")
    check(len(fat["needed"]) == 0, "universal merged needed list")

    print("elf")
    static = write("static", elf_exe(needed=()))
    check(static["format"] == "elf", "format elf")
    check(static["needed"] == [], "no DT_NEEDED -> static")
    dyn = write("dyn", elf_exe(needed=("libc.so.6", "libm.so.6")))
    check(sorted(dyn["needed"]) == ["libc.so.6", "libm.so.6"],
          "DT_NEEDED parsed (%s)" % dyn["needed"])
    check(write("dynlib", elf_exe(etype=3))["kind"] == "shared", "ET_DYN -> shared")

    print("\n%d failure(s)" % FAIL)
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
