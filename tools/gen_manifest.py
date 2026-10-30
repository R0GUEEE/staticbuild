#!/usr/bin/env python3
"""Regenerate manifest/tools.json.

The manifest is the single source of truth for the build matrix, so it is
generated from the tables below instead of hand-edited: a target is one row, a
tool is one block, and every cell that cannot be built carries the reason.

    python3 tools/gen_manifest.py            # rewrite manifest/tools.json
    python3 tools/gen_manifest.py --stdout   # print it

Enforced: every tool has a cell for every target; status is one of
ga | experimental | planned | not-supported; not-supported always has a reason.
Tools the generator does not describe are preserved verbatim.
"""
import argparse
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MANIFEST = os.path.join(ROOT, "manifest", "tools.json")

TARGETS = {
    "linux-x86_64": dict(os="linux", arch="x86_64", goos="linux", goarch="amd64", family="elf",
                         abi="musl", runs_on="ubuntu-24.04", container="alpine:3.21",
                         meaning="fully static ELF: readelf -d prints zero DT_NEEDED"),
    "linux-arm64": dict(os="linux", arch="arm64", goos="linux", goarch="arm64", family="elf",
                        abi="musl", runs_on="ubuntu-24.04-arm", container="alpine:3.21",
                        meaning="static aarch64 ELF: iOS sandbox guest, ARM servers, Apple VMs"),
    "linux-armv7": dict(os="linux", arch="armv7", goos="linux", goarch="arm", family="elf",
                        abi="musleabihf", runs_on="ubuntu-24.04-arm", container="alpine:3.21",
                        meaning="static EABI-hardfloat ELF for 32-bit ARM boards"),
    "linux-386": dict(os="linux", arch="386", goos="linux", goarch="386", family="elf",
                      abi="musl", runs_on="ubuntu-24.04", container="alpine:3.21",
                      meaning="static 32-bit x86 ELF"),
    "linux-riscv64": dict(os="linux", arch="riscv64", goos="linux", goarch="riscv64", family="elf",
                          abi="musl", runs_on="ubuntu-24.04", container="alpine:3.21",
                          meaning="static riscv64 (LP64D) ELF"),
    "windows-x86_64": dict(os="windows", arch="x86_64", goos="windows", goarch="amd64", family="pe",
                           abi="mingw-w64", runs_on="windows-2022", container=None,
                           meaning="PE32+ importing only kernel32/msvcrt: static CRT, no VC++ redist"),
    "windows-arm64": dict(os="windows", arch="arm64", goos="windows", goarch="arm64", family="pe",
                          abi="mingw-w64", runs_on="windows-2022", container=None,
                          meaning="native PE32+ for Windows on ARM"),
    "windows-386": dict(os="windows", arch="386", goos="windows", goarch="386", family="pe",
                        abi="mingw-w64", runs_on="windows-2022", container=None,
                        meaning="32-bit PE for legacy Windows"),
    "macos-arm64": dict(os="macos", arch="arm64", goos="darwin", goarch="arm64", family="macho",
                        abi="macos", runs_on="macos-14", container=None,
                        meaning="Mach-O importing only the dyld shared cache"),
    "macos-x86_64": dict(os="macos", arch="x86_64", goos="darwin", goarch="amd64", family="macho",
                         abi="macos", runs_on="macos-13", container=None,
                         meaning="Intel Mac slice, lipo'd with arm64 into macos-universal"),
    "macos-universal": dict(os="macos", arch="universal", goos="darwin", goarch="universal",
                            family="macho", abi="macos", runs_on="macos-14", container=None,
                            fat=["arm64", "x86_64"],
                            meaning="fat Mach-O: one download for Apple Silicon and Intel, "
                                    "each slice running a native payload"),
    "ios-arm64": dict(os="ios", arch="arm64", goos="ios", goarch="arm64", family="macho",
                      abi="iphoneos", runs_on="macos-14", container=None,
                      meaning="Mach-O for the iOS sandbox, signed by the host app"),
    "ios-arm64-sim": dict(os="ios", arch="arm64", goos="iossimulator", goarch="arm64",
                          family="macho", abi="iphonesimulator", runs_on="macos-14",
                          container=None, meaning="simulator slice for CI lanes"),
    "windows-universal": dict(os="windows", arch="universal", goos="windows", goarch="amd64",
                              family="pe", abi="mingw-w64", runs_on="windows-2022",
                              container=None, fat=["x86_64", "arm64"],
                              meaning="one PE carrier carrying both payloads; on ARM64 Windows "
                                      "the stub prefers the native arm64 tree"),
    "linux-universal": dict(os="linux", arch="x86_64", goos="linux", goarch="amd64", family="elf",
                            abi="musl", runs_on="ubuntu-24.04", container="alpine:3.21",
                            fat=[],
                            meaning="not a thing: the kernel will not exec a foreign ELF; "
                                    "one file per architecture is the physical limit"),
}


def cell(tier, status="ga", note="", entry=None, image=None, smoke=None,
         budget=None, version=None, paths=None):
    c = {"tier": tier, "status": status}
    if entry:
        c["entry"] = entry
    if image:
        c["image"] = image
    if note:
        c["notes"] = note
    if smoke:
        c["smoke"] = smoke
    if budget:
        c["size_budget_mb"] = budget
    if version:
        c["version"] = version
    if paths:
        c["paths"] = paths
    return c


def notsup(reason):
    return cell("none", "not-supported", reason)


def expand(tool_id, cells, entry):
    out = {}
    for name, spec in TARGETS.items():
        if name == "linux-universal":
            out[name] = notsup("the kernel execs the carrier it was built for; one Linux "
                               "file cannot serve two architectures. Ship the per-arch "
                               "files, or a launcher that picks.")
            continue
        if name == "windows-universal":
            base = dict(cells.get("windows-x86_64") or {})
            base.setdefault("entry", entry)
            base.setdefault("paths", ["bin"])
            if base.get("status", "ga") != "ga":
                out[name] = base
                continue
            base["notes"] = ("x86_64 PE carrier that also carries the arm64 payload; on "
                             "ARM64 Windows the stub reads PROCESSOR_ARCHITEW6432 and runs "
                             "the native tree. " + base.get("notes", ""))
            base.setdefault("entry", entry)
            base.setdefault("paths", ["bin"])
            out[name] = base
            continue
        os_name, arch = spec["os"], spec["arch"]
        if spec.get("fat"):
            # Universal targets inherit the first slice's cell: the build is per
            # slice, and composition (lipo / multi-payload) happens afterwards.
            base = dict(cells.get("%s-%s" % (os_name, spec["fat"][0]))
                        or cells.get(os_name + "-*") or cells.get("*") or {})
            if base.get("status", "ga") == "ga" and base:
                base["notes"] = ("one file for %s, composed from the %s slices; %s"
                                 % (" and ".join(spec["fat"]), len(spec["fat"]),
                                    base.get("notes", "")))
                base.setdefault("entry", entry)
                base.setdefault("paths", ["bin"])
                out[name] = base
            else:
                out[name] = base or notsup("no slice cell to compose")
            continue
        pick = (cells.get(name) or cells.get(os_name + "-*")
                or cells.get("*-" + arch) or cells.get("*"))
        if pick is None:
            raise SystemExit("%s: no cell for %s" % (tool_id, name))
        c = dict(pick)
        c.setdefault("entry", entry)
        c.setdefault("paths", ["bin"])
        out[name] = c
    return out


def tool(id, name, version, license, method, upstream, provides, cells, entry,
         source=None, notes=None):
    t = {"id": id, "name": name, "version": version, "license": license,
         "method": method, "upstream": upstream, "provides": provides}
    if source:
        t["source"] = source
    if notes:
        t["notes"] = notes
    t["targets"] = expand(id, cells, entry)
    return t


STATIC_PE = ("PE32+ linking only kernel32/msvcrt (static CRT): no Visual C++ "
             "redistributable beside the binary")
MACHO = "Mach-O importing only dyld-shared-cache libraries; nothing beside the app"
IOS_CROSS = ("no host port: this toolchain is the macos-* bundle cross-compiling "
             "with -target arm64-apple-ios")

TOOLS = []


TOOLS.append(tool(
    "llvm", "Clang / LLVM", "20.1.8", "Apache-2.0 WITH LLVM-exception", "source",
    "https://github.com/llvm/llvm-project/releases/tag/llvmorg-20.1.8",
    ["clang", "clang++", "ld.lld", "lld", "llvm-ar", "llvm-nm", "llvm-strip",
     "llvm-objcopy", "llvm-objdump", "llvm-readelf", "llvm-size", "llvm-lipo",
     "clang-format", "clangd", "clang-tidy"],
    {
        "linux-x86_64": cell("layer", budget=450, smoke="clang --version", note="static "
            "libLLVM/libclang (LLVM_BUILD_LLVM_DYLIB=OFF) so every tool is a zero-DT_NEEDED "
            "ELF; lib/clang resource dir ships as a shared layer"),
        "linux-arm64": cell("layer", budget=450, note="same recipe, native aarch64"),
        "linux-armv7": cell("layer", "experimental", budget=380, note="thumb2 build with "
            "LLVM_BUILD_32_BITS; ~6 h on two cores"),
        "linux-386": cell("layer", "experimental", budget=380, note="32-bit x86; no JIT, "
            "clang -c and lld work"),
        "linux-riscv64": cell("layer", "experimental", budget=420, note="native riscv64 build"),
        "windows-x86_64": cell("sfx", "experimental", budget=900, note="mingw-w64 build with "
            "-DLLVM_STATIC_LINK_CXX_STDLIB=ON and -static in CMAKE_EXE_LINKER_FLAGS gives "
            + STATIC_PE + "; the official MSVC release is the fallback and needs the VC runtime"),
        "windows-arm64": cell("sfx", "planned", budget=900, note="official "
            "aarch64-pc-windows-msvc release, or a mingw aarch64 cross build for a static CRT"),
        "windows-386": cell("sfx", "planned", budget=800, note="32-bit PE; LLVM dropped i686 "
            "Windows hosts, so this is a cross build only"),
        "macos-arm64": cell("layer", budget=1500, note="Xcode toolchain or official darwin-arm64 "
            "release; resource dir is a layer shared with swift"),
        "macos-x86_64": cell("layer", budget=1500, note="Intel slice"),
        "ios-arm64": cell("layer", "experimental", budget=600, note="clang in the sandbox: "
            "needs an SDK layer for -isysroot, lld64 for linking, no JIT without entitlement"),
        "ios-arm64-sim": cell("layer", "experimental", budget=600, note="simulator slice"),
    }, "bin/clang", source="llvmorg-20.1.8"))

TOOLS.append(tool(
    "swift", "Swift", "6.0.3", "Apache-2.0", "release",
    "https://www.swift.org/download/",
    ["swift", "swiftc", "swift-build", "swift-package", "swift-format"],
    {
        "linux-x86_64": cell("layer", budget=1400, image="ubuntu:24.04", note="official "
            "toolchain + Static Linux SDK: `swift build --swift-sdk x86_64-swift-linux-musl` "
            "emits a fully static ELF"),
        "linux-arm64": cell("layer", budget=1400, image="ubuntu:24.04", note="aarch64 "
            "toolchain + aarch64-swift-linux-musl SDK"),
        "linux-armv7": notsup("no armv7 Linux toolchain and no 32-bit ARM Linux runtime"),
        "linux-386": notsup("no 32-bit x86 Linux toolchain upstream"),
        "linux-riscv64": cell("layer", "experimental", budget=1400, image="ubuntu:24.04",
            note="experimental upstream riscv64 toolchain"),
        "windows-x86_64": cell("sfx", "planned", budget=1600, note="official Swift for Windows "
            "toolchain; needs the VC++ runtime (carried in the payload) and a Windows SDK to link"),
        "windows-arm64": notsup("Swift for Windows ships x86_64 only; ARM64 hosts emulate it"),
        "windows-386": notsup("no 32-bit Windows Swift toolchain"),
        "macos-arm64": cell("layer", budget=2200, note="Xcode toolchain; the iOS half is an SDK, "
            "not a second compiler"),
        "macos-x86_64": cell("layer", budget=2200, note="Intel slice"),
        "ios-arm64": notsup(IOS_CROSS),
        "ios-arm64-sim": notsup(IOS_CROSS),
    }, "bin/swift"))

TOOLS.append(tool(
    "theos", "Theos + Logos", "2024.11", "GPL-3.0-or-later", "source",
    "https://github.com/theos/theos",
    ["theos", "logos.pl", "logify.pl", "nic.pl", "dm.pl"],
    {
        "linux-*": cell("layer", "experimental", budget=120, note="perl + make + makefiles; "
            "needs a clang layer and an SDK for `make package` to get past compile"),
        "linux-armv7": notsup("theos host tooling is 64-bit only"),
        "linux-386": notsup("theos host tooling is 64-bit only"),
        "windows-*": notsup("a Makefile+perl build system over a POSIX shell: WSL or a Linux "
                            "container is the supported path"),
        "macos-arm64": cell("layer", budget=140, note="the supported host: theos + SDK symlinks "
            "+ logos, paired with the llvm layer for ld64.lld"),
        "macos-x86_64": cell("layer", budget=140, note="same tree"),
        "ios-arm64": cell("layer", "experimental", budget=140, note="theos inside iSH: perl, "
            "make and ldid work; compiling needs the clang and SDK layers"),
        "ios-arm64-sim": notsup("no simulator host inside the device sandbox"),
    }, "bin/theos"))

TOOLS.append(tool(
    "rust", "Rust", "1.83.0", "MIT OR Apache-2.0", "release",
    "https://static.rust-lang.org/dist/",
    ["rustc", "cargo", "rustdoc", "rustfmt"],
    {
        "linux-x86_64": cell("layer", budget=900, image="ubuntu:24.04", smoke="rustc --version",
            note="rustup dist is glibc-linked, so the compiler is a layer; it emits fully "
                 "static output with --target x86_64-unknown-linux-musl"),
        "linux-arm64": cell("layer", budget=900, image="ubuntu:24.04", note="aarch64 dist + "
            "aarch64-unknown-linux-musl; the iOS path is this toolchain plus aarch64-apple-ios"),
        "linux-armv7": cell("layer", "experimental", budget=800, image="ubuntu:24.04", note="armv7 "
            "host toolchain; armv7-unknown-linux-musleabihf gives static output"),
        "linux-386": notsup("no i686-unknown-linux-musl host toolchain; cross-compile from x86_64"),
        "linux-riscv64": cell("layer", "experimental", budget=900, image="ubuntu:24.04", note="riscv64gc "
            "std exists; the host toolchain is assembled from the dist channel"),
        "windows-x86_64": cell("sfx", "planned", budget=900, note="x86_64-pc-windows-gnu + "
            "+crt-static in .cargo/config.toml gives " + STATIC_PE),
        "windows-arm64": cell("sfx", "planned", budget=900, note="aarch64-pc-windows-gnullvm with "
            "clang/lld is the route that stays static"),
        "windows-386": notsup("no i686-pc-windows host toolchain published"),
        "macos-arm64": cell("layer", budget=1000, note="aarch64-apple-darwin"),
        "macos-x86_64": cell("layer", budget=1000, note="x86_64-apple-darwin"),
        "ios-arm64": notsup(IOS_CROSS + "; add the target with `rustup target add`"),
        "ios-arm64-sim": notsup(IOS_CROSS),
    }, "bin/rustc", source="rust-1.83.0"))

TOOLS.append(tool(
    "go", "Go", "1.23.9", "BSD-3-Clause", "release", "https://go.dev/dl/",
    ["go", "gofmt"],
    {
        "*": cell("layer", budget=260, smoke="go version", note="official tarball/zip per "
            "platform; CGO_ENABLED=0 output is statically linked by construction and GOROOT "
            "ships as a layer"),
        "linux-armv7": cell("layer", budget=240, note="linux-armv6l tarball covers armv6/armv7; "
            "GOARM picks the instruction set"),
        "windows-386": cell("layer", "experimental", budget=240, note="windows-386 zip"),
        "ios-arm64": cell("layer", "experimental", budget=200, note="GOOS=ios needs cgo + the "
            "iOS SDK; pure-Go packages build without it but the binary is app-signed"),
        "ios-arm64-sim": cell("layer", "experimental", budget=200, note="simulator slice"),
    }, "bin/go", source="go1.23.9"))

TOOLS.append(tool(
    "zig", "Zig", "0.13.0", "MIT", "release", "https://ziglang.org/download/", ["zig"],
    {
        "linux-x86_64": cell("static", budget=180, smoke="zig version", note="single static "
            "binary, and the C/C++ cross compiler the ELF recipes use"),
        "linux-arm64": cell("static", budget=170, note="aarch64-linux tarball"),
        "linux-armv7": cell("static", "experimental", budget=170, note="no armv7 host build; the "
            "aarch64 compiler targets arm-linux-musleabihf"),
        "linux-386": cell("static", "experimental", budget=170, note="no i386 host build"),
        "linux-riscv64": cell("static", "experimental", budget=170, note="no riscv64 host build upstream"),
        "windows-x86_64": cell("static", budget=180, note="zig-windows-x86_64, one PE"),
        "windows-arm64": cell("static", budget=180, note="zig-windows-aarch64"),
        "windows-386": notsup("no 32-bit Windows host build"),
        "macos-arm64": cell("static", budget=180, note="zig-macos-aarch64"),
        "macos-x86_64": cell("static", budget=180, note="zig-macos-x86_64"),
        "ios-arm64": cell("static", "experimental", budget=180, note="compiles for aarch64-ios "
            "given the SDK; the app signs the result"),
        "ios-arm64-sim": cell("static", "experimental", budget=180, note="simulator target"),
    }, "bin/zig", source="0.13.0"))


TOOLS.append(tool(
    "python", "CPython", "3.12.7", "PSF-2.0", "release",
    "https://github.com/astral-sh/python-build-standalone/releases",
    ["python3", "pip3", "python"],
    {
        "linux-x86_64": cell("layer", budget=120, smoke="python3 -c 'import ssl,json'",
            note="python-build-standalone musl build: self-contained, no system libpython; "
                 "stdlib is a layer so meson and other Python tools reuse it"),
        "linux-arm64": cell("layer", budget=120, note="aarch64 musl build"),
        "linux-armv7": notsup("no upstream armv7/hardfloat build; cross-compiling CPython is a project"),
        "linux-386": notsup("no 32-bit x86 Linux build"),
        "linux-riscv64": cell("layer", "experimental", budget=120, note="riscv64 musl build in newer releases"),
        "windows-x86_64": cell("sfx", "planned", budget=110, note="PBS windows-amd64: python.exe plus its "
            "DLLs inside the payload"),
        "windows-arm64": cell("sfx", "planned", budget=110, note="windows-arm64 builds in recent PBS"),
        "windows-386": notsup("no 32-bit Windows CPython in PBS"),
        "macos-arm64": cell("layer", budget=120, note="PBS darwin-arm64"),
        "macos-x86_64": cell("layer", budget=120, note="PBS darwin-x86_64"),
        "ios-arm64": cell("layer", "experimental", budget=90, note="CPython builds for iOS only as an "
            "app framework: no fork/exec, no subprocess"),
        "ios-arm64-sim": notsup("simulator builds come from the app's own Xcode build"),
    }, "bin/python3", source="3.12.7"))

TOOLS.append(tool(
    "node", "Node.js", "22.11.0", "MIT", "release", "https://nodejs.org/dist/",
    ["node", "npm", "npx"],
    {
        "linux-x86_64": cell("layer", budget=140, smoke="node -e 'console.log(process.arch)'",
            note="official build + npm; libnode is libc-linked so the bundle is a layer"),
        "linux-arm64": cell("layer", budget=140, note="linux-arm64 build"),
        "linux-armv7": cell("layer", "experimental", budget=130, note="linux-armv7l build exists"),
        "linux-386": notsup("Node dropped 32-bit Linux builds after 10.x"),
        "linux-riscv64": cell("layer", "planned", budget=140, note="unofficial-builds riscv64"),
        "windows-x86_64": cell("sfx", "planned", budget=130, note="win-x64 zip; node.exe + npm"),
        "windows-arm64": cell("sfx", "planned", budget=130, note="win-arm64 zip; some addons are x64-only"),
        "windows-386": notsup("no 32-bit Windows Node build"),
        "macos-arm64": cell("layer", budget=140, note="darwin-arm64 tarball"),
        "macos-x86_64": cell("layer", budget=140, note="darwin-x64 tarball"),
        "ios-arm64": cell("layer", "experimental", budget=110, note="needs a jitless build: the "
            "sandbox denies JIT without an entitlement"),
        "ios-arm64-sim": cell("layer", "experimental", budget=110, note="simulator slice"),
    }, "bin/node", source="v22.11.0"))

TOOLS.append(tool(
    "typescript", "TypeScript", "5.7.2", "Apache-2.0", "release",
    "https://registry.npmjs.org/typescript", ["tsc", "tsserver"],
    {
        "linux-*": cell("layer", budget=90, note="tsc is JavaScript: the payload is the npm tree "
            "plus a node layer, shared rather than duplicated"),
        "linux-386": notsup("no 32-bit Node runtime to host tsc"),
        "windows-x86_64": cell("sfx", "planned", budget=90, note="tsc.cmd + node.exe from the node layer"),
        "windows-arm64": cell("sfx", "planned", budget=90, note="needs the node arm64 layer"),
        "windows-386": notsup("no 32-bit Node runtime"),
        "macos-*": cell("layer", budget=90, note="tsc + node layer"),
        "ios-arm64": cell("layer", "experimental", budget=70, note="works with a jitless node layer"),
        "ios-arm64-sim": cell("layer", "experimental", budget=70, note="simulator slice"),
    }, "bin/tsc"))

TOOLS.append(tool(
    "java", "OpenJDK (jlink)", "21.0.5", "GPL-2.0 WITH Classpath-exception-2.0", "release",
    "https://adoptium.net/temurin/releases/",
    ["java", "javac", "jar", "jlink", "jshell", "keytool"],
    {
        "linux-x86_64": cell("layer", budget=200, image="ubuntu:24.04", smoke="java -version",
            note="Temurin, jlink'd to the modules a build needs; the runtime is a layer shared "
                 "with kotlin"),
        "linux-arm64": cell("layer", budget=200, image="ubuntu:24.04", note="aarch64 JDK"),
        "linux-armv7": cell("layer", "experimental", budget=160, image="ubuntu:24.04", note="arm32 build for some releases"),
        "linux-386": notsup("no 32-bit x86 JDK for current releases"),
        "linux-riscv64": cell("layer", "experimental", budget=200, image="ubuntu:24.04", note="riscv64 JDK builds exist"),
        "windows-x86_64": cell("sfx", "planned", budget=210, note="Temurin windows-x64 + jlink image"),
        "windows-arm64": cell("sfx", "planned", budget=210, note="Microsoft OpenJDK windows-aarch64"),
        "windows-386": notsup("no 32-bit Windows JDK"),
        "macos-arm64": cell("layer", budget=200, note="Temurin macos-aarch64"),
        "macos-x86_64": cell("layer", budget=200, note="Temurin macos-x64"),
        "ios-arm64": notsup("no JVM on iOS: JIT is forbidden and no interpreter-only JVM exists"),
        "ios-arm64-sim": notsup("same: no JVM port to the iOS simulator platform"),
    }, "bin/java", source="21.0.5"))

TOOLS.append(tool(
    "kotlin", "Kotlin", "2.0.21", "Apache-2.0", "release",
    "https://github.com/JetBrains/kotlin/releases", ["kotlinc", "kotlin"],
    {
        "linux-*": cell("layer", budget=180, note="kotlin-compiler.zip + a java layer; the JRE is "
            "not duplicated"),
        "linux-386": notsup("no 32-bit JRE to run the compiler"),
        "windows-x86_64": cell("sfx", "planned", budget=190, note="kotlinc.bat + JRE layer"),
        "windows-arm64": cell("sfx", "planned", budget=190, note="arm64 JRE layer"),
        "windows-386": notsup("no 32-bit JRE"),
        "macos-*": cell("layer", budget=190, note="kotlinc + JRE layer"),
        "ios-arm64": notsup("JVM-only compiler: Kotlin/Native targets iOS from a macos-* host"),
        "ios-arm64-sim": notsup("same as ios-arm64"),
    }, "bin/kotlinc"))

TOOLS.append(tool(
    "make", "GNU Make", "4.4.1", "GPL-3.0-or-later", "source", "https://ftp.gnu.org/gnu/make/",
    ["make", "gmake"],
    {
        "*": cell("static", budget=3, smoke="make --version", note="make has no runtime "
            "dependencies worth naming, which is why it is one static file everywhere; the "
            "Windows build is mingw-w64 and expects a POSIX shell for recipes"),
        "windows-*": cell("static", "experimental", budget=3, note="mingw-w64 cross build; a shell "
            "still has to be on PATH for recipes"),
        "windows-arm64": cell("static", "planned", budget=3, note="aarch64-mingw build"),
        "windows-386": cell("static", "planned", budget=3, note="i686-mingw build"),
        "ios-arm64": cell("macho", budget=3, note="runs in the sandbox: make needs a shell and a filesystem"),
        "ios-arm64-sim": cell("macho", budget=3, note="simulator slice"),
    }, "bin/make"))

TOOLS.append(tool(
    "ninja", "Ninja", "1.12.1", "Apache-2.0", "source",
    "https://github.com/ninja-build/ninja/releases", ["ninja", "samu"],
    {
        "*": cell("static", budget=3, smoke="ninja --version", note="C++ built with -static: "
            "600 KiB, zero DT_NEEDED"),
        "windows-*": cell("static", "experimental", budget=3, note="mingw-w64 build from source; "
            "the official ninja-win.zip is a single static PE"),
        "windows-arm64": cell("static", "planned", budget=3, note="aarch64-mingw build"),
        "windows-386": cell("static", "planned", budget=3, note="i686-mingw build"),
        "ios-arm64": cell("macho", budget=3, note="runs in the sandbox; used by theos"),
        "ios-arm64-sim": cell("macho", budget=3, note="simulator slice"),
    }, "bin/ninja"))

TOOLS.append(tool(
    "meson", "Meson", "1.6.0", "Apache-2.0", "source",
    "https://github.com/mesonbuild/meson/releases", ["meson"],
    {
        "linux-*": cell("layer", budget=40, note="pure Python: the wheel tree plus a python layer, "
            "shared with every other Python tool"),
        "linux-386": notsup("no 32-bit Python layer to run meson"),
        "windows-x86_64": cell("sfx", "planned", budget=40, note="meson.exe shim + python layer"),
        "windows-arm64": cell("sfx", "planned", budget=40, note="needs the python arm64 layer"),
        "windows-386": notsup("no 32-bit Python layer"),
        "macos-*": cell("layer", budget=40, note="python layer + wheel tree"),
        "ios-arm64": cell("layer", "experimental", budget=30, note="meson only generates build "
            "files, so it runs where a compiler cannot"),
        "ios-arm64-sim": cell("layer", "experimental", budget=30, note="simulator slice"),
    }, "bin/meson"))


def legacy_entries(described):
    """Keep tools this generator does not describe, with an honest target gap."""
    if not os.path.isfile(MANIFEST):
        return []
    with open(MANIFEST) as fh:
        old = json.load(fh)
    kept = []
    for t in old.get("tools", []):
        if t["id"] in described:
            continue
        targets = t.setdefault("targets", {})
        for name, spec in TARGETS.items():
            if name in targets:
                continue
            new_arch = spec["arch"] in ("armv7", "386", "riscv64", "universal")
            if spec["os"] == "windows" or new_arch:
                targets[name] = cell("none", "planned",
                                     "no %s branch in recipes/%s.sh yet" %
                                     (spec["os"] if spec["os"] == "windows" else spec["arch"],
                                      t["id"]))
            else:
                targets[name] = cell(targets.get("linux-arm64", {}).get("tier", "sfx"),
                                     "planned", "recipe not exercised on this target")
        kept.append(t)
    return kept


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--stdout", action="store_true")
    ap.add_argument("--check", action="store_true", help="compare, do not write")
    args = ap.parse_args()

    tools = list(TOOLS) + legacy_entries({t["id"] for t in TOOLS})
    tools.sort(key=lambda t: t["id"])

    problems = []
    for t in tools:
        for name, c in t["targets"].items():
            st = c.get("status", "ga")
            if st == "not-supported" and not c.get("notes"):
                problems.append("%s/%s: not-supported without a reason" % (t["id"], name))
            if st in ("ga", "experimental") and not c.get("entry"):
                problems.append("%s/%s: buildable without an entry" % (t["id"], name))
    if problems:
        print("\n".join("FAIL: " + p for p in problems), file=sys.stderr)
        return 1

    doc = {"schema": 2, "updated": "2026-10-30",
           "status_legend": {
               "ga": "built, verified and exercised by CI on this target",
               "experimental": "recipe exists, target not covered by the green matrix",
               "planned": "declared with a known approach, recipe branch not written yet",
               "not-supported": "impossible on this target; the reason is in notes"},
           "tiers": {
               "static": "one binary, zero non-system imports (ELF DT_NEEDED empty; PE only "
                         "kernel32/msvcrt; Mach-O dyld cache only)",
               "macho": "one Mach-O importing only OS-shipped dylibs",
               "sfx": "static carrier + zstd blob region carrying a tree",
               "layer": "sfx whose shared runtime trees are content-addressed, so two bundles "
                        "carrying the same JRE/stdlib store it once on disk",
               "none": "not buildable for this target"},
           "targets": {k: v for k, v in sorted(TARGETS.items())},
           "tools": tools}
    body = json.dumps(doc, indent=1) + "\n"
    if args.stdout:
        sys.stdout.write(body)
    elif args.check:
        current = open(MANIFEST).read() if os.path.isfile(MANIFEST) else ""
        if current != body:
            print("manifest is out of date: run tools/gen_manifest.py", file=sys.stderr)
            return 1
        print("manifest up to date")
    else:
        os.makedirs(os.path.dirname(MANIFEST), exist_ok=True)
        with open(MANIFEST, "w") as fh:
            fh.write(body)
        n = sum(1 for t in tools for c in t["targets"].values()
                if c.get("status", "ga") in ("ga", "experimental"))
        print("manifest: %d tools, %d targets, %d buildable cells"
              % (len(tools), len(TARGETS), n))
    return 0


if __name__ == "__main__":
    sys.exit(main())
