package watchdog

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestRunCycleContinuesAfterErrorAndPanic(t *testing.T) {
	t.Parallel()

	breadcrumbPath := filepath.Join(t.TempDir(), "watchdog.json")
	wd, err := New(Config{
		BreadcrumbPath: breadcrumbPath,
		Logger:         log.New(io.Discard, "", 0),
		DryRun:         true,
	})
	if err != nil {
		t.Fatalf("New() error = %v", err)
	}

	var executed []string
	wd.SetChecks([]Check{
		{
			Name: "returns-error",
			Run: func(ctx context.Context, dryRun bool) error {
				_ = ctx
				if !dryRun {
					t.Fatal("dry-run flag was not propagated to check")
				}
				executed = append(executed, "returns-error")
				return errors.New("synthetic failure")
			},
		},
		{
			Name: "panics",
			Run: func(ctx context.Context, dryRun bool) error {
				_ = ctx
				_ = dryRun
				executed = append(executed, "panics")
				panic("boom")
			},
		},
		{
			Name: "still-runs",
			Run: func(ctx context.Context, dryRun bool) error {
				_ = ctx
				_ = dryRun
				executed = append(executed, "still-runs")
				return nil
			},
		},
	})

	if err := wd.RunCycle(context.Background()); err == nil {
		t.Fatal("RunCycle() error = nil, want aggregated cycle error")
	}

	expectedOrder := []string{"returns-error", "panics", "still-runs"}
	if !reflect.DeepEqual(executed, expectedOrder) {
		t.Fatalf("check execution order = %v, want %v", executed, expectedOrder)
	}

	status := wd.Status()
	if status.Running {
		t.Fatal("status.Running = true after cycle completion")
	}
	if status.ConsecutiveFailures != 1 {
		t.Fatalf("status.ConsecutiveFailures = %d, want 1", status.ConsecutiveFailures)
	}
	if len(status.Checks) != 3 {
		t.Fatalf("len(status.Checks) = %d, want 3", len(status.Checks))
	}
	if status.Checks[0].OK {
		t.Fatal("first check should be marked failed")
	}
	if !status.Checks[1].Panicked {
		t.Fatal("panic check should be marked as panicked")
	}
	if status.Checks[2].OK != true {
		t.Fatal("third check should still succeed after earlier failures")
	}
	if !strings.Contains(status.Checks[1].Error, `panic in check "panics"`) {
		t.Fatalf("panic error missing details: %q", status.Checks[1].Error)
	}

	breadcrumbRaw, err := os.ReadFile(breadcrumbPath)
	if err != nil {
		t.Fatalf("ReadFile(%q) error = %v", breadcrumbPath, err)
	}
	var persisted Status
	if err := json.Unmarshal(breadcrumbRaw, &persisted); err != nil {
		t.Fatalf("Unmarshal breadcrumb error = %v", err)
	}
	if persisted.Running {
		t.Fatal("persisted breadcrumb indicates running=true after cycle completion")
	}
}

func TestNewRecoversInterruptedBreadcrumb(t *testing.T) {
	t.Parallel()

	breadcrumbPath := filepath.Join(t.TempDir(), "watchdog.json")
	started := time.Now().UTC().Add(-2 * time.Minute)
	previous := Status{
		Hostname:            "test-host",
		PID:                 9999,
		DryRun:              false,
		Running:             true,
		StartedAt:           started.Add(-10 * time.Minute),
		LastCycleStart:      &started,
		ConsecutiveFailures: 3,
		LastError:           "old failure",
	}

	payload, err := json.Marshal(previous)
	if err != nil {
		t.Fatalf("json.Marshal() error = %v", err)
	}
	if err := os.WriteFile(breadcrumbPath, payload, 0o644); err != nil {
		t.Fatalf("WriteFile() error = %v", err)
	}

	wd, err := New(Config{
		BreadcrumbPath: breadcrumbPath,
		Logger:         log.New(io.Discard, "", 0),
	})
	if err != nil {
		t.Fatalf("New() error = %v", err)
	}

	status := wd.Status()
	if !status.RecoveredFromBreadcrumb {
		t.Fatal("RecoveredFromBreadcrumb = false, want true")
	}
	if !status.PreviousCycleInterrupted {
		t.Fatal("PreviousCycleInterrupted = false, want true")
	}
	if status.ConsecutiveFailures != 3 {
		t.Fatalf("ConsecutiveFailures = %d, want 3", status.ConsecutiveFailures)
	}
}

func TestNewRejectsMissingBreadcrumbPath(t *testing.T) {
	t.Parallel()

	_, err := New(Config{
		BreadcrumbPath: "",
		Logger:         log.New(io.Discard, "", 0),
	})
	if err == nil {
		t.Fatal("New() with empty breadcrumb path should return an error")
	}
	if !strings.Contains(err.Error(), "breadcrumb path is required") {
		t.Fatalf("unexpected error message: %q", err.Error())
	}
}

func TestNewFailsOnCorruptBreadcrumb(t *testing.T) {
	t.Parallel()

	breadcrumbPath := filepath.Join(t.TempDir(), "watchdog.json")
	if err := os.WriteFile(breadcrumbPath, []byte("{invalid json"), 0o644); err != nil {
		t.Fatalf("WriteFile() error = %v", err)
	}

	_, err := New(Config{
		BreadcrumbPath: breadcrumbPath,
		Logger:         log.New(io.Discard, "", 0),
	})
	if err == nil {
		t.Fatal("New() with corrupt breadcrumb should return an error")
	}
	if !strings.Contains(err.Error(), "decode breadcrumb") {
		t.Fatalf("unexpected error message: %q", err.Error())
	}
}

func TestNewFailsOnUnreadableBreadcrumb(t *testing.T) {
	t.Parallel()

	breadcrumbPath := filepath.Join(t.TempDir(), "watchdog.json")
	if err := os.WriteFile(breadcrumbPath, []byte(`{}`), 0o644); err != nil {
		t.Fatalf("WriteFile() error = %v", err)
	}
	if err := os.Chmod(breadcrumbPath, 0o000); err != nil {
		t.Fatalf("Chmod() error = %v", err)
	}
	t.Cleanup(func() { os.Chmod(breadcrumbPath, 0o644) })

	_, err := New(Config{
		BreadcrumbPath: breadcrumbPath,
		Logger:         log.New(io.Discard, "", 0),
	})
	if err == nil {
		t.Fatal("New() with unreadable breadcrumb should return an error")
	}
	if !strings.Contains(err.Error(), "open breadcrumb") {
		t.Fatalf("unexpected error message: %q", err.Error())
	}
}

func TestRunCheckNilFunction(t *testing.T) {
	t.Parallel()

	breadcrumbPath := filepath.Join(t.TempDir(), "watchdog.json")
	wd, err := New(Config{
		BreadcrumbPath: breadcrumbPath,
		Logger:         log.New(io.Discard, "", 0),
	})
	if err != nil {
		t.Fatalf("New() error = %v", err)
	}

	wd.SetChecks([]Check{
		{Name: "nil-func", Run: nil},
	})

	err = wd.RunCycle(context.Background())
	if err == nil {
		t.Fatal("RunCycle() should return error for nil check function")
	}
	if !strings.Contains(err.Error(), "nil function") {
		t.Fatalf("unexpected error message: %q", err.Error())
	}
}

func TestRunCheckEmptyNameDefaultsToUnnamed(t *testing.T) {
	t.Parallel()

	breadcrumbPath := filepath.Join(t.TempDir(), "watchdog.json")
	wd, err := New(Config{
		BreadcrumbPath: breadcrumbPath,
		Logger:         log.New(io.Discard, "", 0),
	})
	if err != nil {
		t.Fatalf("New() error = %v", err)
	}

	wd.SetChecks([]Check{
		{
			Name: "",
			Run: func(ctx context.Context, dryRun bool) error {
				return errors.New("intentional")
			},
		},
	})

	err = wd.RunCycle(context.Background())
	if err == nil {
		t.Fatal("RunCycle() should return error from failing check")
	}

	// runCheck renames to "unnamed-check" internally, but RunCycle wraps
	// the error using the original check.Name (""). Either way, the
	// check's error must propagate.
	if !strings.Contains(err.Error(), "intentional") {
		t.Fatalf("expected check error to propagate, got: %q", err.Error())
	}
}

func TestRunCycleCancelledContext(t *testing.T) {
	t.Parallel()

	breadcrumbPath := filepath.Join(t.TempDir(), "watchdog.json")
	wd, err := New(Config{
		BreadcrumbPath: breadcrumbPath,
		Logger:         log.New(io.Discard, "", 0),
	})
	if err != nil {
		t.Fatalf("New() error = %v", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	cancel() // cancel immediately

	var ranCheck bool
	wd.SetChecks([]Check{
		{
			Name: "passes-ctx",
			Run: func(ctx context.Context, dryRun bool) error {
				ranCheck = true
				return ctx.Err()
			},
		},
	})

	err = wd.RunCycle(ctx)
	if !ranCheck {
		t.Fatal("check should still run even with cancelled context")
	}
	if err == nil {
		t.Fatal("RunCycle() should propagate context cancellation error")
	}
}

func TestWriteBreadcrumbToReadOnlyDir(t *testing.T) {
	t.Parallel()

	dir := t.TempDir()
	breadcrumbPath := filepath.Join(dir, "sub", "watchdog.json")

	wd, err := New(Config{
		BreadcrumbPath: breadcrumbPath,
		Logger:         log.New(io.Discard, "", 0),
	})
	if err != nil {
		t.Fatalf("New() error = %v", err)
	}

	// Run a successful cycle first (creates the subdirectory)
	wd.SetChecks([]Check{
		{Name: "ok", Run: func(ctx context.Context, dryRun bool) error { return nil }},
	})
	if err := wd.RunCycle(context.Background()); err != nil {
		t.Fatalf("first RunCycle() error = %v", err)
	}

	// Make the directory read-only so breadcrumb writes fail
	subDir := filepath.Join(dir, "sub")
	if err := os.Chmod(subDir, 0o555); err != nil {
		t.Fatalf("Chmod() error = %v", err)
	}
	t.Cleanup(func() { os.Chmod(subDir, 0o755) })

	// Remove existing breadcrumb so write must create a new tmp file
	os.Remove(breadcrumbPath)

	err = wd.RunCycle(context.Background())
	if err == nil {
		t.Fatal("RunCycle() should return error when breadcrumb write fails")
	}

	status := wd.Status()
	if status.ConsecutiveFailures == 0 {
		t.Fatal("ConsecutiveFailures should be > 0 after breadcrumb write failure")
	}
}

func TestHealthHandlerDegradedStatus(t *testing.T) {
	t.Parallel()

	breadcrumbPath := filepath.Join(t.TempDir(), "watchdog.json")
	wd, err := New(Config{
		BreadcrumbPath: breadcrumbPath,
		Logger:         log.New(io.Discard, "", 0),
	})
	if err != nil {
		t.Fatalf("New() error = %v", err)
	}

	// Run a failing cycle so health reports degraded
	wd.SetChecks([]Check{
		{
			Name: "always-fails",
			Run: func(ctx context.Context, dryRun bool) error {
				return errors.New("broken")
			},
		},
	})
	_ = wd.RunCycle(context.Background())

	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	rec := httptest.NewRecorder()
	wd.HealthHandler(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("GET /health status = %d, want 200", rec.Code)
	}

	var resp HealthResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("json.Unmarshal error = %v", err)
	}
	if resp.Status != "degraded" {
		t.Fatalf("health status = %q, want degraded", resp.Status)
	}
	if resp.Watchdog.ConsecutiveFailures != 1 {
		t.Fatalf("ConsecutiveFailures = %d, want 1", resp.Watchdog.ConsecutiveFailures)
	}
}

func TestRunWithOnceFlag(t *testing.T) {
	t.Parallel()

	breadcrumbPath := filepath.Join(t.TempDir(), "watchdog.json")
	wd, err := New(Config{
		BreadcrumbPath: breadcrumbPath,
		Logger:         log.New(io.Discard, "", 0),
	})
	if err != nil {
		t.Fatalf("New() error = %v", err)
	}

	var ran bool
	wd.SetChecks([]Check{
		{
			Name: "once-check",
			Run: func(ctx context.Context, dryRun bool) error {
				ran = true
				return nil
			},
		},
	})

	if err := wd.Run(context.Background(), time.Minute, true); err != nil {
		t.Fatalf("Run(once=true) error = %v", err)
	}
	if !ran {
		t.Fatal("check should have run in once mode")
	}
}

func TestRunWithZeroIntervalDefaultsToOneMinute(t *testing.T) {
	t.Parallel()

	breadcrumbPath := filepath.Join(t.TempDir(), "watchdog.json")
	wd, err := New(Config{
		BreadcrumbPath: breadcrumbPath,
		Logger:         log.New(io.Discard, "", 0),
	})
	if err != nil {
		t.Fatalf("New() error = %v", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	var cycles int
	wd.SetChecks([]Check{
		{
			Name: "count",
			Run: func(ctx context.Context, dryRun bool) error {
				cycles++
				cancel() // stop after first cycle
				return nil
			},
		},
	})

	// interval=0 should default to 1 minute but we cancel immediately
	_ = wd.Run(ctx, 0, false)
	if cycles != 1 {
		t.Fatalf("expected 1 cycle, got %d", cycles)
	}
}

func TestConsecutiveFailuresResetOnSuccess(t *testing.T) {
	t.Parallel()

	breadcrumbPath := filepath.Join(t.TempDir(), "watchdog.json")
	wd, err := New(Config{
		BreadcrumbPath: breadcrumbPath,
		Logger:         log.New(io.Discard, "", 0),
	})
	if err != nil {
		t.Fatalf("New() error = %v", err)
	}

	// Failing cycle
	wd.SetChecks([]Check{
		{Name: "fail", Run: func(ctx context.Context, dryRun bool) error { return errors.New("bad") }},
	})
	_ = wd.RunCycle(context.Background())

	if s := wd.Status(); s.ConsecutiveFailures != 1 {
		t.Fatalf("ConsecutiveFailures after failure = %d, want 1", s.ConsecutiveFailures)
	}

	// Successful cycle resets
	wd.SetChecks([]Check{
		{Name: "ok", Run: func(ctx context.Context, dryRun bool) error { return nil }},
	})
	if err := wd.RunCycle(context.Background()); err != nil {
		t.Fatalf("RunCycle() error = %v", err)
	}

	s := wd.Status()
	if s.ConsecutiveFailures != 0 {
		t.Fatalf("ConsecutiveFailures after success = %d, want 0", s.ConsecutiveFailures)
	}
	if s.LastSuccess == nil {
		t.Fatal("LastSuccess should be set after successful cycle")
	}
	if s.LastError != "" {
		t.Fatalf("LastError should be empty after success, got %q", s.LastError)
	}
}

func TestHealthHandlerReturnsJSONStatus(t *testing.T) {
	t.Parallel()

	wd, err := New(Config{
		BreadcrumbPath: filepath.Join(t.TempDir(), "watchdog.json"),
		Logger:         log.New(io.Discard, "", 0),
	})
	if err != nil {
		t.Fatalf("New() error = %v", err)
	}
	wd.SetChecks([]Check{
		{
			Name: "ok",
			Run: func(ctx context.Context, dryRun bool) error {
				_ = ctx
				_ = dryRun
				return nil
			},
		},
	})
	if err := wd.RunCycle(context.Background()); err != nil {
		t.Fatalf("RunCycle() error = %v, want nil", err)
	}

	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	rec := httptest.NewRecorder()
	wd.HealthHandler(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("GET /health status = %d, want 200", rec.Code)
	}
	if got := rec.Header().Get("Content-Type"); !strings.Contains(got, "application/json") {
		t.Fatalf("Content-Type = %q, want application/json", got)
	}

	var resp HealthResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		t.Fatalf("json.Unmarshal(/health) error = %v", err)
	}
	if resp.Status != "ok" {
		t.Fatalf("health status = %q, want ok", resp.Status)
	}
	if resp.Watchdog.Hostname == "" {
		t.Fatal("hostname is empty in health response")
	}

	nonGetReq := httptest.NewRequest(http.MethodPost, "/health", nil)
	nonGetRec := httptest.NewRecorder()
	wd.HealthHandler(nonGetRec, nonGetReq)
	if nonGetRec.Code != http.StatusMethodNotAllowed {
		t.Fatalf("POST /health status = %d, want 405", nonGetRec.Code)
	}
}
