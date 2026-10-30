package main

import (
	"archive/tar"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/klauspost/compress/zstd"
)

// resolveToken turns a layer-relative symlink into an absolute cache path.
// Recipes write `@@SB_LAYER@@/<sha>/lib/...` because the stub is the only
// component that knows where the cache lives.
func resolveToken(target string) string {
	i := strings.Index(target, layerToken)
	if i < 0 {
		return target
	}
	return filepath.Join(cacheRoot(), "l", filepath.FromSlash(target[i+len(layerToken):]))
}

// liftLayers moves layers/<sha> trees out of the fresh payload into the shared
// cache, so java+kotlin+python that share a JRE store it once on disk. Symlinks
// that pointed at the token are rewritten to absolute paths.
func liftLayers(p *Payload, root string) error {
	for _, sha := range p.Layers {
		src := filepath.Join(root, "layers", sha)
		dst := layerDir(sha)
		if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
			return err
		}
		if _, err := os.Stat(dst); err == nil {
			os.RemoveAll(src)
			continue
		}
		if err := os.Rename(src, dst); err != nil {
			// Cross-device or racing: copy then drop.
			if err := copyTree(src, dst); err != nil {
				return err
			}
			os.RemoveAll(src)
		}
		if err := rewriteTokens(dst); err != nil {
			return err
		}
	}
	if err := os.RemoveAll(filepath.Join(root, "layers")); err != nil {
		return err
	}
	return rewriteTokens(root)
}

// rewriteTokens rewrites every @@SB_LAYER@@ symlink under root, in place.
func rewriteTokens(root string) error {
	return filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if d.Type()&os.ModeSymlink == 0 {
			return nil
		}
		target, err := os.Readlink(path)
		if err != nil || !strings.Contains(target, layerToken) {
			return nil
		}
		os.Remove(path)
		return os.Symlink(resolveToken(target), path)
	})
}

func copyTree(src, dst string) error {
	return filepath.WalkDir(src, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(src, path)
		if err != nil {
			return err
		}
		out := filepath.Join(dst, rel)
		info, err := d.Info()
		if err != nil {
			return err
		}
		switch {
		case d.IsDir():
			return os.MkdirAll(out, 0o755)
		case info.Mode()&os.ModeSymlink != 0:
			t, err := os.Readlink(path)
			if err != nil {
				return err
			}
			os.Remove(out)
			return os.Symlink(t, out)
		default:
			in, err := os.Open(path)
			if err != nil {
				return err
			}
			defer in.Close()
			w, err := os.OpenFile(out, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, info.Mode()&0o777)
			if err != nil {
				return err
			}
			if _, err := io.Copy(w, in); err != nil {
				w.Close()
				return err
			}
			return w.Close()
		}
	})
}

// extractLegacy reads an SBX1 bundle: a zstd tar with .sb/meta.json inside.
// v1 artifacts stay runnable; the format only gained payloads.
func (b *Bundle) extractLegacy(dest string) (string, error) {
	f, err := os.Open(b.Path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	root := dest
	if root == "" {
		root = filepath.Join(cacheRoot(), "v1", hex.EncodeToString(b.Trailer.Sum[:8]))
		if _, err := os.Stat(filepath.Join(root, ".sb-ready")); err == nil {
			return root, nil
		}
	}
	if err := os.MkdirAll(root, 0o755); err != nil {
		return "", err
	}
	sec := io.NewSectionReader(f, int64(b.Trailer.Offset), int64(b.Trailer.Size))
	zr, err := zstd.NewReader(sec, zstd.WithDecoderConcurrency(2))
	if err != nil {
		return "", err
	}
	defer zr.Close()
	tr := tar.NewReader(zr)
	for {
		h, err := tr.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return "", err
		}
		name := strings.TrimPrefix(filepath.ToSlash(h.Name), "./")
		if name == "" || strings.HasPrefix(name, "/") || strings.Contains(name, "..") {
			continue
		}
		dst := filepath.Join(root, filepath.FromSlash(name))
		switch h.Typeflag {
		case tar.TypeDir:
			os.MkdirAll(dst, 0o755)
		case tar.TypeSymlink:
			os.MkdirAll(filepath.Dir(dst), 0o755)
			os.Remove(dst)
			os.Symlink(resolveToken(h.Linkname), dst)
		case tar.TypeReg:
			os.MkdirAll(filepath.Dir(dst), 0o755)
			w, err := os.OpenFile(dst, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, os.FileMode(h.Mode&0o777))
			if err != nil {
				return "", err
			}
			if _, err := io.Copy(w, tr); err != nil {
				w.Close()
				return "", err
			}
			w.Close()
		}
	}
	os.WriteFile(filepath.Join(root, ".sb-ready"), []byte("v1\n"), 0o644)
	return root, nil
}

// legacyPayload reads .sb/meta.json out of a v1 bundle so --sb-print-meta and
// multi-call dispatch keep working on old artifacts.
func (b *Bundle) legacyPayload() (*Payload, error) {
	f, err := os.Open(b.Path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	sec := io.NewSectionReader(f, int64(b.Trailer.Offset), int64(b.Trailer.Size))
	zr, err := zstd.NewReader(sec)
	if err != nil {
		return nil, err
	}
	defer zr.Close()
	tr := tar.NewReader(zr)
	for {
		h, err := tr.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, err
		}
		if strings.TrimPrefix(h.Name, "./") != ".sb/meta.json" {
			continue
		}
		var meta struct {
			Tool    string            `json:"tool"`
			Version string            `json:"version"`
			Entry   string            `json:"entry"`
			Family  string            `json:"family"`
			Paths   []string          `json:"paths"`
			Env     map[string]string `json:"env"`
			Aliases map[string]string `json:"aliases"`
			Layers  []string          `json:"layers"`
		}
		if err := json.NewDecoder(tr).Decode(&meta); err != nil {
			return nil, err
		}
		b.Index.Tool, b.Index.Version = meta.Tool, meta.Version
		return &Payload{ID: "legacy", OS: "unknown", Arch: "unknown", Entry: meta.Entry,
			Family: meta.Family, Paths: meta.Paths, Env: meta.Env, Aliases: meta.Aliases,
			Layers: meta.Layers}, nil
	}
	return nil, errors.New("v1 payload has no .sb/meta.json")
}
