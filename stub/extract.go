package main

import (
	"archive/tar"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"

	"github.com/klauspost/compress/zstd"
)

// layerToken prefixes a symlink target that points into a shared layer tree.
// pack.sh rewrites layer-owned files into symlinks of the form
//   ../../../@@SB_LAYER@@/<sha>/lib/libLLVM.so.19.1
// and the stub turns them into absolute paths under <cache>/l/<sha>/ once the
// layer has been lifted out of the bundle.
const layerToken = "@@SB_LAYER@@/"

type exopts struct{ metaOnly bool }

func onlyMeta() extractOpts { return func(o *exopts) { o.metaOnly = true } }

type extractOpts func(*exopts)

// extract streams the zstd-compressed payload, writes the tree to root and
// returns the metadata plus the sorted list of layer hashes it carried.
func extract(r io.Reader, root string, tr *Trailer, opts ...extractOpts) (*Meta, []string, error) {
	o := &exopts{}
	for _, f := range opts {
		f(o)
	}

	sum := sha256.New()
	var src io.Reader = r
	if !o.metaOnly {
		src = io.TeeReader(r, sum)
	}
	zr, err := zstd.NewReader(src, zstd.WithDecoderConcurrency(2))
	if err != nil {
		return nil, nil, err
	}
	defer zr.Close()

	t := tar.NewReader(zr)
	layers := map[string]bool{}
	var meta *Meta
	var metaBytes []byte

	for {
		h, err := t.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, nil, fmt.Errorf("payload read: %w", err)
		}
		name, ok := safeName(h.Name)
		if !ok {
			return nil, nil, fmt.Errorf("payload contains an unsafe path %q", h.Name)
		}
		if name == "" || name == "." {
			continue
		}

		if strings.HasPrefix(name, "layers/") {
			rest := strings.TrimPrefix(name, "layers/")
			if i := strings.IndexByte(rest, '/'); i > 0 {
				layers[rest[:i]] = true
			}
		}
		if name == ".sb/meta.json" {
			b, err := io.ReadAll(io.LimitReader(t, 1<<20))
			if err != nil {
				return nil, nil, err
			}
			m := &Meta{}
			if err := json.Unmarshal(b, m); err != nil {
				return nil, nil, fmt.Errorf(".sb/meta.json: %w", err)
			}
			meta = m
			metaBytes = b
			if o.metaOnly {
				return meta, nil, nil
			}
		}
		if o.metaOnly {
			continue
		}

		dst := filepath.Join(root, filepath.FromSlash(name))
		switch h.Typeflag {
		case tar.TypeDir:
			if err := os.MkdirAll(dst, 0o755); err != nil {
				return nil, nil, err
			}
		case tar.TypeReg:
			if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
				return nil, nil, err
			}
			mode := os.FileMode(h.Mode & 0o777)
			f, err := os.OpenFile(dst, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, mode)
			if err != nil {
				return nil, nil, err
			}
			var body io.Reader = t
			if name == ".sb/meta.json" && metaBytes != nil {
				body = bytes.NewReader(metaBytes) // already consumed above
			}
			if _, err := io.Copy(f, body); err != nil {
				f.Close()
				return nil, nil, err
			}
			if err := f.Close(); err != nil {
				return nil, nil, err
			}
			// OpenFile honours umask; restore the recorded mode.
			if err := os.Chmod(dst, mode); err != nil {
				return nil, nil, err
			}
		case tar.TypeSymlink:
			if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
				return nil, nil, err
			}
			os.Remove(dst)
			if err := os.Symlink(h.Linkname, dst); err != nil {
				return nil, nil, err
			}
		case tar.TypeLink:
			// hard links inside a bundle: resolve if the target was already written
			target, ok := safeName(h.Linkname)
			if !ok {
				return nil, nil, fmt.Errorf("bad hardlink target %q", h.Linkname)
			}
			if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
				return nil, nil, err
			}
			os.Remove(dst)
			if err := os.Link(filepath.Join(root, filepath.FromSlash(target)), dst); err != nil {
				// fall back to a copy, then to a symlink
				if cpErr := copyFile(filepath.Join(root, filepath.FromSlash(target)), dst); cpErr != nil {
					return nil, nil, err
				}
			}
		case tar.TypeXGlobalHeader, tar.TypeXHeader:
			// ignore
		default:
			// devices, fifos: nothing a build tool needs
		}
	}

	if meta == nil {
		return nil, nil, errors.New("payload has no .sb/meta.json")
	}
	if !o.metaOnly && tr.Flags&flagSealed != 0 {
		if got := hex.EncodeToString(sum.Sum(nil)); got != hex.EncodeToString(tr.Sum[:]) {
			return nil, nil, fmt.Errorf("payload checksum mismatch (bundle corrupted in transit?)\n  want %s\n  got  %s",
				hex.EncodeToString(tr.Sum[:]), got)
		}
	}

	out := make([]string, 0, len(layers))
	for k := range layers {
		out = append(out, k)
	}
	sort.Strings(out)
	if meta != nil && len(meta.Layers) > 0 {
		out = meta.Layers
	}
	return meta, out, nil
}

// rewriteLayerLinks turns every @@SB_LAYER@@/ token in the tree into an
// absolute path inside the shared layer cache.
func rewriteLayerLinks(root, layerRoot string, layers []string) error {
	known := make(map[string]bool, len(layers))
	for _, l := range layers {
		known[l] = true
	}
	return filepath.WalkDir(root, func(p string, d os.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if d.Type()&os.ModeSymlink == 0 {
			return nil
		}
		target, err := os.Readlink(p)
		if err != nil || !strings.Contains(target, layerToken) {
			return nil
		}
		i := strings.Index(target, layerToken)
		rest := target[i+len(layerToken):]
		sha := rest
		tail := ""
		if j := strings.IndexByte(rest, '/'); j > 0 {
			sha, tail = rest[:j], rest[j+1:]
		}
		if !known[sha] {
			return fmt.Errorf("%s references layer %s which the bundle does not carry", p, sha)
		}
		resolved := filepath.Join(layerRoot, sha, filepath.FromSlash(tail))
		if err := os.Remove(p); err != nil {
			return err
		}
		return os.Symlink(resolved, p)
	})
}

// safeName rejects absolute paths and traversal.
func safeName(name string) (string, bool) {
	name = strings.TrimPrefix(name, "./")
	if name == "" {
		return "", true
	}
	if strings.HasPrefix(name, "/") {
		return "", false
	}
	clean := path.Clean(name)
	if clean == ".." || strings.HasPrefix(clean, "../") {
		return "", false
	}
	return clean, true
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}
