package main

// SBX2 container: [carrier][blob region][zstd(index json)][64-byte trailer].
//
// One file can carry several payloads — one per os/arch — because the same
// bundle is shipped to a Mac (two slices), a Linux fleet (four arches) or a
// Windows machine that may be x64 today and ARM64 tomorrow. The stub picks the
// payload that matches the host it runs on, and the packer stores files with
// the same content only once across payloads.

import (
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"runtime"
	"strings"

	"github.com/klauspost/compress/zstd"
)

const (
	magic2      = "SBX2"
	magic1      = "SBX1"
	trailerSize = 64
	flagLayered = 1 << 0
	flagSealed  = 1 << 1
	flagMulti   = 1 << 2
	layerToken  = "@@SB_LAYER@@/"
	cacheSchema = "b2"
)

// Trailer is the last 64 bytes of any bundle.
type Trailer struct {
	Version uint16
	Flags   uint16
	Offset  uint64
	Size    uint64
	Sum     [32]byte
	Epoch   uint64
}

// Blob is one file's bytes inside the blob region.
type Blob struct {
	Off, CSize, USize uint64
	Raw               bool
}

// File is one tree entry: dir (k=d), file (k=f, R=blob key), symlink (k=l, R=target).
type File struct {
	Path string `json:"p"`
	Kind string `json:"k"`
	Mode uint32 `json:"m"`
	Ref  string `json:"r,omitempty"`
}

// Payload is one os/arch tree plus everything needed to run it.
type Payload struct {
	ID      string            `json:"id"`
	OS      string            `json:"os"`
	Arch    string            `json:"arch"`
	Family  string            `json:"family"`
	Tier    string            `json:"tier"`
	Entry   string            `json:"entry"`
	Paths   []string          `json:"paths"`
	Env     map[string]string `json:"env"`
	Aliases map[string]string `json:"aliases"`
	Layers  []string          `json:"layers"`
	Bytes   int64             `json:"bytes"`
	Files   []File            `json:"files"`
}

// Index is the whole catalogue stored at the end of a bundle.
type Index struct {
	Format   string              `json:"format"`
	Tool     string              `json:"tool"`
	Version  string              `json:"version"`
	Epoch    int64               `json:"epoch"`
	BlobBase uint64              `json:"blob_base"`
	Blobs    map[string][]uint64 `json:"blobs"`
	Payloads []Payload           `json:"payloads"`
}

func (ix *Index) blob(key string) (Blob, bool) {
	v, ok := ix.Blobs[key]
	if !ok || len(v) < 3 {
		return Blob{}, false
	}
	b := Blob{Off: v[0], CSize: v[1], USize: v[2]}
	if len(v) > 3 {
		b.Raw = v[3] == 1
	}
	return b, true
}

// Bundle is an opened file plus its parsed index.
type Bundle struct {
	Path    string
	Trailer Trailer
	Index   Index
	legacy  bool
}

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
	if m := string(buf[0:4]); m != magic2 && m != magic1 {
		return nil, errors.New("not a bundle: bad magic (is the file truncated?)")
	}
	tr := &Trailer{
		Version: binary.LittleEndian.Uint16(buf[4:6]),
		Flags:   binary.LittleEndian.Uint16(buf[6:8]),
		Offset:  binary.LittleEndian.Uint64(buf[8:16]),
		Size:    binary.LittleEndian.Uint64(buf[16:24]),
		Epoch:   binary.LittleEndian.Uint64(buf[56:64]),
	}
	copy(tr.Sum[:], buf[24:56])
	if tr.Offset+tr.Size != uint64(fi.Size()-trailerSize) {
		return nil, errors.New("corrupt bundle: index does not abut the trailer")
	}
	return tr, nil
}

func openBundle(path string) (*Bundle, error) {
	tr, err := readTrailer(path)
	if err != nil {
		return nil, err
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	raw := make([]byte, tr.Size)
	if _, err := f.ReadAt(raw, int64(tr.Offset)); err != nil {
		return nil, fmt.Errorf("index read: %w", err)
	}
	b := &Bundle{Path: path, Trailer: *tr}
	if tr.Version == 1 {
		b.legacy = true
		return b, nil
	}
	zr, err := zstd.NewReader(nil)
	if err != nil {
		return nil, err
	}
	defer zr.Close()
	plain, err := zr.DecodeAll(raw, nil)
	if err != nil {
		return nil, fmt.Errorf("index decompress: %w", err)
	}
	if err := json.Unmarshal(plain, &b.Index); err != nil {
		return nil, fmt.Errorf("index json: %w", err)
	}
	if b.Index.Format != magic2 {
		return nil, fmt.Errorf("unsupported index format %q", b.Index.Format)
	}
	return b, nil
}

func normArch(a string) string {
	switch strings.ToLower(a) {
	case "amd64", "x64", "x86_64":
		return "x86_64"
	case "aarch64", "arm64":
		return "arm64"
	case "arm", "armv7", "armv7l":
		return "armv7"
	case "i386", "i686", "386":
		return "386"
	}
	return strings.ToLower(a)
}

func hostOS() string {
	switch runtime.GOOS {
	case "darwin":
		return "macos"
	case "ios", "iossimulator":
		return "ios"
	}
	return runtime.GOOS
}

// hostArch reports the architecture the payload should be built for. On Windows
// an amd64 stub runs on ARM64 hardware under emulation; PROCESSOR_ARCHITEW6432
// names the real machine, so a single windows-x86_64 download still gets the
// native arm64 payload when the bundle carries one.
func hostArch() string {
	if runtime.GOOS == "windows" {
		for _, k := range []string{"PROCESSOR_ARCHITEW6432", "PROCESSOR_ARCHITECTURE"} {
			if v := strings.ToUpper(os.Getenv(k)); v != "" {
				return normArch(v)
			}
		}
	}
	return normArch(runtime.GOARCH)
}

// selectPayload resolves --sb-payload, exact host match, then a single-payload
// fallback (a foreign-arch bundle extracted on purpose).
func (b *Bundle) selectPayload(forced string) (*Payload, error) {
	ps := b.Index.Payloads
	if len(ps) == 0 {
		return nil, errors.New("bundle carries no payloads")
	}
	if forced != "" {
		for i := range ps {
			if ps[i].ID == forced || ps[i].OS+"-"+ps[i].Arch == forced ||
				ps[i].OS+"/"+ps[i].Arch == forced {
				return &ps[i], nil
			}
		}
		return nil, fmt.Errorf("no payload %q (have %s)", forced, b.payloadIDs())
	}
	wantOS, wantArch := hostOS(), hostArch()
	for i := range ps {
		if ps[i].OS == wantOS && normArch(ps[i].Arch) == wantArch {
			return &ps[i], nil
		}
	}
	if len(ps) == 1 {
		return &ps[0], nil
	}
	return nil, fmt.Errorf("no payload for %s/%s (have %s)", wantOS, wantArch, b.payloadIDs())
}

func (b *Bundle) payloadIDs() string {
	ids := make([]string, 0, len(b.Index.Payloads))
	for _, p := range b.Index.Payloads {
		ids = append(ids, p.ID)
	}
	return strings.Join(ids, ", ")
}

// payloadKey is the content address of one extracted payload tree.
func (b *Bundle) payloadKey(p *Payload) string {
	return cacheSchema + "-" + sanitize(p.ID) + "-" + hex.EncodeToString(b.Trailer.Sum[:8])
}

func sanitize(s string) string {
	return strings.Map(func(r rune) rune {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z',
			r >= '0' && r <= '9', r == '-', r == '.':
			return r
		}
		return '_'
	}, s)
}
