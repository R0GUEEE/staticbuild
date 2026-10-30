#!/usr/bin/env python3
"""Report what a binary needs from the system, without running it or using
platform tools. Works on Linux, macOS and Windows hosts alike, which is what
lets a Linux runner verify a windows-arm64 payload.

    checkbin.py dist/ninja-1.12.1-linux-arm64
    checkbin.py --json <file>

Output (json): {"format": "elf"|"pe"|"macho"|"script"|"bundle"|"unknown",
                "arch": "...", "needed": [...], "kind": "exe"|"dll"|"dylib"}
ELF:     DT_NEEDED from .dynamic (empty list == fully static)
PE:      import table DLL names (kernel32.dll/msvcrt.dll are the allowed set)
Mach-O:  LC_LOAD_DYLIB / LC_LOAD_WEAK_DYLIB paths (dyld shared cache only)
"""
from __future__ import annotations

import json
import struct
import sys

SYSTEM_PE = {"kernel32.dll", "msvcrt.dll", "ntdll.dll", "user32.dll", "advapi32.dll",
             "shell32.dll", "ole32.dll", "oleaut32.dll", "ws2_32.dll", "crypt32.dll",
             "bcrypt.dll", "iphlpapi.dll", "userenv.dll", "psapi.dll", "dbghelp.dll",
             "secur32.dll", "version.dll", "winmm.dll", "gdi32.dll", "rpcrt4.dll",
             "shlwapi.dll", "setupapi.dll", "powrprof.dll", "wintrust.dll", "mpr.dll",
             "netapi32.dll", "dnsapi.dll", "imm32.dll", "comctl32.dll", "comdlg32.dll",
             "ucrtbase.dll", "vcruntime140.dll", "msvcp140.dll", "kernelbase.dll",
             "api-ms-win-crt-runtime-l1-1-0.dll"}

MACHO_MAGIC = {0xFEEDFACE: ("<", 32), 0xFEEDFACF: ("<", 64),
               0xCEFAEDFE: (">", 32), 0xCFFAEDFE: (">", 64)}
FAT_MAGIC = (0xCAFEBABE, 0xCAFEBABF)


def elf(data: bytes) -> dict:
    ei_class, ei_data = data[4], data[5]
    endian = "<" if ei_data == 1 else ">"
    is64 = ei_class == 2
    mach = {0x3E: "x86_64", 0xB7: "aarch64", 0x28: "arm", 0x03: "i386",
            0xF3: "riscv64", 0x16: "ppc64le"}.get(struct.unpack_from(endian + "H", data, 18)[0], "?")
    if is64:
        e_shoff, = struct.unpack_from(endian + "Q", data, 0x28)
        e_shentsize, e_shnum, e_shstrndx = struct.unpack_from(endian + "HHH", data, 0x3A)
    else:
        e_shoff, = struct.unpack_from(endian + "I", data, 0x20)
        e_shentsize, e_shnum, e_shstrndx = struct.unpack_from(endian + "HHH", data, 0x2E)
    e_type, = struct.unpack_from(endian + "H", data, 16)
    needed = []
    kind = {1: "reloc", 2: "exe", 3: "shared", 4: "core"}.get(e_type, "exe")
    sh_fmt = endian + ("IIQQQQIIQQ" if is64 else "IIIIIIIIII")
    sections = []
    for i in range(e_shnum):
        off = e_shoff + i * e_shentsize
        if off + struct.calcsize(sh_fmt) > len(data):
            break
        sections.append(struct.unpack_from(sh_fmt, data, off))
    for sh in sections:
        sh_type, sh_offset, sh_size, sh_link = sh[1], sh[4], sh[5], sh[6]
        if sh_type != 6:  # SHT_DYNAMIC
            continue
        if sh_link >= len(sections):
            continue
        str_off = sections[sh_link][4]
        i = 0
        step = 16 if is64 else 8
        dtag = endian + ("qQ" if is64 else "iI")
        while i + step <= sh_size:
            tag, val = struct.unpack_from(dtag, data, sh_offset + i)
            i += step
            if tag == 0:
                break
            if tag == 1:  # DT_NEEDED
                s = data[str_off + val:]
                needed.append(s.split(b"\0", 1)[0].decode("utf-8", "replace"))
    return {"format": "elf", "arch": mach, "needed": needed, "kind": kind}


def pe(data: bytes) -> dict:
    e_lfanew, = struct.unpack_from("<I", data, 0x3C)
    if data[e_lfanew:e_lfanew + 4] != b"PE\0\0":
        return {"format": "pe", "arch": "?", "needed": [], "kind": "exe", "error": "no PE header"}
    coff = e_lfanew + 4
    machine, nsect = struct.unpack_from("<HH", data, coff)
    opt_size, = struct.unpack_from("<H", data, coff + 16)
    opt = coff + 20
    magic, = struct.unpack_from("<H", data, opt)
    pe32plus = magic == 0x20B
    arch = {0x8664: "x86_64", 0xAA64: "arm64", 0x14C: "i386", 0x1C4: "arm"}.get(machine, "?")
    characteristics, = struct.unpack_from("<H", data, coff + 18)
    kind = "dll" if characteristics & 0x2000 else "exe"
    # section table
    sect = opt + opt_size
    sections = []
    for i in range(nsect):
        off = sect + i * 40
        name = data[off:off + 8].rstrip(b"\0").decode("ascii", "replace")
        vsize, vaddr, rawsize, rawptr = struct.unpack_from("<IIII", data, off + 8)
        sections.append((vaddr, max(vsize, rawsize), rawptr, rawsize))

    def rva2off(rva: int):
        for vaddr, size, rawptr, rawsize in sections:
            if vaddr <= rva < vaddr + size:
                return rawptr + (rva - vaddr)
        return None

    dd = opt + (0x70 if pe32plus else 0x60) + 8  # skip debug dir index? import is [1]
    imp_rva, imp_size = struct.unpack_from("<II", data, dd)
    needed = []
    if imp_rva:
        off = rva2off(imp_rva)
        while off and off + 20 <= len(data):
            ilt, ts, fc, name_rva, iat = struct.unpack_from("<IIIII", data, off)
            if name_rva == 0 and iat == 0:
                break
            noff = rva2off(name_rva)
            if noff is None:
                break
            end = data.index(b"\0", noff)
            needed.append(data[noff:end].decode("ascii", "replace"))
            off += 20
    return {"format": "pe", "arch": arch, "needed": needed, "kind": kind,
            "pointer_bits": 64 if pe32plus else 32}


PLATFORMS = {1: "macos", 2: "ios", 3: "tvos", 4: "watchos", 5: "bridgeos",
             6: "maccatalyst", 7: "ios-simulator", 8: "tvos-simulator",
             9: "watchos-simulator", 10: "driverkit"}


def _ver(v: int) -> str:
    return "%d.%d.%d" % ((v >> 16) & 0xFFFF, (v >> 8) & 0xFF, v & 0xFF)


def macho(data: bytes) -> dict:
    magic, = struct.unpack_from(">I", data, 0)
    if magic in FAT_MAGIC:
        nfat, = struct.unpack_from(">I", data, 4)
        slices = []
        start = 8
        for i in range(nfat):
            cputype, cpusub, off, size, align = struct.unpack_from(">iiIII", data, start + i * 20)
            arch = {0x0100000C: "arm64", 0x01000007: "x86_64", 12: "arm", 7: "i386"}.get(cputype, "?")
            slices.append({"arch": arch, "offset": off, "size": size})
        detail = [macho_slice(data[s["offset"]:s["offset"] + s["size"]]) for s in slices]
        needed = sorted({n for d in detail for n in d["needed"]})
        return {"format": "macho", "arch": "universal", "slices": slices,
                "needed": needed, "kind": "exe"}
    return macho_slice(data)


def macho_slice(data: bytes) -> dict:
    magic, = struct.unpack_from("<I", data, 0)
    if magic not in MACHO_MAGIC:
        return {"format": "macho", "arch": "?", "needed": [], "kind": "exe", "error": "bad magic"}
    endian, bits = MACHO_MAGIC[magic]
    cputype, cpusub, filetype, ncmds, sizeofcmds, flags = struct.unpack_from(
        endian + "iiIIII", data, 4)
    arch = {0x0100000C: "arm64", 0x01000007: "x86_64", 12: "arm", 7: "i386"}.get(cputype, "?")
    kind = {2: "exe", 6: "dylib", 8: "bundle", 11: "kext"}.get(filetype, "exe")
    off = 32 if bits == 64 else 28
    needed = []
    plat = None
    minos = None
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from(endian + "II", data, off)
        if cmd in (0xC, 0x18 | 0x80000000, 0x1F | 0x80000000):  # LOAD_DYLIB / WEAK / REEXPORT
            name_off, = struct.unpack_from(endian + "I", data, off + 8)
            start = off + name_off
            end = data.index(b"\0", start)
            needed.append(data[start:end].decode("utf-8", "replace"))
        elif cmd == 0x32:  # LC_BUILD_VERSION
            # platform: 1 macOS, 2 iOS, 3 tvOS, 4 watchOS, 6 Mac Catalyst,
            # 7 iOS simulator, 8 tvOS simulator, 9 watchOS simulator, 10 DriverKit
            p, m, _sdk = struct.unpack_from(endian + "III", data, off + 8)
            plat = PLATFORMS.get(p, "platform-%d" % p)
            minos = _ver(m)
        elif cmd == 0x24:  # LC_VERSION_MIN_MACOSX
            v, = struct.unpack_from(endian + "I", data, off + 8)
            plat, minos = plat or "macos", minos or _ver(v)
        elif cmd == 0x25:  # LC_VERSION_MIN_IPHONEOS
            v, = struct.unpack_from(endian + "I", data, off + 8)
            plat, minos = plat or "ios", minos or _ver(v)
        elif cmd == 0x2F:  # LC_VERSION_MIN_TVOS
            plat = plat or "tvos"
        elif cmd == 0x30:  # LC_VERSION_MIN_WATCHOS
            plat = plat or "watchos"
        off += cmdsize
        if off > len(data):
            break
    return {"format": "macho", "arch": arch, "needed": needed, "kind": kind,
            "bits": bits, "platform": plat, "minos": minos}


def inspect(path: str) -> dict:
    with open(path, "rb") as fh:
        head = fh.read(64)
        if len(head) < 4:
            return {"format": "unknown", "needed": []}
        size = len(fh.read())
        fh.seek(0)
        data = fh.read()
    if head[:4] == b"\x7fELF":
        return elf(data)
    if head[:2] == b"MZ":
        return pe(data)
    if head[:4] in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xce",
                    b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"):
        return macho(data)
    if head[:2] == b"#!":
        return {"format": "script", "needed": [], "kind": "script",
                "interpreter": head[2:].split(b"\n")[0].decode("utf-8", "replace").strip()}
    return {"format": "unknown", "needed": [], "bytes": size}


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    as_json = "--json" in sys.argv[1:]
    if not args:
        print(__doc__)
        return 2
    out = inspect(args[0])
    if as_json:
        print(json.dumps(out))
    else:
        print("%s: %s %s" % (args[0], out["format"], out.get("arch", "")))
        print("  needs: %s" % (", ".join(out["needed"]) or "nothing (static)"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
