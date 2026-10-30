#!/usr/bin/env python3
"""Pack a staged tree into a single self-extracting bundle.

    pack.py --stub build/sb-stub --root stage/clang --out dist/clang-20.1.8-linux-arm64 \
            [--level 19] [--flags layered]

Format (little endian):

    [ stub Mach-O/ELF ][ zstd(tar payload) ][ 64-byte trailer ]

Trailer: magic "SBX1", u16 version, u16 flags, u64 payload offset,
u64 payload size, sha256[32] of the compressed payload, u64 epoch.

The tar payload is deterministic: entries sorted, uid/gid 0, uname/gname empty,
mtime pinned to SOURCE_DATE_EPOCH, mode normalised. Two builds of the same tree
with the same epoch produce byte-identical bundles, which is what makes the
sha256 in SHA256SUMS meaningful.
"""
import argparse
import hashlib
import io
import json
import os
import struct
import subprocess
import sys
import tarfile
import tempfile

MAGIC = b"SBX1"
VERSION = 1
FLAG_LAYERED = 1 << 0
FLAG_SEALED = 1 << 1
TRAILER = struct.Struct("<4sHHQQ32sQ")


def epoch() -> int:
    v = os.environ.get("SOURCE_DATE_EPOCH")
    if v and v.isdigit():
        return int(v)
    return 1700000000


def walk(root):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        rel = os.path.relpath(dirpath, root)
        if rel != ".":
            yield dirpath, rel
        for name in sorted(filenames):
            yield os.path.join(dirpath, name), os.path.join(rel, name) if rel != "." else name


def add_entry(tar, full, rel, mtime):
    st = os.lstat(full)
    ti = tarfile.TarInfo(rel.replace(os.sep, "/"))
    ti.uid = ti.gid = 0
    ti.uname = ti.gname = ""
    ti.mtime = mtime
    if os.path.islink(full):
        ti.type = tarfile.SYMTYPE
        ti.linkname = os.readlink(full)
        ti.mode = 0o777
        tar.addfile(ti)
        return
    if os.path.isdir(full):
        ti.type = tarfile.DIRTYPE
        ti.mode = 0o755
        tar.addfile(ti)
        return
    if not os.path.isfile(full):
        return
    ti.type = tarfile.REGTYPE
    ti.mode = 0o755 if st.st_mode & 0o111 else 0o644
    with open(full, "rb") as fh:
        data = fh.read()
    ti.size = len(data)
    tar.addfile(ti, io.BytesIO(data))


def build_tar(root, out_path, mtime):
    with tarfile.open(out_path, "w", format=tarfile.USTAR_FORMAT) as tar:
        for full, rel in walk(root):
            add_entry(tar, full, rel, mtime)


def make_payload(root, workdir, level):
    tar_path = os.path.join(workdir, "payload.tar")
    build_tar(root, tar_path, epoch())
    zst_path = os.path.join(workdir, "payload.tar.zst")
    cmd = ["zstd", "-q", "-f", f"-{level}", "-T0", "--no-progress", tar_path, "-o", zst_path]
    subprocess.run(cmd, check=True)
    return zst_path


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--stub", required=True)
    ap.add_argument("--root", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--level", type=int, default=int(os.environ.get("SB_ZSTD_LEVEL", 19)))
    ap.add_argument("--layered", action="store_true")
    args = ap.parse_args()

    meta_path = os.path.join(args.root, ".sb", "meta.json")
    if not os.path.isfile(meta_path):
        sys.exit(f"pack: {args.root} has no .sb/meta.json (recipe must call sb_meta)")
    meta = json.load(open(meta_path))
    for key in ("tool", "version", "entry"):
        if not meta.get(key):
            sys.exit(f"pack: .sb/meta.json is missing {key}")
    if not os.path.isfile(os.path.join(args.root, meta["entry"])):
        sys.exit(f"pack: entrypoint {meta['entry']} does not exist in {args.root}")

    flags = FLAG_SEALED | (FLAG_LAYERED if args.layered else 0)
    stub_size = os.path.getsize(args.stub)

    with tempfile.TemporaryDirectory() as work:
        payload = make_payload(args.root, work, args.level)
        size = os.path.getsize(payload)
        h = hashlib.sha256()
        os.makedirs(os.path.dirname(os.path.abspath(args.out)) or ".", exist_ok=True)
        tmp_out = args.out + ".tmp"
        with open(tmp_out, "wb") as out, open(args.stub, "rb") as stub, open(payload, "rb") as src:
            out.write(stub.read())
            while True:
                chunk = src.read(1 << 20)
                if not chunk:
                    break
                h.update(chunk)
                out.write(chunk)
            out.write(TRAILER.pack(MAGIC, VERSION, flags, stub_size, size, h.digest(), epoch()))

    os.chmod(tmp_out, 0o755)
    os.replace(tmp_out, args.out)
    total = os.path.getsize(args.out)
    print(f"packed {meta['tool']} {meta['version']} -> {args.out}")
    print(f"  stub   {stub_size:>12,} B")
    print(f"  payload{size:>12,} B  sha256:{h.hexdigest()[:16]}…")
    print(f"  total  {total:>12,} B  ({total / 1048576:.1f} MiB)")


if __name__ == "__main__":
    main()
