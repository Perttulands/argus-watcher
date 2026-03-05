package main

import (
	"context"
	"errors"
	"io"
	"log"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func withArgs(args []string, fn func()) {
	old := os.Args
	os.Args = args
	defer func() { os.Args = old }()
	fn()
}

func TestEnvOrDefault_Set(t *testing.T) {
	t.Setenv("ARGUS_TEST_KEY_SET", "custom")
	if got := envOrDefault("ARGUS_TEST_KEY_SET", "fallback"); got != "custom" {
		t.Fatalf("envOrDefault() = %q, want %q", got, "custom")
	}
}

func TestEnvOrDefault_Unset(t *testing.T) {
	if got := envOrDefault("ARGUS_TEST_KEY_NEVER_SET", "fallback"); got != "fallback" {
		t.Fatalf("envOrDefault() = %q, want %q", got, "fallback")
	}
}

func TestRunOnceSucceeds(t *testing.T) {
	bc := filepath.Join(t.TempDir(), "bc.json")
	withArgs([]string{"argus", "--once", "--dry-run", "--health-addr=", "--breadcrumb-file=" + bc}, func() {
		if err := run(context.Background(), log.New(io.Discard, "", 0)); err != nil {
			t.Fatalf("run() error = %v", err)
		}
	})
}

func TestRunOnceWithHealthServer(t *testing.T) {
	bc := filepath.Join(t.TempDir(), "bc.json")
	withArgs([]string{"argus", "--once", "--dry-run", "--health-addr=127.0.0.1:0", "--breadcrumb-file=" + bc}, func() {
		if err := run(context.Background(), log.New(io.Discard, "", 0)); err != nil {
			t.Fatalf("run() error = %v", err)
		}
	})
}

func TestRunHelpExitsCleanly(t *testing.T) {
	withArgs([]string{"argus", "--help"}, func() {
		if err := run(context.Background(), log.New(io.Discard, "", 0)); !errors.Is(err, errHelpRequested) {
			t.Fatalf("run(--help) error = %v, want errHelpRequested", err)
		}
	})
}

func TestRunInvalidFlagErrors(t *testing.T) {
	withArgs([]string{"argus", "--nonexistent-flag"}, func() {
		err := run(context.Background(), log.New(io.Discard, "", 0))
		if err == nil {
			t.Fatal("run() should fail with invalid flag")
		}
		if !strings.Contains(err.Error(), "invalid arguments") {
			t.Fatalf("unexpected error: %v", err)
		}
	})
}

func TestRunFailsOnEmptyBreadcrumb(t *testing.T) {
	withArgs([]string{"argus", "--once", "--health-addr=", "--breadcrumb-file="}, func() {
		err := run(context.Background(), log.New(io.Discard, "", 0))
		if err == nil {
			t.Fatal("run() should fail with empty breadcrumb path")
		}
		if !strings.Contains(err.Error(), "watchdog init failed") {
			t.Fatalf("unexpected error: %v", err)
		}
	})
}
