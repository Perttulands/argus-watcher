#!/usr/bin/env bash
set -euo pipefail
trap 'echo "ERROR: collectors.sh failed at line $LINENO" >&2' ERR

# collectors.sh — metric collection functions for Argus
#
# Each collector is wrapped to never fail fatally (set -e safe).
# A failing collector outputs an error line but does not abort the cycle.
# Collectors should output clear, parseable data with actual values
# so the LLM can make good decisions.

collect_memory_hog_context() {
    local indent="${1:-  }"
    if ! command -v ps >/dev/null 2>&1; then # REASON: some minimal environments may not include procps.
        echo "${indent}Top memory hog: unavailable (ps command missing)"
        return 0
    fi

    local top_line
    top_line=$(ps -eo pid=,comm=,%mem=,rss=,etime= --sort=-rss 2>/dev/null | awk 'NR==1{print $1 "|" $2 "|" $3 "|" $4 "|" $5}') || true # REASON: transient ps failures should degrade to unavailable output.
    if [[ -z "$top_line" ]]; then
        echo "${indent}Top memory hog: unavailable"
        return 0
    fi

    local pid proc mem_pct rss_kb runtime kill_candidate
    IFS='|' read -r pid proc mem_pct rss_kb runtime <<< "$top_line"
    kill_candidate="no"
    if [[ "$proc" =~ (node|claude|codex) ]]; then
        kill_candidate="yes"
    fi

    local rss_mb=0
    if [[ "$rss_kb" =~ ^[0-9]+$ ]]; then
        rss_mb=$((rss_kb / 1024))
    fi

    echo "${indent}Top memory hog: ${proc} (PID ${pid})"
    echo "${indent}  RSS: ${rss_kb}KB (${rss_mb}MB), %MEM: ${mem_pct}, runtime: ${runtime}"
    echo "${indent}  Kill candidate (allowlist match): ${kill_candidate}"
    if [[ "$kill_candidate" == "yes" ]]; then
        echo "${indent}  Suggested LLM action: kill_pid target=${pid}"
    fi
}

collect_cgroup_memory_context() {
    local indent="${1:-  }"
    local current_file="/sys/fs/cgroup/memory.current"
    local max_file="/sys/fs/cgroup/memory.max"
    if [[ ! -r "$current_file" ]] || [[ ! -r "$max_file" ]]; then
        return 0
    fi

    local current max pct
    current=$(cat "$current_file" 2>/dev/null || echo "") # REASON: cgroup files may disappear during container lifecycle changes.
    max=$(cat "$max_file" 2>/dev/null || echo "") # REASON: cgroup files may disappear during container lifecycle changes.
    [[ "$current" =~ ^[0-9]+$ ]] || return 0

    if [[ "$max" == "max" ]]; then
        echo "${indent}Cgroup memory: current ${current} bytes (no limit)"
        return 0
    fi
    [[ "$max" =~ ^[0-9]+$ ]] || return 0
    if (( max <= 0 )); then
        return 0
    fi
    pct=$(( (current * 100) / max ))
    echo "${indent}Cgroup memory: ${current}/${max} bytes (${pct}%)"
}

collect_services() {
    echo "=== Services ==="

    # openclaw-gateway: check gateway port (configurable via ARGUS_GATEWAY_PORT, default 18505)
    echo -n "openclaw-gateway: "
    local gw_http
    gw_http=$(curl -s -o /dev/null -w '%{http_code}' -m 5 "http://localhost:${ARGUS_GATEWAY_PORT:-18505}/" 2>/dev/null) || gw_http="failed" # REASON: service reachability checks should not abort collection.
    if [[ "$gw_http" == "000" || "$gw_http" == "failed" ]]; then
        echo "DOWN (port ${ARGUS_GATEWAY_PORT:-18505} unreachable)"
    else
        echo "UP (port ${ARGUS_GATEWAY_PORT:-18505}, HTTP $gw_http)"
    fi

    # athena-web removed from monitoring (2026-02-19)
}

collect_system() {
    echo "=== System ==="

    # Memory with parsed percentages for LLM
    echo "Memory:"
    local memory_pct=-1
    if command -v free &>/dev/null; then
        local mem_line
        mem_line=$(free -m 2>/dev/null | grep '^Mem:') || true # REASON: free output can vary across environments; missing line means unavailable metrics.
        if [[ -n "$mem_line" ]]; then
            local total used avail pct
            total=$(echo "$mem_line" | awk '{print $2}')
            used=$(echo "$mem_line" | awk '{print $3}')
            avail=$(echo "$mem_line" | awk '{print $7}')
            if (( total > 0 )); then
                pct=$(( (used * 100) / total ))
                memory_pct=$pct
                echo "  Used: ${used}MB / ${total}MB (${pct}%)"
                echo "  Available: ${avail}MB"
            else
                free -h 2>/dev/null | grep -E '(Mem|Swap)' || echo "  free command failed" # REASON: fallback output is best-effort and may fail on minimal hosts.
            fi
        fi
        # Swap
        local swap_line
        swap_line=$(free -m 2>/dev/null | grep '^Swap:') || true # REASON: swap line may be absent when swap is disabled.
        if [[ -n "$swap_line" ]]; then
            local swap_total swap_used
            swap_total=$(echo "$swap_line" | awk '{print $2}')
            swap_used=$(echo "$swap_line" | awk '{print $3}')
            if (( swap_total > 0 )); then
                local swap_pct=$(( (swap_used * 100) / swap_total ))
                echo "  Swap: ${swap_used}MB / ${swap_total}MB (${swap_pct}%)"
            else
                echo "  Swap: none configured"
            fi
        fi
    else
        echo "  free command not available"
    fi

    collect_cgroup_memory_context "  "
    if (( memory_pct >= 90 )); then
        echo "  Memory pressure: CRITICAL (>=90%)"
        collect_memory_hog_context "  "
    fi

    # Disk with parsed percentage
    echo "Disk (/):"
    if command -v df &>/dev/null; then
        local disk_line
        disk_line=$(df -h / 2>/dev/null | tail -n1) || true # REASON: df failures should not abort the cycle.
        if [[ -n "$disk_line" ]]; then
            echo "  $disk_line"
        else
            echo "  df command failed"
        fi
    fi

    # CPU count (needed for load average interpretation)
    local cpu_count
    cpu_count=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo "unknown") # REASON: cpu core detection has multiple fallbacks and may fail on constrained systems.
    echo "CPU cores: $cpu_count"

    # Load average with context
    echo "Load average:"
    local loadavg
    loadavg=$(cat /proc/loadavg 2>/dev/null || uptime 2>/dev/null || echo "unknown") # REASON: loadavg source files vary by platform/container.
    echo "  $loadavg"

    # Uptime
    echo "Uptime:"
    uptime -p 2>/dev/null || uptime 2>/dev/null || echo "  unknown" # REASON: uptime formatting flags are platform-dependent.
}

collect_processes() {
    echo "=== Processes ==="

    # Orphan node --test — use pgrep -c; exclude our own grep
    echo "Orphan node --test processes:"
    local orphan_count
    orphan_count=$(pgrep -cf 'node.*--test' 2>/dev/null) || orphan_count=0 # REASON: no matches or pgrep limitations should map to zero.
    echo "  Count: $orphan_count"

    # If there are orphans, show the oldest one's age
    if (( orphan_count > 0 )); then
        local oldest_pid
        oldest_pid=$(pgrep -f 'node.*--test' 2>/dev/null | head -1) || true # REASON: no matching process during race is expected.
        if [[ -n "$oldest_pid" ]]; then
            local elapsed
            elapsed=$(ps -p "$oldest_pid" -o etime= 2>/dev/null | tr -d ' ') || true # REASON: process may exit before elapsed-time lookup.
            [[ -n "$elapsed" ]] && echo "  Oldest process age: $elapsed"
        fi
    fi

    echo "Tmux sessions on openclaw socket:"
    local oc_count
    oc_count=$(tmux -S "${ARGUS_TMUX_SOCKET:-/tmp/openclaw-coding-agents.sock}" list-sessions 2>/dev/null | wc -l) || oc_count=0 # REASON: missing tmux socket should be treated as zero sessions.
    oc_count=$(echo "$oc_count" | tr -d '[:space:]')
    echo "  Count: $oc_count"
}

collect_athena() {
    echo "=== Athena ==="
    local memory_dir="${ARGUS_MEMORY_DIR:-$HOME/.openclaw-athena/memory}"
    if [[ -d "$memory_dir" ]]; then
        echo "Memory file modifications (last 5):"
        find "$memory_dir" -name "*.md" -type f -printf "%T+ %p\n" 2>/dev/null | sort -r | head -n5 || echo "  No .md files found" # REASON: inaccessible memory files should not break collectors.
    else
        echo "Memory directory not found: $memory_dir"
    fi
    # Athena API (port 9000) removed from monitoring (2026-02-19)
}

collect_agents() {
    echo "=== Agents ==="
    echo "Standard tmux sessions:"
    local std_count
    std_count=$(tmux list-sessions 2>/dev/null | wc -l) || std_count=0 # REASON: tmux may be unavailable; treat as zero sessions.
    std_count=$(echo "$std_count" | tr -d '[:space:]')
    echo "  Count: $std_count"
    if (( std_count > 0 )); then
        echo "  Names:"
        tmux list-sessions -F "    #{session_name} (#{session_windows} windows, created #{session_created_string})" 2>/dev/null || true # REASON: session enumeration may fail during tmux churn.
    fi

    # Custom TMUX_TMPDIR sessions (claude-* agents use a non-default socket dir)
    local custom_tmpdir="${ARGUS_TMUX_TMPDIR:-/home/polis/.tmux-socket}"
    if [[ -d "$custom_tmpdir" ]]; then
        local custom_socket="$custom_tmpdir/default"
        echo "TMUX_TMPDIR sessions ($custom_tmpdir):"
        local custom_count
        custom_count=$(tmux -S "$custom_socket" list-sessions 2>/dev/null | wc -l) || custom_count=0 # REASON: missing socket should be treated as zero sessions.
        custom_count=$(echo "$custom_count" | tr -d '[:space:]')
        echo "  Count: $custom_count"
        if (( custom_count > 0 )); then
            echo "  Names:"
            tmux -S "$custom_socket" list-sessions -F "    #{session_name} (#{session_windows} windows, created #{session_created_string})" 2>/dev/null || true # REASON: session enumeration may fail during tmux churn.
        fi
    fi

    echo "OpenClaw socket sessions:"
    local oc_sessions
    oc_sessions=$(tmux -S "${ARGUS_TMUX_SOCKET:-/tmp/openclaw-coding-agents.sock}" list-sessions -F "    #{session_name}" 2>/dev/null) || true # REASON: missing OpenClaw socket should not be treated as an error.
    if [[ -n "$oc_sessions" ]]; then
        echo "$oc_sessions"
    else
        echo "  None"
    fi
}

collect_skill_health() {
    echo "=== Skill System ==="
    local lint_script="$HOME/skills/skill-creator/scripts/lint.sh"
    if [[ ! -x "$lint_script" ]]; then
        echo "Skill lint script not found or not executable: $lint_script"
        return 0
    fi
    # Run lint and capture summary line
    local output
    output=$("$lint_script" 2>&1) || true # REASON: lint exit 1 means unhealthy; still want to report output.
    # Extract summary and result lines for the LLM
    local summary result
    summary=$(echo "$output" | grep -E '^(PASS|WARN|FAIL):' | tail -1) || true
    result=$(echo "$output" | grep -E '^Result:' | tail -1) || true
    if [[ -n "$result" ]]; then
        echo "  $result"
    fi
    if [[ -n "$summary" ]]; then
        echo "  $summary"
    fi
    # Show any FAIL/WARN lines for context
    local issues
    issues=$(echo "$output" | grep -E '^\s+(FAIL|WARN):' | head -5) || true
    if [[ -n "$issues" ]]; then
        echo "  Issues:"
        echo "$issues" | while IFS= read -r line; do echo "    $line"; done
    fi
}

# Main collection function that calls all collectors.
# Each collector runs in a subshell so a failure in one does not abort others.
collect_all_metrics() {
    echo "===== ARGUS METRICS ====="
    echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "Host: $(hostname -f 2>/dev/null || hostname)" # REASON: FQDN may be unavailable; fallback to short hostname.
    echo ""

    local collectors=(collect_services collect_system collect_processes collect_athena collect_agents collect_skill_health)
    for collector in "${collectors[@]}"; do
        if ! "$collector" 2>&1; then
            echo "ERROR: ${collector} failed"
        fi
        echo ""
    done

    echo "===== END METRICS ====="
}
