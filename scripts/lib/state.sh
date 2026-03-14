#!/usr/bin/env bash

state_acquire_lock() {
    local target="$1"
    local dir
    dir=$(dirname "$target")
    mkdir -p "$dir"

    local lock_dir="${target}.lock"
    local attempt=0
    while ! mkdir "$lock_dir" 2>/dev/null; do
        attempt=$((attempt + 1))
        if (( attempt >= 100 )); then
            echo "ERROR: timed out acquiring state lock for $target" >&2
            return 1
        fi
        sleep 0.05
    done

    printf '%s\n' "$lock_dir"
}

state_release_lock() {
    local lock_dir="${1:-}"
    [[ -n "$lock_dir" ]] || return 0
    rmdir "$lock_dir" 2>/dev/null || true
}

state_atomic_write_from_stdin() {
    local target="$1"
    local dir tmp_file status=0
    dir=$(dirname "$target")

    if ! mkdir -p "$dir"; then
        return 1
    fi

    if ! tmp_file=$(mktemp "${target}.tmp.XXXXXX"); then
        return 1
    fi

    if ! cat > "$tmp_file"; then
        status=1
    elif ! mv "$tmp_file" "$target"; then
        status=1
    fi

    if (( status != 0 )); then
        rm -f "$tmp_file"
    fi
    return "$status"
}

state_atomic_write_string() {
    local target="$1"
    local content="${2-}"
    printf '%s' "$content" | state_atomic_write_from_stdin "$target"
}

state_atomic_append_line() {
    local target="$1"
    local line="$2"
    local lock_dir tmp_file status=0

    lock_dir=$(state_acquire_lock "$target") || return 1
    if ! tmp_file=$(mktemp "${target}.tmp.XXXXXX"); then
        state_release_lock "$lock_dir"
        return 1
    fi

    if [[ -f "$target" ]] && ! cat "$target" > "$tmp_file"; then
        status=1
    elif ! printf '%s\n' "$line" >> "$tmp_file"; then
        status=1
    elif ! mv "$tmp_file" "$target"; then
        status=1
    fi

    if (( status != 0 )); then
        rm -f "$tmp_file"
    fi
    state_release_lock "$lock_dir"
    return "$status"
}
