package main

import (
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

var argusPath string

func TestMain(m *testing.M) {
	tmpDir, err := os.MkdirTemp("", "argus-e2e-*")
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to create temp dir: %v\n", err)
		os.Exit(1)
	}

	argusPath = filepath.Join(tmpDir, "argus")
	cmd := exec.Command("go", "build", "-o", argusPath, ".")
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "failed to build argus: %v\n", err)
		os.RemoveAll(tmpDir)
		os.Exit(1)
	}

	code := m.Run()
	os.RemoveAll(tmpDir)
	os.Exit(code)
}

func TestE2E_Help(t *testing.T) {
	cmd := exec.Command(argusPath, "--help")
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("--help should exit 0, got error: %v\noutput: %s", err, out)
	}
	output := string(out)
	for _, flag := range []string{"breadcrumb-file", "health-addr", "interval", "once", "dry-run"} {
		if !strings.Contains(output, flag) {
			t.Errorf("--help output missing flag %q:\n%s", flag, output)
		}
	}
}

func TestE2E_ValidConfig(t *testing.T) {
	bc := filepath.Join(t.TempDir(), "bc.json")
	cmd := exec.Command(argusPath, "--once", "--dry-run", "--health-addr=", "--breadcrumb-file="+bc)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("valid config should exit 0, got error: %v\noutput: %s", err, out)
	}
	output := string(out)
	if !strings.Contains(output, "dry-run") {
		t.Fatalf("expected dry-run output, got:\n%s", output)
	}
}

func TestE2E_InvalidConfig(t *testing.T) {
	cmd := exec.Command(argusPath, "--once", "--health-addr=", "--breadcrumb-file=")
	out, err := cmd.CombinedOutput()
	if err == nil {
		t.Fatal("empty breadcrumb path should exit non-zero")
	}
	output := string(out)
	if !strings.Contains(output, "watchdog init failed") {
		t.Fatalf("expected init error, got:\n%s", output)
	}
}

func TestE2E_UnknownFlag(t *testing.T) {
	cmd := exec.Command(argusPath, "--bogus-flag")
	out, err := cmd.CombinedOutput()
	if err == nil {
		t.Fatal("unknown flag should exit non-zero")
	}
	if !strings.Contains(string(out), "invalid arguments") {
		t.Fatalf("expected invalid arguments error, got:\n%s", string(out))
	}
}

// TestE2E_HealthEndpointAndSignal exercises the core production workflow:
// argus starts in loop mode, exposes a health endpoint, responds to HTTP
// requests, and shuts down gracefully on SIGTERM. If this test breaks,
// production monitoring and systemd integration are broken.
func TestE2E_HealthEndpointAndSignal(t *testing.T) {
	bc := filepath.Join(t.TempDir(), "bc.json")

	// Find a free port to avoid conflicts.
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("finding free port: %v", err)
	}
	port := ln.Addr().(*net.TCPAddr).Port
	ln.Close()

	addr := fmt.Sprintf("127.0.0.1:%d", port)
	cmd := exec.Command(argusPath,
		"--dry-run",
		"--interval=1h",
		"--health-addr="+addr,
		"--breadcrumb-file="+bc)

	if err := cmd.Start(); err != nil {
		t.Fatalf("start argus: %v", err)
	}

	// Track process lifecycle via a goroutine.
	exited := make(chan struct{})
	go func() {
		cmd.Wait()
		close(exited)
	}()
	t.Cleanup(func() {
		cmd.Process.Kill()
		<-exited
	})

	// Wait for health endpoint to become ready.
	healthURL := fmt.Sprintf("http://%s/health", addr)
	var ready bool
	for i := 0; i < 30; i++ {
		resp, err := http.Get(healthURL)
		if err == nil {
			resp.Body.Close()
			ready = true
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	if !ready {
		t.Fatal("health endpoint not ready after 3s")
	}

	// Verify health endpoint returns valid JSON with expected structure.
	resp, err := http.Get(healthURL)
	if err != nil {
		t.Fatalf("GET /health: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		t.Fatalf("GET /health status = %d, want 200", resp.StatusCode)
	}

	var health map[string]interface{}
	if err := json.NewDecoder(resp.Body).Decode(&health); err != nil {
		t.Fatalf("decode /health response: %v", err)
	}
	if health["status"] != "ok" {
		t.Errorf("health status = %v, want ok", health["status"])
	}
	wd, _ := health["watchdog"].(map[string]interface{})
	if wd == nil {
		t.Fatal("health response missing 'watchdog' object")
	}
	if wd["hostname"] == nil || wd["hostname"] == "" {
		t.Error("health response missing watchdog.hostname")
	}
	if wd["dry_run"] != true {
		t.Error("health response should reflect dry_run=true")
	}

	// Graceful shutdown via SIGTERM — the way systemd stops argus.
	cmd.Process.Signal(syscall.SIGTERM)

	select {
	case <-exited:
		// Clean exit — success.
	case <-time.After(5 * time.Second):
		t.Fatal("argus did not exit within 5s of SIGTERM")
	}
}

// TestE2E_BreadcrumbRecovery exercises the crash-recovery workflow:
// argus runs once (creating a breadcrumb), then a second instance starts
// with the same breadcrumb path and recovers the previous state. This is
// how argus knows if it crashed mid-cycle.
func TestE2E_BreadcrumbRecovery(t *testing.T) {
	bc := filepath.Join(t.TempDir(), "bc.json")

	// First run — creates breadcrumb.
	cmd1 := exec.Command(argusPath, "--once", "--dry-run", "--health-addr=", "--breadcrumb-file="+bc)
	if out, err := cmd1.CombinedOutput(); err != nil {
		t.Fatalf("first run failed: %v\n%s", err, out)
	}

	// Verify breadcrumb exists and has valid structure.
	data, err := os.ReadFile(bc)
	if err != nil {
		t.Fatalf("breadcrumb not created: %v", err)
	}

	var state map[string]interface{}
	if err := json.Unmarshal(data, &state); err != nil {
		t.Fatalf("breadcrumb is not valid JSON: %v", err)
	}
	if state["hostname"] == nil {
		t.Fatal("breadcrumb missing hostname")
	}
	if state["running"] != false {
		t.Fatal("breadcrumb should have running=false after clean exit")
	}

	// Second run — recovers from breadcrumb.
	cmd2 := exec.Command(argusPath, "--once", "--dry-run", "--health-addr=", "--breadcrumb-file="+bc)
	out2, err := cmd2.CombinedOutput()
	if err != nil {
		t.Fatalf("second run (recovery) failed: %v\n%s", err, out2)
	}

	// Verify breadcrumb was updated (PID should change).
	data2, err := os.ReadFile(bc)
	if err != nil {
		t.Fatalf("breadcrumb not updated after second run: %v", err)
	}
	var state2 map[string]interface{}
	if err := json.Unmarshal(data2, &state2); err != nil {
		t.Fatalf("updated breadcrumb is not valid JSON: %v", err)
	}

	// The PID must differ between runs (confirms second process wrote it).
	pid1, _ := state["pid"].(float64)
	pid2, _ := state2["pid"].(float64)
	if pid1 == pid2 {
		t.Errorf("breadcrumb PID unchanged (%v) — second run may not have written it", pid1)
	}
}
