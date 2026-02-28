# Argus Test Suite — Quality Assessment

Scored against the Polis Test Quality Rubric (5 dimensions, 0–5 each, max 25).

## Rubric Scores

| Dimension | Before | After | Delta |
|-----------|--------|-------|-------|
| E2E Realism | 2 | 4 | +2 |
| Unit Test Behaviour Focus | 3 | 4 | +1 |
| Edge Case & Error Path | 3 | 3 | 0 |
| Test Isolation & Reliability | 3 | 3 | 0 |
| Regression Value | 3 | 4 | +1 |
| **Total** | **14 (C)** | **18 (B)** | **+4** |

## Assessment by Dimension

### 1. E2E Realism — 4/5

Six E2E tests cover the three core workflows: single-cycle execution (--once --dry-run),
health endpoint accessibility + SIGTERM graceful shutdown, and breadcrumb recovery across
process restarts. Error paths (invalid config, unknown flags) are also covered. Missing:
concurrent load on /health during an active cycle, and running without --dry-run with real
check implementations.

### 2. Unit Test Behaviour Focus — 4/5

All unit tests target observable behaviour through the public API (New, RunCycle, Run,
HealthHandler, Status). No tests reach into private struct fields or test internal helpers
directly. Each test name describes a user-visible property. Removed 9 coverage-padding
tests that tested internals (cleanupTempFile, private state mutation, fake ResponseWriter).

### 3. Edge Case & Error Path — 3/5

Good coverage of init-time errors (corrupt/unreadable/missing breadcrumb, empty config),
runtime errors (panicking checks, nil functions, cancelled context), and persistence
failures (read-only directory). Missing: slow check with context timeout, check that
modifies its own watchdog state, extremely large breadcrumb file, breadcrumb format
evolution (old version writes, new version reads).

### 4. Test Isolation & Reliability — 3/5

Watchdog tests are fully parallel with isolated temp dirs and no shared state. E2E tests
use temp dirs and discover free ports dynamically. The health+signal E2E test has a
theoretical port TOCTOU race but is reliable in practice. The cmd/argus unit tests
mutate global os.Args via withArgs(), preventing parallelism — this is the main weakness,
caused by flag.Parse reading os.Args.

### 5. Regression Value — 4/5

The test suite would catch: broken startup/shutdown, health endpoint returning wrong
status, corrupted breadcrumb persistence, failure counter not accumulating, crash recovery
not detecting interrupted cycles, panic killing the check pipeline, and SIGTERM not
triggering graceful exit. Hard to break anything meaningful without a test failing. Missing:
monitoring JSON schema drift (field renames would break external consumers but not tests).

## What the Suite is MISSING

These are the gaps that would push the score higher:

1. **Concurrent health requests during an active cycle.** The Watchdog uses RWMutex
   protection, but no test verifies it under contention. A race detector test with
   parallel health checks + RunCycle would catch data races.

2. **Slow check with context timeout.** No test verifies what happens when a check
   takes longer than the watchdog interval. The current code doesn't enforce per-check
   timeouts — is that by design?

3. **Breadcrumb schema evolution.** If a new field is added to Status, old breadcrumbs
   (written by a previous version) would decode with zero values. No test verifies that
   argus handles partially-populated breadcrumbs gracefully.

4. **Health endpoint JSON schema contract test.** The health endpoint is consumed by
   external monitoring. If a JSON tag changes (e.g., `last_error` → `lastError`),
   no test catches the break. A golden-file or snapshot test would help.

5. **Real check integration.** All tests use stub checks. The actual production checks
   (collect-metrics, execute-actions) are untested wiring in main.go.

## Test Inventory

### cmd/argus (13 tests)

**E2E (6 tests — exec.Command against compiled binary):**
- TestE2E_Help — --help exits 0 with all flag names
- TestE2E_ValidConfig — --once --dry-run produces expected output
- TestE2E_InvalidConfig — empty breadcrumb exits non-zero with clear error
- TestE2E_UnknownFlag — bogus flag exits non-zero with error
- TestE2E_HealthEndpointAndSignal — health endpoint responds, SIGTERM exits cleanly
- TestE2E_BreadcrumbRecovery — breadcrumb persists across restarts, PID updates

**Unit (7 tests — run() and envOrDefault):**
- TestEnvOrDefault_Set/Unset — ARGUS_HEALTH_ADDR env var mechanism
- TestRunOnceSucceeds — run() with --once --dry-run
- TestRunOnceWithHealthServer — run() with health server on random port
- TestRunHelpExitsCleanly — --help returns nil (not os.Exit)
- TestRunInvalidFlagErrors — unknown flag returns wrapped error
- TestRunFailsOnEmptyBreadcrumb — empty breadcrumb returns init error

### internal/watchdog (17 tests)

**Core behaviour (7 tests):**
- TestRunCycleContinuesAfterErrorAndPanic — panic doesn't kill pipeline
- TestConsecutiveFailuresResetOnSuccess — failure counter state machine
- TestMultipleConsecutiveFailures — failure accumulation across 3 cycles
- TestRunWithOnceFlag — once mode runs exactly one cycle
- TestRunWithZeroIntervalDefaultsToOneMinute — interval default
- TestRunLoopAccumulatesErrors — loop mode error propagation
- TestRunCycleCancelledContext — cancelled ctx propagates to checks

**Health endpoint (3 tests):**
- TestHealthHandlerReturnsJSONStatus — ok status, JSON contract, POST rejected
- TestHealthHandlerDegradedStatus — degraded after check failure
- TestHealthDegradedAfterInterruption — degraded after crash recovery, clears on success

**Persistence (4 tests):**
- TestNewRecoversInterruptedBreadcrumb — crash recovery from Running=true
- TestBreadcrumbContractAfterSuccessfulCycle — breadcrumb JSON field verification
- TestWriteBreadcrumbToReadOnlyDir — breadcrumb write failure handling
- TestNewFailsOnCorruptBreadcrumb — malformed JSON rejected

**Init validation (3 tests):**
- TestNewRejectsMissingBreadcrumbPath — empty config rejected
- TestNewFailsOnUnreadableBreadcrumb — permission error handled
- TestRunCheckNilFunction — nil check function returns clear error

## Changelog

### 2026-02-28 — Agent: hephaestus

- Added: TestE2E_HealthEndpointAndSignal — verifies the core production workflow
  (health endpoint reachable, SIGTERM graceful shutdown). Catches systemd integration
  regressions.
- Added: TestE2E_BreadcrumbRecovery — verifies breadcrumb persistence across process
  restarts. Catches crash-recovery regressions.
- Added: TestHealthDegradedAfterInterruption — verifies health reports "degraded" after
  unclean restart and recovers after a successful cycle. Catches monitoring blind spots.
- Added: TestMultipleConsecutiveFailures — verifies failure counter accumulates correctly
  across 3 consecutive failing cycles. Catches alert escalation bugs.
- Added: TestBreadcrumbContractAfterSuccessfulCycle — verifies breadcrumb JSON contains
  all fields a recovering process depends on. Catches serialization regressions.
- Removed: 9 coverage-padding tests that tested internal helpers (cleanupTempFile x3),
  mutated private struct fields (writeBreadcrumb MkdirAll/Rename errors), used unrealistic
  fakes (failWriter), or verified trivial behaviour (AddCheck, default logger, empty name
  rename). These would not catch real bugs in a Polis workflow.
- Changed: Refactored run() to use local flag.FlagSet (from previous session) enabling
  --help to exit 0 cleanly and making unit tests possible without global flag state.
- Coverage delta: 90.3% → 86.3% overall (intentional: removed 9 junk tests, added 5 that
  matter). Coverage dropped because the removed tests hit internal error paths artificially.
