package main

import (
	"archive/tar"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/klauspost/compress/zstd"
)

// extractLegacy reads an SBX1 bundle: a zstd tar with .sb/meta.json inside.
// v1 artefacts stay runnable; the format only gained payloads.
func (b *Bundle) extractLegacy(dest string) (string, error) {
	f, err := os.Open(b.Path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	root := dest
	if root == "" {
		root = filepath.Join(cacheRoot(), "v1", hex.EncodeToString(b.Trailer.Sum[:8]))
		if ok, err := isReady(root); err == nil && ok {
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
			if err := os.Symlink(resolveToken(h.Linkname), dst); err != nil {
				copyLink(root, h.Linkname, dst)
			}
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
// multi-call dispatch keep working on old artefacts.
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
			Family: meta.Family, Paths: meta.Paths, Env: meta.Env,
			Aliases: meta.Aliases, Layers: meta.Layers}, nil
	}
	return nil, errors.New("v1 payload has no .sb/meta.json")
}
