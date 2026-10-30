// Command sb-stub is the self-extracting prefix of every .sfx bundle produced by
// this repository. It is compiled once per target as a fully static musl/ELF
// binary (~4 MB), and scripts/pack.sh concatenates it with a zstd-compressed tar
// payload and a 64-byte trailer.
//
// At run time it validates the trailer, extracts the payload into a
// content-addressed cache (shared across every bundle that carries the same
// layer), and execve()s the real entrypoint with the environment the bundle
// declares.
package main

import (
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"

)

const (
	magic       = "SBX1"
	trailerSize = 64
	flagLayered = 1 << 0 // payload carries layers/<sha>/ trees, not just files
	flagSealed  = 1 << 1 // payload sha256 verified by the packer at build time
)

// Trailer is the last 64 bytes of a bundle.
//
//	 0..3   magic "SBX1"
//	 4..5   uint16 version
//	 6..7   uint16 flags
//	 8..15  uint64 payload offset
//	16..23  uint64 payload size
//	24..55  [32]byte sha256 of the payload
//	56..63  uint64 build epoch (SOURCE_DATE_EPOCH)
type Trailer struct {
	Version uint16
	Flags   uint16
	Offset  uint64
	Size    uint64
	Sum     [32]byte
	Epoch   uint64
}

// Meta is .sb/meta.json, the only file the stub requires inside the payload.
type Meta struct {
	Tool    string            `json:"tool"`
	Version string            `json:"version"`
	Entry   string            `json:"entry"`  // path relative to bundle root
	Paths   []string          `json:"paths"`  // added to PATH, in order, before the host PATH
	Env     map[string]string `json:"env"`    // extra environment, ${ROOT} expanded
	Layers  []string          `json:"layers"` // layer hashes carried in layers/<sha>/
	Layered bool              `json:"layered"`
	Require []string          `json:"require"` // host binaries the bundle shells out to, if any
}

func main() {
	self, err := os.Executable()
	if err != nil {
		fatal(err)
	}
	if self, err = filepath.EvalSymlinks(self); err != nil {
		fatal(err)
	}

	if len(os.Args) > 1 && strings.HasPrefix(os.Args[1], "--sb-") {
		if err := inspect(self, os.Args[1:]); err != nil {
			fatal(err)
		}
		return
	}

	tr, err := readTrailer(self)
	if err != nil {
		fatalf("%s: %v", filepath.Base(self), err)
	}
	meta, root, err := materialize(self, tr, nil)
	if err != nil {
		fatalf("%s: %v", filepath.Base(self), err)
	}
	if err := execBundle(meta, root, os.Args[1:]); err != nil {
		fatalf("%s: %v", filepath.Base(self), err)
	}
}

// readTrailer pulls and validates the fixed-size trailer.
func readTrailer(path string) (*Trailer, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		return nil, err
	}
	if fi.Size() < trailerSize {
		return nil, errors.New("not a bundle: file smaller than trailer")
	}
	buf := make([]byte, trailerSize)
	if _, err := f.ReadAt(buf, fi.Size()-trailerSize); err != nil {
		return nil, err
	}
	if string(buf[0:4]) != magic {
		return nil, errors.New("not a bundle: bad magic (is the payload truncated?)")
	}
	tr := &Trailer{
		Version: binary.LittleEndian.Uint16(buf[4:6]),
		Flags:   binary.LittleEndian.Uint16(buf[6:8]),
		Offset:  binary.LittleEndian.Uint64(buf[8:16]),
		Size:    binary.LittleEndian.Uint64(buf[16:24]),
		Epoch:   binary.LittleEndian.Uint64(buf[56:64]),
	}
	copy(tr.Sum[:], buf[24:56])
	if tr.Version != 1 {
		return nil, fmt.Errorf("unsupported bundle version %d", tr.Version)
	}
	if tr.Offset+tr.Size != uint64(fi.Size()-trailerSize) {
		return nil, errors.New("corrupt bundle: payload does not abut the trailer")
	}
	return tr, nil
}

// cacheDir resolves the extraction root. The order matters on iOS and in
// CI: an explicit SB_CACHE always wins, then XDG, then HOME, then TMPDIR.
func cacheDir() string {
	if v := os.Getenv("SB_CACHE"); v != "" {
		return v
	}
	if v := os.Getenv("XDG_CACHE_HOME"); v != "" {
		return filepath.Join(v, "staticbuild")
	}
	if v := os.Getenv("HOME"); v != "" {
		return filepath.Join(v, ".cache", "staticbuild")
	}
	return filepath.Join(os.TempDir(), "staticbuild-"+strconv.Itoa(os.Getuid()))
}

// bundleKey is the content address used for the extracted tree.
func bundleKey(tr *Trailer) string { return hex.EncodeToString(tr.Sum[:12]) }

// materialize extracts (or reuses) the bundle and returns its metadata and root.
// If dest is non-empty the tree is written there directly, with layers inlined
// and no cache lookup: that is the --sb-extract-dir path used when a downstream
// project wants the SDK tree rather than the executable.
func materialize(self string, tr *Trailer, dest *string) (*Meta, string, error) {
	f, err := os.Open(self)
	if err != nil {
		return nil, "", err
	}
	defer f.Close()
	payload := io.NewSectionReader(f, int64(tr.Offset), int64(tr.Size))

	cache := cacheDir()
	key := bundleKey(tr)

	var root string
	var tmp string
	if dest != nil {
		root = *dest
		if err := os.MkdirAll(root, 0o755); err != nil {
			return nil, "", err
		}
	} else {
		root = filepath.Join(cache, "b", key)
		if ok, _ := os.Stat(filepath.Join(root, ".sb-ok")); ok != nil {
			// already extracted by an earlier run (or a concurrent bundle)
			if meta, err := readMeta(root); err == nil {
				return meta, root, nil
			}
		}
		if err := os.MkdirAll(filepath.Dir(root), 0o755); err != nil {
			return nil, "", err
		}
		if err := acquire(filepath.Join(root + ".lock")); err != nil {
			return nil, "", err
		}
		defer release(filepath.Join(root + ".lock"))
		if _, err := os.Stat(filepath.Join(root, ".sb-ok")); err == nil {
			if meta, err := readMeta(root); err == nil {
				return meta, root, nil
			}
		}
		tmp = fmt.Sprintf("%s.tmp-%d-%d", root, os.Getpid(), time.Now().UnixNano())
		if err := os.MkdirAll(tmp, 0o755); err != nil {
			return nil, "", err
		}
		root = tmp
	}

	meta, layers, err := extract(payload, root, tr)
	if err != nil {
		if tmp != "" {
			os.RemoveAll(tmp)
		}
		return nil, "", err
	}

	if tmp != "" {
		// Layered bundles: lift each layers/<sha>/ tree into the shared cache so
		// that java, kotlin and gradle (or clang and clangd) pay for the JRE or
		// libLLVM once on disk, then point the tool tree at it with symlinks.
		if len(layers) > 0 {
			shared := filepath.Join(cache, "l")
			if err := os.MkdirAll(shared, 0o755); err != nil {
				return nil, "", err
			}
			for _, sha := range layers {
				src := filepath.Join(tmp, "layers", sha)
				dst := filepath.Join(shared, sha)
				if _, err := os.Stat(filepath.Join(dst, ".sb-ok")); err == nil {
					continue
				}
				lock := dst + ".lock"
				if err := acquire(lock); err == nil {
					if _, err := os.Stat(filepath.Join(dst, ".sb-ok")); err != nil {
						if err := os.RemoveAll(dst); err != nil {
							release(lock)
							return nil, "", err
						}
						if err := os.Rename(src, dst); err != nil {
							release(lock)
							return nil, "", err
						}
						writeOK(dst)
					}
					release(lock)
				}
			}
			if err := rewriteLayerLinks(tmp, shared, layers); err != nil {
				return nil, "", err
			}
			os.RemoveAll(filepath.Join(tmp, "layers"))
		}

		writeOK(tmp)
		final := strings.TrimSuffix(tmp, tmp[strings.LastIndex(tmp, ".tmp-"):])
		if err := os.Rename(tmp, final); err != nil {
			os.RemoveAll(tmp)
			if _, statErr := os.Stat(filepath.Join(final, ".sb-ok")); statErr != nil {
				return nil, "", err
			}
		}
		root = final
	}

	meta, err = readMeta(root)
	if err != nil {
		return nil, "", err
	}
	if dest != nil && len(layers) > 0 {
		// inline mode leaves layers/ in place and fixes the links in-tree
		if err := rewriteLayerLinks(root, filepath.Join(root, "layers"), layers); err != nil {
			return nil, "", err
		}
	}
	return meta, root, nil
}

func readMeta(root string) (*Meta, error) {
	b, err := os.ReadFile(filepath.Join(root, ".sb", "meta.json"))
	if err != nil {
		return nil, fmt.Errorf("bundle is missing .sb/meta.json: %w", err)
	}
	m := &Meta{}
	if err := json.Unmarshal(b, m); err != nil {
		return nil, fmt.Errorf("bundle metadata is corrupt: %w", err)
	}
	if m.Entry == "" {
		return nil, errors.New("bundle metadata has no entry")
	}
	return m, nil
}

// execBundle builds the child environment and replaces this process.
func execBundle(meta *Meta, root string, args []string) error {
	path := filepath.Join(root, meta.Entry)
	if _, err := os.Stat(path); err != nil {
		return fmt.Errorf("entrypoint %s missing after extraction: %w", meta.Entry, err)
	}

	env := make([]string, 0, len(os.Environ())+8)
	drop := map[string]bool{
		"LD_PRELOAD": true, "LD_LIBRARY_PATH": true, "LD_AUDIT": true,
		"PYTHONHOME": true, "PYTHONPATH": true, "NODE_OPTIONS": true,
		"JAVA_HOME": true, "CLASSPATH": true, "GEM_HOME": true, "PERL5LIB": true,
	}
	for _, kv := range os.Environ() {
		if i := strings.IndexByte(kv, '='); i > 0 && drop[kv[:i]] {
			continue
		}
		env = append(env, kv)
	}

	env = append(env, "SB_BUNDLE_ROOT="+root)
	env = append(env, "SB_BUNDLE_TOOL="+meta.Tool, "SB_BUNDLE_VERSION="+meta.Version)

	if len(meta.Paths) > 0 {
		parts := make([]string, 0, len(meta.Paths)+1)
		for _, p := range meta.Paths {
			parts = append(parts, filepath.Join(root, p))
		}
		parts = append(parts, os.Getenv("PATH"))
		env = append(env, "PATH="+strings.Join(parts, ":"))
	}

	for k, v := range meta.Env {
		env = append(env, k+"="+strings.ReplaceAll(v, "${ROOT}", root))
	}
	env = append(env, "TMPDIR="+defaultTmp())

	argv := append([]string{path}, args...)
	return syscall.Exec(path, argv, env)
}

func defaultTmp() string {
	if v := os.Getenv("TMPDIR"); v != "" {
		return v
	}
	return "/tmp"
}

// inspect answers the --sb-* introspection flags without extracting anything
// except when explicitly asked to.
func inspect(self string, args []string) error {
	tr, err := readTrailer(self)
	if err != nil {
		return err
	}
	switch args[0] {
	case "--sb-version":
		fmt.Printf("staticbuild stub 1 · bundle v%d · %s/%s · payload %d bytes · sha256:%s\n",
			tr.Version, runtime.GOOS, runtime.GOARCH, tr.Size, hex.EncodeToString(tr.Sum[:]))
		return nil
	case "--sb-self":
		fmt.Println(self)
		return nil
	case "--sb-print-meta", "--sb-print-layers":
		f, err := os.Open(self)
		if err != nil {
			return err
		}
		defer f.Close()
		meta, _, err := extract(io.NewSectionReader(f, int64(tr.Offset), int64(tr.Size)),
			"", tr, onlyMeta())
		if err != nil {
			return err
		}
		b, _ := json.MarshalIndent(meta, "", "  ")
		fmt.Println(string(b))
		return nil
	case "--sb-extract-dir":
		if len(args) < 2 {
			return errors.New("usage: --sb-extract-dir DIR")
		}
		dir, err := filepath.Abs(args[1])
		if err != nil {
			return err
		}
		if _, err := os.Stat(dir); err == nil {
			return fmt.Errorf("%s already exists", dir)
		}
		meta, root, err := materialize(self, tr, &dir)
		if err != nil {
			return err
		}
		fmt.Printf("extracted %s %s to %s (entry %s)\n", meta.Tool, meta.Version, root, meta.Entry)
		return nil
	case "--sb-clean":
		if err := os.RemoveAll(cacheDir()); err != nil {
			return err
		}
		fmt.Println("cleared", cacheDir())
		return nil
	default:
		return fmt.Errorf("unknown introspection flag %q\n"+
			"  --sb-version  --sb-self  --sb-print-meta  --sb-print-layers\n"+
			"  --sb-extract-dir DIR  --sb-clean", args[0])
	}
}

// acquire takes an advisory lock file, waiting for a concurrent extractor.
func acquire(path string) error {
	deadline := time.Now().Add(15 * time.Minute)
	for {
		f, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o644)
		if err == nil {
			fmt.Fprintf(f, "%d", os.Getpid())
			f.Close()
			return nil
		}
		if !os.IsExist(err) {
			return err
		}
		if fi, statErr := os.Stat(path); statErr == nil && time.Since(fi.ModTime()) > 15*time.Minute {
			os.Remove(path) // stale: the previous extractor died
			continue
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("timed out waiting for %s", path)
		}
		time.Sleep(100 * time.Millisecond)
	}
}

func release(path string) { os.Remove(path) }

func writeOK(dir string) {
	if f, err := os.Create(filepath.Join(dir, ".sb-ok")); err == nil {
		fmt.Fprintf(f, "%d\n", time.Now().Unix())
		f.Close()
	}
}

func fatal(err error) {
	fmt.Fprintf(os.Stderr, "sb: %v\n", err)
	os.Exit(127)
}

func fatalf(format string, a ...any) {
	fmt.Fprintf(os.Stderr, "sb: "+format+"\n", a...)
	os.Exit(127)
}
