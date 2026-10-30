//go:build windows

package main

import (
	"os"
	"os/exec"
)

// execBundle: Windows has no execve, so spawn and forward the exit code. stdin,
// stdout and stderr are inherited handles, which keeps pipes and CI logs intact.
func execBundle(prog string, argv []string, env []string) error {
	cmd := exec.Command(prog, argv[1:]...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	cmd.Env = env
	err := cmd.Run()
	if err == nil {
		os.Exit(0)
	}
	if ee, ok := err.(*exec.ExitError); ok {
		os.Exit(ee.ExitCode())
	}
	return err
}
