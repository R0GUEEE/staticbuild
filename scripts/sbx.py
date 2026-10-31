#!/usr/bin/env python3
"""Shared SBX2 container helpers: trailer, zstd, tree walk, pack, extract.

Layout:

    [ carrier stub ][ blob region ][ zstd(index json) ][ 64-byte trailer ]

A blob is a file's bytes, compressed once and referenced by content digest, so
a universal bundle that carries the same headers twice stores them once.

Nothing here executes a bundle: this is the format layer that packing,
verification and CI share on any host.
"""
from __future__ import annotations

import ctypes
import hashlib
import json
import os
import stat
import struct
import subprocess
import tarfile
import tempfile

MAGIC = b"SBX2"
MAGIC_V1 = b"SBX1"
VERSION = 2
TRAILER = struct.Struct("<4sHHQQ32sQ")
TRAILER_SIZE = TRAILER.size

FLAG_LAYERED = 1 << 0
FLAG_SEALED = 1 << 1
FLAG_MULTI = 1 << 2

LAYER_TOKEN = "@@SB_LAYER@@/"


class ZstdError(RuntimeError):
    pass


_lib = None
_missing = object()


def _libzstd():
    global _lib
    if _lib is not None:
        return None if _lib is _missing else _lib
    for name in ("libzstd.so.1", "libzstd.so", "libzstd.1.dylib", "libzstd.dylib",
                 "/opt/homebrew/lib/libzstd.dylib"):
        try:
            lib = ctypes.CDLL(name)
            lib.ZSTD_compressBound.argtypes = [ctypes.c_size_t]
            lib.ZSTD_compressBound.restype = ctypes.c_size_t
            lib.ZSTD_compress.argtypes = [ctypes.c_void_p, ctypes.c_size_t,
                                          ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int]
            lib.ZSTD_compress.restype = ctypes.c_size_t
            lib.ZSTD_decompress.argtypes = [ctypes.c_void_p, ctypes.c_size_t,
                                            ctypes.c_void_p, ctypes.c_size_t]
            lib.ZSTD_decompress.restype = ctypes.c_size_t
            lib.ZSTD_isError.argtypes = [ctypes.c_size_t]
            lib.ZSTD_isError.restype = ctypes.c_uint
            lib.ZSTD_getFrameContentSize.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
            lib.ZSTD_getFrameContentSize.restype = ctypes.c_ulonglong
            lib.ZSTD_getErrorName.argtypes = [ctypes.c_size_t]
            lib.ZSTD_getErrorName.restype = ctypes.c_char_p
            _lib = lib
            return lib
        except OSError:
            continue
    _lib = _missing
    return None


def _err(lib, code):
    return lib.ZSTD_getErrorName(ctypes.c_size_t(code)).decode()


def zcompress(data: bytes, level: int = 19) -> bytes:
    if not data:
        return b""
    lib = _libzstd()
    if lib is not None:
        cap = lib.ZSTD_compressBound(len(data))
        buf = ctypes.create_string_buffer(cap)
        n = lib.ZSTD_compress(buf, cap, data, len(data), level)
        if lib.ZSTD_isError(n):
            raise ZstdError(_err(lib, n))
        return buf.raw[:n]
    try:
        return subprocess.run(["zstd", "-%d" % level, "-q", "-c"], input=data,
                              capture_output=True, check=True).stdout
    except (OSError, subprocess.CalledProcessError) as exc:
        raise ZstdError("no zstd available: %s" % exc) from exc


def zdecompress(data: bytes) -> bytes:
    if not data:
        return b""
    lib = _libzstd()
    if lib is not None:
        size = lib.ZSTD_getFrameContentSize(data, len(data))
        if size < (1 << 60):
            out = ctypes.create_string_buffer(size)
            n = lib.ZSTD_decompress(out, size, data, len(data))
            if lib.ZSTD_isError(n):
                raise ZstdError(_err(lib, n))
            return out.raw[:n]
    try:
        return subprocess.run(["zstd", "-dc", "-q"], input=data,
                              capture_output=True, check=True).stdout
    except (OSError, subprocess.CalledProcessError) as exc:
        raise ZstdError("no zstd available: %s" % exc) from exc


# --------------------------------------------------------------- tree walking

def tree_entries(root: str) -> list:
    """Deterministic listing of a staged tree: dirs, files, symlinks."""
    out, root = [], os.path.abspath(root)
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        dirnames.sort()
        rel_dir = os.path.relpath(dirpath, root)
        if rel_dir != ".":
            out.append({"p": rel_dir.replace(os.sep, "/"), "k": "d", "m": 0o755})
        for name in sorted(filenames):
            full = os.path.join(dirpath, name)
            rel = (rel_dir + "/" + name if rel_dir != "." else name).replace(os.sep, "/")
            st = os.lstat(full)
            if stat.S_ISLNK(st.st_mode):
                out.append({"p": rel, "k": "l", "m": 0o777, "r": os.readlink(full)})
            elif stat.S_ISREG(st.st_mode) and rel.endswith(".sblayer"):
                # A layer tree the build host could not symlink (Windows): the
                # marker carries the hash, the index gets a symlink entry.
                with open(full) as fh:
                    sha = json.load(fh)["layer"]
                out.append({"p": rel[:-len(".sblayer")], "k": "l", "m": 0o777,
                            "r": LAYER_TOKEN + sha})
            elif stat.S_ISREG(st.st_mode):
                with open(full, "rb") as fh:
                    data = fh.read()
                out.append({"p": rel, "k": "f", "m": stat.S_IMODE(st.st_mode),
                            "r": hashlib.sha256(data).hexdigest()[:32], "_data": data})
    out.sort(key=lambda e: e["p"])
    return out


def write_bundle(out: str, stub: bytes, payloads: list, tool: str, version: str,
                 epoch: int = 1700000000, level: int = 19) -> dict:
    """Assemble an SBX2 file. Returns a summary dict."""
    blobs, index_payloads = {}, []
    for p in payloads:
        files, size = [], 0
        for e in tree_entries(p["root"]):
            e = dict(e)
            data = e.pop("_data", None)
            if data is not None:
                blobs.setdefault(e["r"], data)
                size += len(data)
            files.append(e)
        index_payloads.append({
            "id": p["id"], "os": p["os"], "arch": p["arch"],
            "family": p.get("family", "elf"), "tier": p.get("tier", "sfx"),
            "entry": p["entry"], "paths": p.get("paths", ["bin"]),
            "env": p.get("env", {}), "aliases": p.get("aliases", {}),
            "layers": p.get("layers", []), "bytes": size, "files": files,
        })

    flags = FLAG_SEALED
    if any(p.get("layers") for p in index_payloads):
        flags |= FLAG_LAYERED
    if len(index_payloads) > 1:
        flags |= FLAG_MULTI

    table, body, off = {}, [], 0
    for key in sorted(blobs):
        raw = blobs[key]
        packed = zcompress(raw, level) if len(raw) > 64 else raw
        if len(packed) >= len(raw) - 16:
            packed, is_raw = raw, 1
        else:
            is_raw = 0
        table[key] = [off, len(packed), len(raw), is_raw]
        body.append(packed)
        off += len(packed)
    blob_region = b"".join(body)

    index = {"format": "SBX2", "tool": tool, "version": version, "epoch": epoch,
             "blob_base": len(stub), "blobs": table, "payloads": index_payloads}
    packed = zcompress(json.dumps(index, separators=(",", ":"), sort_keys=True).encode(), level)

    with open(out, "wb") as fh:
        fh.write(stub)
        fh.write(blob_region)
        fh.write(packed)
        fh.write(TRAILER.pack(MAGIC, VERSION, flags, len(stub) + len(blob_region),
                              len(packed), hashlib.sha256(packed).digest(), epoch))
    return {"bytes": os.path.getsize(out), "blobs": len(table),
            "blob_bytes": len(blob_region),
            "payloads": [p["id"] for p in index_payloads], "flags": flags}


# ------------------------------------------------------------------- reading

ARCH_ALIASES = {"amd64": "x86_64", "x86_64": "x86_64", "aarch64": "arm64",
                "arm64": "arm64", "arm": "armv7", "armv7": "armv7", "armv7l": "armv7",
                "i386": "386", "i686": "386", "386": "386"}


def norm_arch(a: str) -> str:
    return ARCH_ALIASES.get((a or "").lower(), (a or "").lower())


def read_trailer(path: str) -> dict:
    size = os.path.getsize(path)
    if size < TRAILER_SIZE:
        raise ValueError("%s: smaller than a trailer" % path)
    with open(path, "rb") as fh:
        fh.seek(size - TRAILER_SIZE)
        magic, ver, flags, off, length, digest, epoch = TRAILER.unpack(fh.read())
    if magic not in (MAGIC, MAGIC_V1):
        raise ValueError("%s: bad magic %r (truncated?)" % (path, magic))
    if off + length != size - TRAILER_SIZE:
        raise ValueError("%s: index does not abut the trailer" % path)
    return {"magic": magic.decode(), "version": ver, "flags": flags, "offset": off,
            "size": length, "sha256": digest.hex(), "epoch": epoch, "total": size}


def load(path: str) -> dict:
    tr = read_trailer(path)
    with open(path, "rb") as fh:
        fh.seek(tr["offset"])
        raw = fh.read(tr["size"])
    if tr["version"] == 1:
        tmp = tempfile.mkdtemp(prefix="sbx-")
        tar_path = os.path.join(tmp, "payload.tar.zst")
        with open(tar_path, "wb") as fh:
            fh.write(raw)
        with tarfile.open(tar_path, "r:zst") as tf:
            meta = json.load(tf.extractfile(".sb/meta.json"))
        meta.setdefault("id", "legacy")
        meta.setdefault("os", "unknown")
        meta.setdefault("arch", "unknown")
        return {"trailer": tr, "legacy": tar_path, "path": path,
                "index": {"format": "SBX1", "tool": meta.get("tool"),
                          "version": meta.get("version"), "blobs": {},
                          "payloads": [meta]}}
    return {"trailer": tr, "path": path, "index": json.loads(zdecompress(raw).decode())}


def select(doc: dict, want: str) -> dict:
    ps = doc["index"]["payloads"]
    if not ps:
        raise ValueError("bundle carries no payloads")
    if not want:
        return ps[0]
    for p in ps:
        if want in (p.get("id"), p.get("os"), "%s/%s" % (p.get("os"), p.get("arch")),
                    "%s-%s" % (p.get("os"), p.get("arch"))):
            return p
    raise KeyError("no payload %r; have %s" % (want, ", ".join(p["id"] for p in ps)))


def extract(doc: dict, payload: dict, into: str) -> str:
    """Materialise one payload. Mirrors the stub's --sb-extract-dir."""
    root = os.path.abspath(into)
    os.makedirs(root, exist_ok=True)
    if "legacy" in doc:
        with tarfile.open(doc["legacy"]) as tf:
            tf.extractall(root, filter="tar")
        return root
    idx = doc["index"]
    blobs, base = idx["blobs"], idx["blob_base"]
    with open(doc["path"], "rb") as fh:
        for ent in payload["files"]:
            rel = ent["p"]
            if os.path.isabs(rel) or ".." in rel.split("/"):
                raise ValueError("unsafe path in payload: %r" % rel)
            dst = os.path.join(root, rel.replace("/", os.sep))
            if ent["k"] == "d":
                os.makedirs(dst, exist_ok=True)
                continue
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            if ent["k"] == "l":
                if os.path.lexists(dst):
                    os.unlink(dst)
                os.symlink(ent["r"], dst)
                continue
            off, csize, usize, is_raw = blobs[ent["r"]]
            fh.seek(base + off)
            packed = fh.read(csize)
            data = packed if is_raw else zdecompress(packed)
            if len(data) != usize or hashlib.sha256(data).hexdigest()[:32] != ent["r"]:
                raise ValueError("blob %s (%s) failed its digest" % (ent["r"], rel))
            with open(dst, "wb") as out:
                out.write(data)
            os.chmod(dst, ent.get("m", 0o644) & 0o777)
    return root


def check(path: str) -> list:
    """Structural validation; returns a list of problems (empty is good)."""
    doc = load(path)
    idx, tr, problems = doc["index"], doc["trailer"], []
    ids, blobs = set(), idx.get("blobs", {})
    for p in idx["payloads"]:
        pid = p.get("id", "?")
        if pid in ids:
            problems.append("duplicate payload id %s" % pid)
        ids.add(pid)
        if not p.get("entry"):
            problems.append("%s: no entry" % pid)
        for ent in p.get("files", []):
            if ent["k"] == "f" and ent["r"] not in blobs:
                problems.append("%s: %s references unknown blob" % (pid, ent["p"]))
    if len(ids) > 1 and not tr["flags"] & FLAG_MULTI:
        problems.append("multi-payload bundle without FLAG_MULTI")
    for key, (off, csize, usize, is_raw) in blobs.items():
        if tr["version"] == 2 and idx["blob_base"] + off + csize > tr["offset"]:
            problems.append("blob %s overruns the index" % key)
        if is_raw and csize != usize:
            problems.append("raw blob %s has mismatched sizes" % key)
    return problems
