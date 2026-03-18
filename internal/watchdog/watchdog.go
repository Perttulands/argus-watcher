package watchdog

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime/debug"
	"strings"
	"sync"
	"time"
)

type CheckFunc func(ctx context.Context, dryRun bool) error

type Check struct {
	Name string
	Run  CheckFunc
}

type CheckStatus struct {
	Name       string    `json:"name"`
	OK         bool      `json:"ok"`
	Panicked   bool      `json:"panicked"`
	Error      string    `json:"error,omitempty"`
	StartedAt  time.Time `json:"started_at"`
	FinishedAt time.Time `json:"finished_at"`
}

type Status struct {
	Hostname                 string        `json:"hostname"`
	PID                      int           `json:"pid"`
	DryRun                   bool          `json:"dry_run"`
	Running                  bool          `json:"running"`
	StartedAt                time.Time     `json:"started_at"`
	LastCycleStart           *time.Time    `json:"last_cycle_start,omitempty"`
	LastCycleEnd             *time.Time    `json:"last_cycle_end,omitempty"`
	LastSuccess              *time.Time    `json:"last_success,omitempty"`
	ConsecutiveFailures      int           `json:"consecutive_failures"`
	RecoveredFromBreadcrumb  bool          `json:"recovered_from_breadcrumb"`
	PreviousCycleInterrupted bool          `json:"previous_cycle_interrupted"`
	LastError                string        `json:"last_error,omitempty"`
	Checks                   []CheckStatus `json:"checks"`
}

type Config struct {
	BreadcrumbPath string
	Logger         *log.Logger
	DryRun         bool
	Hostname       string
	Clock          func() time.Time
}

type HealthResponse struct {
	Status   string `json:"status"`
	Watchdog Status `json:"watchdog"`
}

type Watchdog struct {
	mu             sync.RWMutex
	logger         *log.Logger
	clock          func() time.Time
	breadcrumbPath string
	dryRun         bool
	checks         []Check
	state          Status
}

type panicError struct {
	checkName string
	panicVal  any
}

func (e *panicError) Error() string {
	return fmt.Sprintf("panic in check %q: %v", e.checkName, e.panicVal)
}

func New(cfg Config) (*Watchdog, error) {
	if cfg.BreadcrumbPath == "" {
		return nil, errors.New("breadcrumb path is required")
	}
	if cfg.Logger == nil {
		cfg.Logger = log.New(os.Stdout, "", log.LstdFlags|log.LUTC)
	}
	if cfg.Clock == nil {
		cfg.Clock = time.Now
	}
	hostname := cfg.Hostname
	if hostname == "" {
		resolved, err := os.Hostname()
		if err != nil {
			return nil, fmt.Errorf("resolve hostname: %w", err)
		}
		hostname = resolved
	}

	now := cfg.Clock().UTC()
	w := &Watchdog{
		logger:         cfg.Logger,
		clock:          cfg.Clock,
		breadcrumbPath: cfg.BreadcrumbPath,
		dryRun:         cfg.DryRun,
		state: Status{
			Hostname:  hostname,
			PID:       os.Getpid(),
			DryRun:    cfg.DryRun,
			StartedAt: now,
		},
	}

	if err := w.loadBreadcrumb(); err != nil {
		return nil, fmt.Errorf("load breadcrumb: %w", err)
	}
	return w, nil
}

func (w *Watchdog) SetChecks(checks []Check) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.checks = append([]Check(nil), checks...)
}

func (w *Watchdog) AddCheck(check Check) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.checks = append(w.checks, check)
}

func (w *Watchdog) Run(ctx context.Context, interval time.Duration, once bool) error {
	if interval <= 0 {
		interval = time.Minute
	}

	if once {
		return w.RunCycle(ctx)
	}

	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	var runErr error

	for {
		if err := w.RunCycle(ctx); err != nil {
			runErr = errors.Join(runErr, err)
		}
		select {
		case <-ctx.Done():
			return runErr
		case <-ticker.C:
		}
	}
}

func (w *Watchdog) RunCycle(ctx context.Context) error {
	start := w.clock().UTC()
	var priorLastSuccess *time.Time
	var priorConsecutiveFailures int
	w.mu.Lock()
	priorLastSuccess = cloneTimePtr(w.state.LastSuccess)
	priorConsecutiveFailures = w.state.ConsecutiveFailures
	w.state.Running = true
	w.state.LastCycleStart = cloneTimePtr(&start)
	w.state.Checks = nil
	w.mu.Unlock()

	var cycleErr error
	failureReasons := make([]string, 0)
	startWriteErr := w.writeBreadcrumb()
	if startWriteErr != nil {
		msg := fmt.Sprintf("failed to write start breadcrumb: %v", startWriteErr)
		failureReasons = append(failureReasons, msg)
		cycleErr = errors.Join(cycleErr, fmt.Errorf("write start breadcrumb: %w", startWriteErr))
	}

	checks := w.snapshotChecks()
	results := make([]CheckStatus, 0, len(checks))
	checkFailures := 0

	for _, check := range checks {
		result := CheckStatus{
			Name:      check.Name,
			StartedAt: w.clock().UTC(),
		}
		checkErr := w.runCheck(ctx, check)
		if checkErr != nil {
			checkFailures++
			result.Error = checkErr.Error()
			failureReasons = append(failureReasons, fmt.Sprintf("check %q failed: %v", check.Name, checkErr))
			cycleErr = errors.Join(cycleErr, fmt.Errorf("check %q: %w", check.Name, checkErr))
			var panicErr *panicError
			if errors.As(checkErr, &panicErr) {
				result.Panicked = true
			}
		} else {
			result.OK = true
		}
		result.FinishedAt = w.clock().UTC()
		results = append(results, result)
	}

	end := w.clock().UTC()
	hadFailuresBeforeEnd := len(failureReasons) > 0 || checkFailures > 0
	w.mu.Lock()
	w.state.Running = false
	w.state.LastCycleEnd = cloneTimePtr(&end)
	w.state.Checks = results
	if !hadFailuresBeforeEnd {
		w.state.LastSuccess = cloneTimePtr(&end)
		w.state.ConsecutiveFailures = 0
		w.state.LastError = ""
		w.state.PreviousCycleInterrupted = false
	} else {
		w.state.ConsecutiveFailures++
		if len(failureReasons) == 0 {
			w.state.LastError = fmt.Sprintf("%d check(s) failed in last cycle", checkFailures)
		} else {
			w.state.LastError = strings.Join(failureReasons, "; ")
		}
	}
	w.mu.Unlock()

	endWriteErr := w.writeBreadcrumb()
	if endWriteErr != nil {
		msg := fmt.Sprintf("failed to write end breadcrumb: %v", endWriteErr)
		cycleErr = errors.Join(cycleErr, fmt.Errorf("write end breadcrumb: %w", endWriteErr))
		w.mu.Lock()
		if !hadFailuresBeforeEnd {
			w.state.LastSuccess = priorLastSuccess
			w.state.ConsecutiveFailures = priorConsecutiveFailures + 1
			w.state.LastError = msg
		} else {
			if w.state.LastError == "" {
				w.state.LastError = msg
			} else {
				w.state.LastError += "; " + msg
			}
		}
		w.mu.Unlock()
	}

	state := w.Status()
	if shouldPublishAlert(priorConsecutiveFailures, state.ConsecutiveFailures) {
		w.publishCycleAlert(results, state.LastError, end)
	}

	return cycleErr
}

func (w *Watchdog) HealthHandler(rw http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodGet {
		rw.Header().Set("Allow", http.MethodGet)
		http.Error(rw, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	requestID := strings.TrimSpace(req.Header.Get("X-Request-ID"))
	if requestID == "" {
		requestID = fmt.Sprintf("req-%d", w.clock().UTC().UnixNano())
	}
	rw.Header().Set("X-Request-ID", requestID)

	s := w.Status()
	overall := "ok"
	if s.PreviousCycleInterrupted || s.ConsecutiveFailures > 0 {
		overall = "degraded"
	}
	payload := HealthResponse{
		Status:   overall,
		Watchdog: s,
	}

	rw.Header().Set("Content-Type", "application/json")
	encodedPayload, err := json.Marshal(payload)
	if err != nil {
		http.Error(rw, "internal server error", http.StatusInternalServerError)
		return
	}
	if _, writeErr := rw.Write(encodedPayload); writeErr != nil {
		return
	}
}

func (w *Watchdog) Status() Status {
	w.mu.RLock()
	defer w.mu.RUnlock()
	return cloneStatus(w.state)
}

func (w *Watchdog) runCheck(ctx context.Context, check Check) (err error) {
	if check.Name == "" {
		check.Name = "unnamed-check"
	}
	if check.Run == nil {
		return fmt.Errorf("check %q has nil function", check.Name)
	}

	defer func() {
		if recovered := recover(); recovered != nil {
			w.logger.Printf("panic recovered in check %q: %v\n%s", check.Name, recovered, string(debug.Stack()))
			err = &panicError{checkName: check.Name, panicVal: recovered}
		}
	}()

	return check.Run(ctx, w.dryRun)
}

func (w *Watchdog) loadBreadcrumb() error {
	f, err := os.Open(w.breadcrumbPath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return fmt.Errorf("open breadcrumb %q: %w", w.breadcrumbPath, err)
	}
	defer f.Close()

	var prev Status
	if err := json.NewDecoder(f).Decode(&prev); err != nil {
		return fmt.Errorf("decode breadcrumb %q: %w", w.breadcrumbPath, err)
	}

	w.mu.Lock()
	defer w.mu.Unlock()
	w.state.RecoveredFromBreadcrumb = true
	w.state.LastCycleStart = cloneTimePtr(prev.LastCycleStart)
	w.state.LastCycleEnd = cloneTimePtr(prev.LastCycleEnd)
	w.state.LastSuccess = cloneTimePtr(prev.LastSuccess)
	w.state.ConsecutiveFailures = prev.ConsecutiveFailures
	w.state.LastError = prev.LastError
	w.state.Checks = append([]CheckStatus(nil), prev.Checks...)
	if prev.Running {
		w.state.PreviousCycleInterrupted = true
		w.state.LastError = "previous process stopped during a running cycle"
	}
	return nil
}

func (w *Watchdog) writeBreadcrumb() error {
	s := w.Status()

	dir := filepath.Dir(w.breadcrumbPath)
	if dir != "." {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return fmt.Errorf("create breadcrumb directory %q: %w", dir, err)
		}
	}

	tmpFile := w.breadcrumbPath + ".tmp"
	f, err := os.Create(tmpFile)
	if err != nil {
		return fmt.Errorf("create temp breadcrumb %q: %w", tmpFile, err)
	}

	enc := json.NewEncoder(f)
	enc.SetIndent("", "  ")
	if err := enc.Encode(s); err != nil {
		closeErr := f.Close()
		wrappedErr := fmt.Errorf("encode breadcrumb %q: %w", tmpFile, err)
		if closeErr != nil {
			wrappedErr = errors.Join(wrappedErr, fmt.Errorf("close temp breadcrumb %q: %w", tmpFile, closeErr))
		}
		return cleanupTempFile(tmpFile, wrappedErr)
	}

	if err := f.Close(); err != nil {
		return cleanupTempFile(tmpFile, fmt.Errorf("close temp breadcrumb %q: %w", tmpFile, err))
	}

	if err := os.Rename(tmpFile, w.breadcrumbPath); err != nil {
		return cleanupTempFile(tmpFile, fmt.Errorf("replace breadcrumb %q: %w", w.breadcrumbPath, err))
	}
	return nil
}

func cleanupTempFile(tmpFile string, originalErr error) error {
	if err := os.Remove(tmpFile); err != nil && !errors.Is(err, os.ErrNotExist) {
		return errors.Join(originalErr, fmt.Errorf("remove temp breadcrumb %q: %w", tmpFile, err))
	}
	return originalErr
}

func (w *Watchdog) snapshotChecks() []Check {
	w.mu.RLock()
	defer w.mu.RUnlock()
	return append([]Check(nil), w.checks...)
}

func cloneStatus(in Status) Status {
	out := in
	out.LastCycleStart = cloneTimePtr(in.LastCycleStart)
	out.LastCycleEnd = cloneTimePtr(in.LastCycleEnd)
	out.LastSuccess = cloneTimePtr(in.LastSuccess)
	out.Checks = append([]CheckStatus(nil), in.Checks...)
	return out
}

func cloneTimePtr(t *time.Time) *time.Time {
	if t == nil {
		return nil
	}
	copyVal := *t
	return &copyVal
}

func shouldPublishAlert(before, after int) bool {
	return before == 0 && after > 0 || after > 0 && after%3 == 0
}

func (w *Watchdog) publishCycleAlert(results []CheckStatus, message string, ts time.Time) {
	checkName := "watchdog"
	for _, result := range results {
		if !result.OK {
			checkName = result.Name
			break
		}
	}
	payload, err := json.Marshal(map[string]any{
		"source":   "argus",
		"check":    checkName,
		"severity": "critical",
		"message":  message,
		"ts":       ts.UTC().Format(time.RFC3339),
	})
	if err != nil {
		return
	}
	go func(body []byte, text string) {
		if script := resolveNotifyScript(); script != "" {
			exec.Command(script, text).Run()
		}
		exec.Command("relay", "send", "--to", "system", "--type", "alert", "--body", string(body)).Run()
	}(payload, message)
}

func resolveNotifyScript() string {
	if exe, err := os.Executable(); err == nil {
		if path := filepath.Join(filepath.Dir(exe), "notify-telegram.sh"); isExecutable(path) {
			return path
		}
	}
	if cwd, err := os.Getwd(); err == nil {
		if path := filepath.Join(cwd, "notify-telegram.sh"); isExecutable(path) {
			return path
		}
	}
	if path, err := exec.LookPath("notify-telegram.sh"); err == nil {
		return path
	}
	return ""
}

func isExecutable(path string) bool {
	info, err := os.Stat(path)
	return err == nil && !info.IsDir() && info.Mode()&0o111 != 0
}
