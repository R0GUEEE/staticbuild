#!/usr/bin/env python3
"""Report what a binary needs from the system, without running it and without
platform tools — so a Linux runner can hold a windows-arm64 payload to account.

    checkbin.py --json dist/ninja-1.12.1-linux-arm64
    checkbin.py dist/...

ELF:     DT_NEEDED (empty list == fully static)
PE:      import-table DLL names (kernel32/msvcrt and the api-ms-win-* API
         sets are the allowed system set)
Mach-O:  LC_LOAD_DYLIB paths (dyld shared cache only)
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
             "ucrtbase.dll", "vcruntime140.dll", "msvcp140.dll", "kernelbase.dll"}

MACHO_MAGIC = {0xFEEDFACE: ("<", 32), 0xFEEDFACF: ("<", 64),
               0xCEFAEDFE: (">", 32), 0xCFFAEDFE: (">", 64)}
FAT_MAGIC = (0xCAFEBABE, 0xCAFEBABF)
CPU = {0x0100000C: "arm64", 0x01000007: "x86_64", 12: "arm", 7: "i386"}


def elf(data: bytes) -> dict:
    endian = "<" if data[5] == 1 else ">"
    is64 = data[4] == 2
    machine = struct.unpack_from(endian + "H", data, 18)[0]
    arch = {0x3E: "x86_64", 0xB7: "aarch64", 0x28: "arm", 0x03: "i386",
            0xF3: "riscv64"}.get(machine, "?")
    e_type = struct.unpack_from(endian + "H", data, 16)[0]
    kind = {1: "reloc", 2: "exe", 3: "shared", 4: "core"}.get(e_type, "exe")
    if is64:
        shoff, = struct.unpack_from(endian + "Q", data, 0x28)
        shentsize, shnum, _ = struct.unpack_from(endian + "HHH", data, 0x3A)
    else:
        shoff, = struct.unpack_from(endian + "I", data, 0x20)
        shentsize, shnum, _ = struct.unpack_from(endian + "HHH", data, 0x2E)
    fmt = endian + ("IIQQQQIIQQ" if is64 else "IIIIIIIIII")
    sections = []
    for i in range(shnum):
        off = shoff + i * shentsize
        if off + struct.calcsize(fmt) > len(data):
            break
        sections.append(struct.unpack_from(fmt, data, off))
    needed = []
    for sh in sections:
        if sh[1] != 6:  # SHT_DYNAMIC
            continue
        if sh[6] >= len(sections):
            continue
        str_off = sections[sh[6]][4]
        step = 16 if is64 else 8
        dtag = endian + ("qQ" if is64 else "iI")
        i = 0
        while i + step <= sh[5]:
            tag, val = struct.unpack_from(dtag, data, sh[4] + i)
            i += step
            if tag == 0:
                break
            if tag == 1:
                s = data[str_off + val:]
                needed.append(s.split(b"\0", 1)[0].decode("utf-8", "replace"))
    return {"format": "elf", "arch": arch, "needed": needed, "kind": kind}


def pe(data: bytes) -> dict:
    e_lfanew, = struct.unpack_from("<I", data, 0x3C)
    if data[e_lfanew:e_lfanew + 4] != b"PE\0\0":
        return {"format": "pe", "arch": "?", "needed": [], "kind": "exe"}
    coff = e_lfanew + 4
    machine, nsect = struct.unpack_from("<HH", data, coff)
    opt_size, = struct.unpack_from("<H", data, coff + 16)
    characteristics, = struct.unpack_from("<H", data, coff + 18)
    opt = coff + 20
    magic, = struct.unpack_from("<H", data, opt)
    pe32plus = magic == 0x20B
    arch = {0x8664: "x86_64", 0xAA64: "arm64", 0x14C: "i386", 0x1C4: "arm"}.get(machine, "?")
    kind = "dll" if characteristics & 0x2000 else "exe"
    sect = opt + opt_size
    sections = []
    for i in range(nsect):
        off = sect + i * 40
        vsize, vaddr, rawsize, rawptr = struct.unpack_from("<IIII", data, off + 8)
        sections.append((vaddr, max(vsize, rawsize), rawptr))

    def rva2off(rva):
        for vaddr, size, rawptr in sections:
            if vaddr <= rva < vaddr + size:
                return rawptr + (rva - vaddr)
        return None

    # Data directory 1 is the import table; index 0 is the export table.
    dd = opt + (0x70 if pe32plus else 0x60) + 8
    imp_rva, imp_size = struct.unpack_from("<II", data, dd)
    needed, off = [], rva2off(imp_rva) if imp_rva else None
    while off and off + 20 <= len(data):
        ilt, ts, fc, name_rva, iat = struct.unpack_from("<IIIII", data, off)
        if name_rva == 0 and iat == 0:
            break
        noff = rva2off(name_rva)
        if noff is None or noff >= len(data):
            break
        end = data.index(b"\0", noff)
        needed.append(data[noff:end].decode("ascii", "replace"))
        off += 20
    return {"format": "pe", "arch": arch, "needed": needed, "kind": kind,
            "pointer_bits": 64 if pe32plus else 32}


def macho_slice(data: bytes) -> dict:
    magic, = struct.unpack_from("<I", data, 0)
    if magic not in MACHO_MAGIC:
        return {"format": "macho", "arch": "?", "needed": [], "kind": "exe"}
    endian, bits = MACHO_MAGIC[magic]
    cputype, cpusub, filetype, ncmds, sizeofcmds, flags = struct.unpack_from(
        endian + "iiIIII", data, 4)
    arch = CPU.get(cputype, "?")
    kind = {2: "exe", 6: "dylib", 8: "bundle", 11: "kext"}.get(filetype, "exe")
    off = 32 if bits == 64 else 28
    needed = []
    for _ in range(ncmds):
        if off + 8 > len(data):
            break
        cmd, cmdsize = struct.unpack_from(endian + "II", data, off)
        if cmd in (0xC, 0x18 | 0x80000000, 0x1F | 0x80000000):
            name_off, = struct.unpack_from(endian + "I", data, off + 8)
            start = off + name_off
            end = data.index(b"\0", start)
            needed.append(data[start:end].decode("utf-8", "replace"))
        if cmdsize == 0:
            break
        off += cmdsize
    return {"format": "macho", "arch": arch, "needed": needed, "kind": kind, "bits": bits}


def macho(data: bytes) -> dict:
    magic, = struct.unpack_from(">I", data, 0)
    if magic in FAT_MAGIC:
        nfat, = struct.unpack_from(">I", data, 4)
        slices, detail = [], []
        for i in range(nfat):
            cputype, cpusub, off, size, align = struct.unpack_from(">iiIII", data, 8 + i * 20)
            slices.append({"arch": CPU.get(cputype, "?"), "offset": off, "size": size})
            detail.append(macho_slice(data[off:off + size]))
        return {"format": "macho", "arch": "universal", "slices": slices,
                "needed": sorted({n for d in detail for n in d["needed"]}), "kind": "exe"}
    return macho_slice(data)


def inspect(path: str) -> dict:
    with open(path, "rb") as fh:
        data = fh.read()
    head = data[:4]
    if head == b"\x7fELF":
        return elf(data)
    if data[:2] == b"MZ":
        return pe(data)
    if head in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xce",
                b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"):
        return macho(data)
    if data[:2] == b"#!":
        return {"format": "script", "needed": [], "kind": "script",
                "interpreter": data[2:].split(b"\n")[0].decode("utf-8", "replace").strip()}
    return {"format": "unknown", "needed": [], "bytes": len(data)}


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if not args:
        print(__doc__)
        return 2
    out = inspect(args[0])
    if "--json" in sys.argv[1:]:
        print(json.dumps(out))
    else:
        print("%s: %s %s" % (args[0], out["format"], out.get("arch", "")))
        print("  needs: %s" % (", ".join(out["needed"]) or "nothing (static)"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
