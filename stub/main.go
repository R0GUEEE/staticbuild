// Command sb-stub is the carrier of every bundle this repository produces.
//
// Compiled once per target (ELF, Mach-O, PE; static, CGO off). pack.py appends
// the blob region, the index and a trailer, so the artefact is one file.
//
// At run time it validates the trailer and the index digest, extracts the
// payload matching the host into a content-addressed cache (shared across every
// bundle carrying the same layer), and hands the process to the real program.
//
// Introspection flags never extract a payload:
//
//	--sb-version            stub + index digest
//	--sb-print-index        the whole payload catalogue as JSON
//	--sb-print-meta         metadata of the payload this host would run
//	--sb-payloads           one line per payload
//	--sb-list               commands this bundle answers to
//	--sb-cache              extraction root
//	--sb-clean              remove the extraction root
//	--sb-extract-dir DIR    materialise the tree and stop
//	--sb-payload ID         run a specific payload
//	--sb-run NAME args...   run an alias (npm, javac, clang++)
package main

import (
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
)

const stubVersion = "2.0.0"

func main() {
	self, err := os.Executable()
	if err != nil {
		fatal(err)
	}
	if self, err = filepath.EvalSymlinks(self); err != nil {
		fatal(err)
	}

	args := os.Args[1:]
	// --sb-payload may appear anywhere; it selects the payload for this run.
	for i := 0; i < len(args); i++ {
		if args[i] == "--sb-payload" && i+1 < len(args) {
			os.Setenv("SB_PAYLOAD", args[i+1])
			args = append(args[:i], args[i+2:]...)
			break
		}
	}
	// --sb-run needs the extracted tree; every other flag is metadata-only.
	dispatch := len(args) >= 1 && args[0] == "--sb-run"
	if len(args) >= 1 && strings.HasPrefix(args[0], "--sb-") && !dispatch {
		if err := inspect(self, args); err != nil {
			fatalf("%s: %v", filepath.Base(self), err)
		}
		return
	}

	b, err := openBundle(self)
	if err != nil {
		fatalf("%s: %v", filepath.Base(self), err)
	}
	payload, err := b.resolvePayload(os.Getenv("SB_PAYLOAD"))
	if err != nil {
		fatalf("%s: %v", filepath.Base(self), err)
	}
	root, err := b.materialize(payload, "")
	if err != nil {
		fatalf("%s: %v", filepath.Base(self), err)
	}
	entry, rest := selectEntry(payload, filepath.Base(self), args)
	prog := entry
	if !filepath.IsAbs(prog) {
		prog = filepath.Join(root, filepath.FromSlash(entry))
	}
	if err := execBundle(prog, append([]string{prog}, rest...), bundleEnv(payload, root)); err != nil {
		fatalf("%s: %v", filepath.Base(self), err)
	}
}

func (b *Bundle) resolvePayload(forced string) (*Payload, error) {
	if b.legacy {
		return b.legacyPayload()
	}
	return b.selectPayload(forced)
}

// selectEntry resolves multi-call dispatch:
//
//	<bundle> --sb-run NAME args     explicit
//	<symlink NAME> args             argv[0] against aliases
//	<bundle> args                   the payload entry
func selectEntry(p *Payload, invoked string, args []string) (string, []string) {
	if len(args) >= 2 && args[0] == "--sb-run" {
		if path, ok := p.Aliases[args[1]]; ok {
			return path, args[2:]
		}
		fatalf("%s: no program %q (try --sb-list)", invoked, args[1])
	}
	if path, ok := p.Aliases[invoked]; ok {
		return path, args
	}
	return p.Entry, args
}

// bundleEnv builds the child environment: PATH gets the payload's own bin
// directories first, then the tool's declared variables, then the host's.
func bundleEnv(p *Payload, root string) []string {
	sep := ":"
	if runtime.GOOS == "windows" {
		sep = ";"
	}
	dirs := make([]string, 0, len(p.Paths))
	for _, d := range p.Paths {
		if d == "" {
			continue
		}
		if filepath.IsAbs(d) {
			dirs = append(dirs, d)
			continue
		}
		dirs = append(dirs, filepath.Join(root, filepath.FromSlash(d)))
	}
	env := map[string]string{}
	order := []string{}
	for _, kv := range os.Environ() {
		k, v, ok := strings.Cut(kv, "=")
		if !ok {
			continue
		}
		env[k] = v
		order = append(order, k)
	}
	if len(dirs) > 0 {
		old := env["PATH"]
		env["PATH"] = strings.Join(dirs, sep)
		if old != "" {
			env["PATH"] += sep + old
		}
	}
	for k, v := range p.Env {
		if _, seen := env[k]; !seen {
			order = append(order, k)
		}
		env[k] = expand(v, root)
	}
	out := make([]string, 0, len(env))
	seen := map[string]bool{}
	for _, k := range order {
		if seen[k] {
			continue
		}
		seen[k] = true
		out = append(out, k+"="+env[k])
	}
	for k, v := range env {
		if !seen[k] {
			out = append(out, k+"="+v)
		}
	}
	return out
}

func expand(v, root string) string {
	v = strings.ReplaceAll(v, "${ROOT}", root)
	v = strings.ReplaceAll(v, "${LAYERS}", filepath.Join(cacheRoot(), "l"))
	v = strings.ReplaceAll(v, "${CACHE}", cacheRoot())
	v = strings.ReplaceAll(v, "$ROOT", root)
	return v
}

// inspect prints metadata. It must work on a foreign-arch bundle too, so it
// never materialises anything unless --sb-extract-dir asks for it.
func inspect(self string, args []string) error {
	b, err := openBundle(self)
	if err != nil {
		return err
	}
	switch args[0] {
	case "--sb-version":
		fmt.Printf("stub %s  %s/%s\nbundle %s %s  index %s\n", stubVersion,
			runtime.GOOS, runtime.GOARCH, b.Index.Tool, b.Index.Version,
			hex.EncodeToString(b.Trailer.Sum[:12]))
		if b.legacy {
			fmt.Println("payload format SBX1 (legacy, single payload)")
		}
		return nil

	case "--sb-payloads":
		for _, p := range b.Index.Payloads {
			fmt.Printf("%-16s %-8s %-8s %-10s %s\n", p.ID, p.OS, p.Arch, p.Tier, p.Entry)
		}
		return nil

	case "--sb-cache":
		fmt.Println(cacheRoot())
		return nil

	case "--sb-clean":
		return os.RemoveAll(cacheRoot())

	case "--sb-list":
		p, err := b.resolvePayload(os.Getenv("SB_PAYLOAD"))
		if err != nil {
			return err
		}
		fmt.Printf("%s %s\n  %s\t%s (default)\n", b.Index.Tool, b.Index.Version,
			p.Entry, filepath.Base(p.Entry))
		names := make([]string, 0, len(p.Aliases))
		for k := range p.Aliases {
			names = append(names, k)
		}
		sort.Strings(names)
		for _, k := range names {
			fmt.Printf("  %s\t%s\n", k, p.Aliases[k])
		}
		return nil

	case "--sb-print-index":
		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")
		return enc.Encode(b.Index)

	case "--sb-print-meta":
		p, err := b.resolvePayload(os.Getenv("SB_PAYLOAD"))
		if err != nil {
			return err
		}
		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")
		return enc.Encode(p)

	case "--sb-extract-dir":
		if len(args) < 2 {
			return fmt.Errorf("--sb-extract-dir needs a directory")
		}
		p, err := b.resolvePayload(os.Getenv("SB_PAYLOAD"))
		if err != nil {
			return err
		}
		root, err := b.materialize(p, args[1])
		if err != nil {
			return err
		}
		fmt.Println(root)
		return nil
	}
	return fmt.Errorf("unknown flag %q", args[0])
}

func fatal(err error) { fatalf("%v", err) }

func fatalf(format string, a ...any) {
	fmt.Fprintf(os.Stderr, format+"\n", a...)
	os.Exit(1)
}
