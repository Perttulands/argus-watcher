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

	"github.com/perttu/argus/internal/watchdog"
)

func envOrDefault(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func main() {
	logger := log.New(os.Stdout, "argus: ", log.LstdFlags|log.LUTC)
	if err := run(logger); err != nil {
		logger.Printf("fatal error: %v", err)
		os.Exit(1)
	}
}

func run(logger *log.Logger) error {
	var (
		breadcrumbPath = flag.String("breadcrumb-file", "logs/watchdog.breadcrumb.json", "breadcrumb state file path")
		healthAddr     = flag.String("health-addr", envOrDefault("ARGUS_HEALTH_ADDR", ":8080"), "health server bind address (empty disables server)")
		interval       = flag.Duration("interval", 5*time.Minute, "watchdog interval")
		once           = flag.Bool("once", false, "run one cycle and exit")
		dryRun         = flag.Bool("dry-run", false, "log intended actions without executing them")
	)
	flag.Parse()

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

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	var srv *http.Server
	if *healthAddr != "" {
		mux := http.NewServeMux()
		mux.HandleFunc("/health", wd.HealthHandler)
		srv = &http.Server{
			Addr:              *healthAddr,
			Handler:           mux,
			ReadHeaderTimeout: 2 * time.Second,
		}
		go func() {
			logger.Printf("health endpoint listening on %s", *healthAddr)
			if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
				logger.Printf("health server stopped with error: %v", err)
			}
		}()
	}

	var runErr error
	if err := wd.Run(ctx, *interval, *once); err != nil {
		runErr = errors.Join(runErr, fmt.Errorf("watchdog run failed: %w", err))
	}

	if srv != nil {
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		if err := srv.Shutdown(shutdownCtx); err != nil {
			runErr = errors.Join(runErr, fmt.Errorf("health server shutdown failed: %w", err))
		}
	}

	return runErr
}
