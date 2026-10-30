package main

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/klauspost/compress/zstd"
)

// cacheRoot resolves the extraction root. SB_CACHE always wins (iOS sandbox,
// CI), then the platform convention, then TMPDIR.
func cacheRoot() string {
	if v := os.Getenv("SB_CACHE"); v != "" {
		return v
	}
	if v := os.Getenv("XDG_CACHE_HOME"); v != "" {
		return filepath.Join(v, "staticbuild")
	}
	if hostOS() == "windows" && os.Getenv("LOCALAPPDATA") != "" {
		return filepath.Join(os.Getenv("LOCALAPPDATA"), "staticbuild")
	}
	if v := os.Getenv("HOME"); v != "" {
		return filepath.Join(v, ".cache", "staticbuild")
	}
	return filepath.Join(os.TempDir(), "staticbuild-cache")
}

func layerDir(sha string) string { return filepath.Join(cacheRoot(), "l", sha) }

// resolveToken turns a layer-relative symlink into an absolute cache path.
// Recipes write `@@SB_LAYER@@/<sha>/lib/...` because only the stub knows where
// the cache lives on this machine.
func resolveToken(target string) string {
	i := strings.Index(target, layerToken)
	if i < 0 {
		return target
	}
	return filepath.Join(cacheRoot(), "l", filepath.FromSlash(target[i+len(layerToken):]))
}

// materialize writes the payload tree and returns its root. With dest != "" the
// tree is written there verbatim (layers inlined, no cache reuse): the
// --sb-extract-dir path, where a project wants the SDK rather than an exec.
func (b *Bundle) materialize(p *Payload, dest string) (string, error) {
	if b.legacy {
		return b.extractLegacy(dest)
	}
	if !b.indexIntact() {
		return "", errors.New("index digest does not match the trailer: the file is damaged")
	}
	if dest != "" {
		if err := b.writeTree(p, dest); err != nil {
			return "", err
		}
		return dest, nil
	}
	root := filepath.Join(cacheRoot(), "b", b.payloadKey(p))
	if ready, err := isReady(root); err == nil && ready {
		return root, nil
	}
	if err := os.MkdirAll(filepath.Dir(root), 0o755); err != nil {
		return "", err
	}
	tmp := fmt.Sprintf("%s.tmp%d", root, os.Getpid())
	os.RemoveAll(tmp)
	if err := b.writeTree(p, tmp); err != nil {
		os.RemoveAll(tmp)
		return "", err
	}
	if err := liftLayers(p, tmp); err != nil {
		os.RemoveAll(tmp)
		return "", err
	}
	if err := os.WriteFile(filepath.Join(tmp, ".sb-ready"), []byte(p.Entry+"\n"), 0o644); err != nil {
		os.RemoveAll(tmp)
		return "", err
	}
	if err := os.Rename(tmp, root); err != nil {
		if ready, e2 := isReady(root); e2 == nil && ready {
			os.RemoveAll(tmp)
			return root, nil
		}
		os.RemoveAll(tmp)
		return "", err
	}
	return root, nil
}

func isReady(root string) (bool, error) {
	if _, err := os.Stat(filepath.Join(root, ".sb-ready")); err != nil {
		return false, err
	}
	return true, nil
}

func (b *Bundle) indexIntact() bool {
	f, err := os.Open(b.Path)
	if err != nil {
		return false
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.CopyN(h, io.NewSectionReader(f, int64(b.Trailer.Offset),
		int64(b.Trailer.Size)), int64(b.Trailer.Size)); err != nil {
		return false
	}
	return hex.EncodeToString(h.Sum(nil)) == hex.EncodeToString(b.Trailer.Sum[:])
}

func safeJoin(root, rel string) (string, error) {
	if rel == "" || strings.HasPrefix(rel, "/") || strings.Contains(rel, "..") {
		return "", fmt.Errorf("unsafe path in payload: %q", rel)
	}
	return filepath.Join(root, filepath.FromSlash(rel)), nil
}

// writeTree materialises every entry straight out of the blob region.
func (b *Bundle) writeTree(p *Payload, root string) error {
	if err := os.MkdirAll(root, 0o755); err != nil {
		return err
	}
	f, err := os.Open(b.Path)
	if err != nil {
		return err
	}
	defer f.Close()
	zr, err := zstd.NewReader(nil, zstd.WithDecoderConcurrency(1), zstd.WithDecoderLowmem(true))
	if err != nil {
		return err
	}
	defer zr.Close()

	var buf []byte
	for _, ent := range p.Files {
		dst, err := safeJoin(root, ent.Path)
		if err != nil {
			return err
		}
		switch ent.Kind {
		case "d":
			if err := os.MkdirAll(dst, os.FileMode(ent.Mode|0o700)); err != nil {
				return err
			}
		case "l":
			if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
				return err
			}
			// Windows needs a privilege for symlinks that a payload cannot
			// assume, so a failed link falls back to copying the target.
			os.Remove(dst)
			if err := os.Symlink(resolveToken(ent.Ref), dst); err != nil {
				if !copyLink(root, ent.Ref, dst) {
					return fmt.Errorf("symlink %s: %w", ent.Path, err)
				}
			}
		case "f":
			blob, ok := b.Index.blob(ent.Ref)
			if !ok {
				return fmt.Errorf("missing blob %s for %s", ent.Ref, ent.Path)
			}
			if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
				return err
			}
			packed := make([]byte, blob.CSize)
			if _, err := f.ReadAt(packed, int64(b.Index.BlobBase+blob.Off)); err != nil {
				return fmt.Errorf("blob %s: %w", ent.Ref, err)
			}
			data := packed
			if !blob.Raw {
				if data, err = zr.DecodeAll(packed, buf[:0]); err != nil {
					return fmt.Errorf("blob %s: %w", ent.Ref, err)
				}
				buf = data[:0]
			}
			if uint64(len(data)) != blob.USize {
				return fmt.Errorf("blob %s: %d bytes, expected %d", ent.Ref, len(data), blob.USize)
			}
			out, err := os.OpenFile(dst, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, os.FileMode(ent.Mode&0o777))
			if err != nil {
				return err
			}
			if _, err := out.Write(data); err != nil {
				out.Close()
				return err
			}
			if err := out.Close(); err != nil {
				return err
			}
			if err := os.Chmod(dst, os.FileMode(ent.Mode&0o777)); err != nil {
				return err
			}
		}
	}
	return nil
}

// copyLink materialises a symlink target when the OS refuses to create one.
func copyLink(root, target, dst string) bool {
	if strings.Contains(target, layerToken) {
		target = resolveToken(target)
	}
	if !filepath.IsAbs(target) {
		target = filepath.Join(filepath.Dir(dst), filepath.FromSlash(target))
	}
	src, err := os.Open(target)
	if err != nil {
		return false
	}
	defer src.Close()
	out, err := os.OpenFile(dst, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o755)
	if err != nil {
		return false
	}
	defer out.Close()
	_, err = io.Copy(out, src)
	return err == nil
}

// liftLayers moves layers/<sha> trees out of the fresh payload into the shared
// cache, so java+kotlin that share a JRE store it once on disk. Symlinks that
// pointed at the token are rewritten to absolute paths.
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
			if err := copyTree(src, dst); err != nil {
				return err
			}
			os.RemoveAll(src)
		}
		if err := rewriteTokens(dst); err != nil {
			return err
		}
	}
	os.RemoveAll(filepath.Join(root, "layers"))
	return rewriteTokens(root)
}

func rewriteTokens(root string) error {
	return filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
		if err != nil || d.Type()&os.ModeSymlink == 0 {
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
