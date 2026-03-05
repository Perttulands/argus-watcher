package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/Perttulands/argus-watcher/internal/watchdog"
)

var errHelpRequested = errors.New("help requested")

func envOrDefault(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func main() {
	logger := log.New(os.Stdout, "argus: ", log.LstdFlags|log.LUTC)
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	runErr := run(ctx, logger)
	if runErr == nil || errors.Is(runErr, errHelpRequested) {
		return
	}
	panic(fmt.Errorf("fatal error: %w", runErr))
}

func run(ctx context.Context, logger *log.Logger) (runErr error) {
	fs := flag.NewFlagSet("argus", flag.ContinueOnError)
	var (
		breadcrumbPath = fs.String("breadcrumb-file", "logs/watchdog.breadcrumb.json", "breadcrumb state file path")
		healthAddr     = fs.String("health-addr", envOrDefault("ARGUS_HEALTH_ADDR", ":8080"), "health server bind address (empty disables server)")
		interval       = fs.Duration("interval", 5*time.Minute, "watchdog interval")
		once           = fs.Bool("once", false, "run one cycle and exit")
		dryRun         = fs.Bool("dry-run", false, "log intended actions without executing them")
	)
	if err := fs.Parse(os.Args[1:]); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return errHelpRequested
		}
		return fmt.Errorf("invalid arguments: %w", err)
	}

	wd, err := watchdog.New(watchdog.Config{
		BreadcrumbPath: *breadcrumbPath,
		Logger:         logger,
		DryRun:         *dryRun,
	})
	if err != nil {
		return fmt.Errorf("watchdog init failed: %w", err)
	}

	wd.SetChecks([]watchdog.Check{
		{
			Name: "collect-metrics",
			Run: func(ctx context.Context, dryRun bool) error {
				_ = ctx
				if dryRun {
					logger.Printf("dry-run: would collect metrics and evaluate actions")
				}
				return nil
			},
		},
		{
			Name: "execute-actions",
			Run: func(ctx context.Context, dryRun bool) error {
				_ = ctx
				if dryRun {
					logger.Printf("dry-run: action execution skipped")
					return nil
				}
				// Action execution hook for production integrations.
				return nil
			},
		},
	})

	var srv *http.Server
	var srvErrCh chan error
	if *healthAddr != "" {
		mux := http.NewServeMux()
		mux.HandleFunc("/health", wd.HealthHandler)
		srv = &http.Server{
			Addr:              *healthAddr,
			Handler:           mux,
			ReadHeaderTimeout: 2 * time.Second,
		}
		srvErrCh = make(chan error, 1)
		go func(ctx context.Context) {
			_ = ctx
			logger.Printf("health endpoint listening on %s", *healthAddr)
			if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
				srvErrCh <- err
			}
			close(srvErrCh)
		}(ctx)
	}

	defer func() {
		if srv == nil {
			return
		}
		shutdownCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 3*time.Second)
		defer cancel()
		if err := srv.Shutdown(shutdownCtx); err != nil && !errors.Is(err, http.ErrServerClosed) {
			runErr = errors.Join(runErr, fmt.Errorf("health server shutdown failed: %w", err))
		}
		if srvErrCh != nil {
			if err, ok := <-srvErrCh; ok && err != nil {
				runErr = errors.Join(runErr, fmt.Errorf("health server stopped with error: %w", err))
			}
		}
	}()

	if err := wd.Run(ctx, *interval, *once); err != nil {
		runErr = errors.Join(runErr, fmt.Errorf("watchdog run failed: %w", err))
		return runErr
	}

	return runErr
}
