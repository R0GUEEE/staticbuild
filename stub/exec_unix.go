//go:build !windows

package main

import "syscall"

// execBundle replaces the stub process with the payload program: no extra PID,
// signals and exit codes belong to the tool, argv[0] stays meaningful for
// busybox-style multi-call binaries.
func execBundle(prog string, argv []string, env []string) error {
	return syscall.Exec(prog, argv, env)
}
