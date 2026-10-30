# Architecture

## The problem this solves

Integrating a toolchain into an iOS app normally means one of three things, all bad:

1. ship a `.dylib` collection and fix `DYLD_LIBRARY_PATH` — iOS will not load it,
   and it bloats the app bundle;
2. reuse the host's `/usr/lib` — a sandboxed app does not have one;
3. vendor a build system's worth of `install` commands into every downstream project.

This repository produces a fourth thing: **one file per tool**, either a bare
executable that imports nothing but what the OS already ships, or a self-extracting
bundle whose payload is the tool's tree, unpacked on first run into a content-addressed
cache.

## Two families of artifact

The meaning of "static" depends on the platform, and blurring that is how these
projects ship broken binaries.

| Family | Targets | Definition of self-contained |
|---|---|---|
| ELF | `linux-arm64`, `linux-x86_64` | `readelf -d` prints **no** `DT_NEEDED`. Not one. `ldd` says "not a dynamic executable". Works in a bare initramfs, in the iSH/linuxkit guest, in a proot rootfs. |
| Mach-O | `ios-arm64`, `macos-arm64` | `otool -L` lists only `/usr/lib/*`, `/System/Library/*` and `@rpath/libswift*`. Those live in the dyld shared cache, so nothing is embedded in the app bundle. |

On Darwin you cannot statically link libSystem — Apple ships no `libSystem.a`. A
"fully static iOS binary" is therefore a category error; the useful, achievable
property is *zero non-system imports*, which is what `scripts/verify.sh` enforces
per target.

## Bundle format

```
+--------------+----------------+---------------------+--------------+---------+
| carrier      | blob region    | zstd(index json)    | payload tree | trailer |
| ELF/PE/Mach-O| unique file    | one entry per       | materialised | 64 B    |
| (the stub)   | contents       | os/arch, with       | at run time  |         |
|              |                | digests + offsets   |              |         |
+--------------+----------------+---------------------+--------------+---------+
```

Trailer, little endian, fixed size so it can be read with one `pread`:

| offset | size | field |
|---|---|---|
| 0 | 4 | magic `SBX2` |
| 4 | 2 | version (2; version 1 bundles still run) |
| 6 | 2 | flags: bit0 layered, bit1 sealed, bit2 multi-payload |
| 8 | 8 | index offset |
| 16 | 8 | index length |
| 24 | 32 | SHA-256 of the compressed index |
| 56 | 8 | `SOURCE_DATE_EPOCH` of the build |

The index is JSON, zstd-compressed, key-sorted:

```json
{
  "format": "SBX2", "tool": "clang", "version": "20.1.8",
  "blob_base": 2425092,
  "blobs": { "<sha256[:32]>": [offset, compressed_size, size, raw_flag] },
  "payloads": [{
    "id": "windows-arm64", "os": "windows", "arch": "arm64",
    "family": "pe", "tier": "sfx", "entry": "bin/clang.exe",
    "paths": ["bin"], "env": {...}, "aliases": {...}, "layers": ["<sha>"],
    "files": [{"p": "bin/clang.exe", "k": "f", "m": 493, "r": "<sha>"},
              {"p": "lib", "k": "d", "m": 493},
              {"p": "bin/clang++", "k": "l", "r": "clang"}]
  }]
}
```

Three properties fall out of that shape:

* **one file can carry several payloads.** The stub picks by `(os, arch)` of the
  host it is running on, which is what makes `macos-universal` and
  `windows-universal` real rather than a naming convention.
* **content is stored once.** Blobs are keyed by content digest and emitted in
  digest order, so two payloads that share a header tree, a JRE or a stdlib
  store it a single time.
* **determinism is structural.** Entries are sorted, modes normalised, mtime
  pinned to `SOURCE_DATE_EPOCH`, index serialised with sorted keys. Same inputs,
  same bytes, same sha256.

At run time the stub validates the trailer, checks the index digest, extracts
the matching payload into `$XDG_CACHE_HOME/staticbuild/b/<payload>-<index12>`
(atomic rename; a second process that loses the race reuses the winner's tree),
lifts `layers/<sha>` into `staticbuild/l/<sha>` and rewrites `@@SB_LAYER@@`
symlinks to absolute paths, then `execve`s the entry with a cleaned environment:

* `LD_PRELOAD`, `LD_LIBRARY_PATH`, `PYTHONHOME`, `PYTHONPATH`, `JAVA_HOME`,
  `NODE_OPTIONS`, `CLASSPATH`, `PERL5LIB` are dropped — a bundle must not inherit
  the host's idea of where its runtime lives;
* `PATH` gets the payload's `bin` directories first;
* `env` values are expanded with `${ROOT}`, `${LAYERS}` and `${CACHE}`, so
  `GOROOT`, `JAVA_HOME`, `PYTHONHOME` and `THEOS` all point inside the bundle;
* on Windows, where there is no `execve`, the stub spawns the entry with
  inherited handles and forwards the exit code.

Introspection never extracts anything: `--sb-print-index`, `--sb-payloads`,
`--sb-print-meta`, `--sb-list`, `--sb-version`, `--sb-cache`. `--sb-extract-dir
DIR` materialises the tree and stops, which is how the compose job repacks a
universal file without a second build, and how `scripts/compose.py` recovers a
tree from an artifact.

### Layers

A layer is a directory that two or more tools need verbatim — the JRE shared by
`java` and `kotlin`, the stdlib shared by `python` and `meson`, the LLVM resource
directory shared by `clang` and `clangd`.

The recipe stages the directory, calls `sb_layer <rel>`, and the build computes a
content hash over its files, moves the tree to `layers/<sha>/`, and replaces the
original path with a symlink whose target starts with `@@SB_LAYER@@/`. At first
run the stub lifts each layer into `$CACHE/l/<sha>` under a lock and rewrites the
symlink to an absolute path. Two bundles carrying the same layer store its bytes
once on disk; the download cost is paid twice, the disk cost once.

Layer granularity is deliberately *directory-level*. Per-file hard-linking would
deduplicate more and cost a `stat` storm on every extract; the two big wins (JRE,
LLVM/Python stdlib) are whole directories anyway.

### Determinism

`pack.py` writes the tar itself: entries sorted, `uid/gid 0`, empty `uname/gname`,
`mtime = SOURCE_DATE_EPOCH`, mode normalised to 755/644. `zstd -19 -T0` is
single-threaded deterministic at a fixed level. Building the same tree twice on
the same architecture produces byte-identical bundles, so a checksum in
`SHA256SUMS` is a meaningful monotonic artefact rather than a build timestamp.

## Why a stub at all

Alternatives considered, and why they lost:

| Approach | Why not |
|---|---|
| Bare binary always | Impossible for anything with a resource directory (clang's builtin headers, Python's stdlib, the JRE). |
| `apk`/`deb` package | Needs a package manager on the device; iOS has none. |
| Docker/OCI image | Needs a runtime; the whole point is zero dependencies. |
| `busybox`-style applet multiplexing | Only works when every tool is the same binary. |
| Tar + `--to-stdout` shell wrapper | Needs a shell, `tar` and `zstd` before anything runs. |

A 2.4 MB Go stub is the smallest thing that can read its own tail, decompress
zstd, and `execve` without a shell. It also gives every bundle the same
introspection flags (`--sb-version`, `--sb-print-meta`, `--sb-extract-dir`,
`--sb-clean`), which is what makes them debuggable in the field.

## Size accounting

The point is *total* cost to a downstream project, not per-file size:

* `clang` — 220 MiB budget. A stock LLVM install with all backends is ~1.6 GiB;
  four backends, no dylib, no docs, no examples land near 200 MiB compressed.
* `java` + `kotlin` — two files, but the JRE layer is stored once (~90 MiB
  compressed) instead of twice.
* `python` + `meson` — same trick with the stdlib.
* Everything classified `static` is 4–20 MiB and needs no extraction at all.

`verify.sh` fails a build that exceeds the manifest's `size_budget_mb`, so sizes
are a contract, not a surprise.
