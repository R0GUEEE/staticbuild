package main

import (
	"crypto/sha256"
	"encoding/hex"
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
	switch {
	case os.Getenv("XDG_CACHE_HOME") != "":
		return filepath.Join(os.Getenv("XDG_CACHE_HOME"), "staticbuild")
	case os.Getenv("LOCALAPPDATA") != "" && hostOS() == "windows":
		return filepath.Join(os.Getenv("LOCALAPPDATA"), "staticbuild")
	case os.Getenv("HOME") != "":
		return filepath.Join(os.Getenv("HOME"), ".cache", "staticbuild")
	case os.Getenv("TMPDIR") != "":
		return filepath.Join(os.Getenv("TMPDIR"), "staticbuild-cache")
	}
	return filepath.Join(os.TempDir(), "staticbuild-cache")
}

func layerDir(sha string) string { return filepath.Join(cacheRoot(), "l", sha) }

// materialize writes the payload tree and returns its root. With dest != "" the
// tree is written there verbatim (layers inlined, no cache reuse), which is the
// --sb-extract-dir path: a downstream project wants the SDK, not an exec.
func (b *Bundle) materialize(p *Payload, dest string) (string, error) {
	if b.legacy {
		return b.extractLegacy(dest)
	}
	if !verifyIndexDigest(b) {
		return "", fmt.Errorf("%s: index digest mismatch (corrupt or truncated bundle)", filepath.Base(b.Path))
	}

	if dest != "" {
		if err := b.writeTree(p, dest, true); err != nil {
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
	if err := b.writeTree(p, tmp, false); err != nil {
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
		// Lost a race with another process: its tree is as good as ours.
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
	if _, err := os.Stat(root); err != nil {
		return false, err
	}
	if _, err := os.Stat(filepath.Join(root, ".sb-ready")); err != nil {
		return false, err
	}
	return true, nil
}

func verifyIndexDigest(b *Bundle) bool {
	h := sha256.New()
	f, err := os.Open(b.Path)
	if err != nil {
		return false
	}
	defer f.Close()
	if _, err := f.Seek(int64(b.Trailer.Offset), io.SeekStart); err != nil {
		return false
	}
	if _, err := io.CopyN(h, f, int64(b.Trailer.Size)); err != nil {
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

// writeTree materialises every entry. inline=true keeps layer trees in place
// (the extract-dir path); otherwise layers/<sha> is left for liftLayers.
func (b *Bundle) writeTree(p *Payload, root string, inline bool) error {
	if err := os.MkdirAll(root, 0o755); err != nil {
		return err
	}
	f, err := os.Open(b.Path)
	if err != nil {
		return err
	}
	defer f.Close()
	zr, err := zstd.NewReader(nil, zstd.WithDecoderConcurrency(2))
	if err != nil {
		return err
	}
	defer zr.Close()

	buf := make([]byte, 0, 1<<20)
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
			os.Remove(dst)
			if err := os.Symlink(resolveToken(ent.Ref), dst); err != nil {
				return err
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
				buf = buf[:0]
				if data, err = zr.DecodeAll(packed, buf); err != nil {
					return fmt.Errorf("blob %s: %w", ent.Ref, err)
				}
			}
			if uint64(len(data)) != blob.USize {
				return fmt.Errorf("blob %s: %d bytes, expected %d", ent.Ref, len(data), blob.USize)
			}
			// The blob key is the first 32 hex chars of its sha256: this is the
			// check that turns a flipped byte anywhere in the file into a clear
			// failure instead of a mysteriously broken tool.
			if sum := sha256.Sum256(data); hex.EncodeToString(sum[:])[:len(ent.Ref)] != ent.Ref {
				return fmt.Errorf("blob %s (%s): content digest mismatch", ent.Ref, ent.Path)
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
