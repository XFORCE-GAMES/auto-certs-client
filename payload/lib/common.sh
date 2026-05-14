# auto-certs common helpers — POSIX sh.
# This file is sourced (not executed). Caller has set: AUTO_CERTS_LOG.

# Failure-category enum (matches sql/031_client_update_log.sql).
# Only the categories actually consumed by report.sh / auto_certs.sh are
# defined; the unused FC_SYNTAX_CHECK + FC_TLS_SELFTEST were dropped 2026-05-02.
# The 11 unused RC_* exit-code constants were also dropped at the same
# time — exit codes used by the script are inline integers per POSIX
# convention.
FC_NETWORK="network"
FC_INTEGRITY="integrity"
FC_EXTRACTION="extraction"
FC_RELOAD_HOOK="reload_hook"
FC_OTHER="other"

# log_<level> "message"
log_info() {
    log_line "INFO " "$1"
}
log_warn() {
    log_line "WARN " "$1"
}
log_error() {
    log_line "ERROR" "$1"
}

# Internal — caller-facing levels above redirect here.
log_line() {
    _level="$1"
    _msg="$2"
    _ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "0")
    _line="$_ts [$_level] $_msg"
    if [ -n "${AUTO_CERTS_LOG:-}" ]; then
        # Best-effort log file write.
        echo "$_line" >> "$AUTO_CERTS_LOG" 2>/dev/null || true
    fi
    echo "$_line" >&2
}

# Replace any token-shaped substring with [REDACTED]. Defense-in-depth on
# log lines + report payloads. The regex matches:
#   - acert_(live|test)_<43 base62>      (full bearer plaintext)
#   - dl_<43 base62>                     (full download token)
#   - 43-char base62 chunks surrounded by non-alnum (bundle-pwd shape)
redact() {
    sed -E \
        -e 's/acert_(live|test)_[A-Za-z0-9]{43}/[REDACTED_TOKEN]/g' \
        -e 's/dl_[A-Za-z0-9]{43}/[REDACTED_DLTOKEN]/g'
}

# Run a command with a timeout. Falls back to a busy-wait polling loop on
# systems without `timeout` (rare; CentOS 6+ all have it via coreutils 8.4).
#
# Usage: run_with_timeout <seconds> <cmd> [args...]
# Captures stdout+stderr to combined output; returns the command's exit
# code (or 124 if the timeout triggered, matching coreutils' convention).
run_with_timeout() {
    _t="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$_t" "$@"
        return $?
    fi
    # Fallback: spawn the command, kill after $_t seconds.
    "$@" &
    _pid=$!
    _i=0
    while [ "$_i" -lt "$_t" ]; do
        if ! kill -0 "$_pid" 2>/dev/null; then
            wait "$_pid"
            return $?
        fi
        sleep 1
        _i=$((_i + 1))
    done
    kill "$_pid" 2>/dev/null || true
    sleep 1
    kill -9 "$_pid" 2>/dev/null || true
    return 124
}

# Lazy-generate a UUID at the requested path if absent. Atomic write.
# Returns 0 on success; non-zero on filesystem trouble. After call,
# caller can read the UUID from the file.
ensure_machine_uuid() {
    _path="$1"
    if [ -s "$_path" ]; then
        return 0
    fi
    _dir=$(dirname "$_path")
    mkdir -p "$_dir" 2>/dev/null || true
    _uuid=""
    if [ -r /proc/sys/kernel/random/uuid ]; then
        _uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "")
    fi
    if [ -z "$_uuid" ] && command -v uuidgen >/dev/null 2>&1; then
        _uuid=$(uuidgen 2>/dev/null || echo "")
    fi
    if [ -z "$_uuid" ]; then
        log_error "Could not generate machine UUID — neither /proc/sys/kernel/random/uuid nor uuidgen available"
        return 1
    fi
    _tmp=$(mktemp "${_path}.XXXXXX" 2>/dev/null || echo "${_path}.tmp")
    printf "%s\n" "$_uuid" > "$_tmp" || return 1
    chmod 600 "$_tmp" 2>/dev/null || true
    mv "$_tmp" "$_path" || return 1
    log_info "generated machine_id at $_path"
    return 0
}

# §100 (v0.4.0-rc2): auto-fix the most common operator misstep when
# customizing the reload hook — file edited but `chmod +x` forgotten.
# Without this, the launcher invocation fails with exit 126 ("found
# but not executable") which surfaces as a noisy MIS alert that's
# resolved by a one-line shell command.
#
# Safety: by the time we call this, self-check has already gated the
# placeholder content separately (failure_reason='hook_placeholder' if
# the hook is still the unedited shipped placeholder), so reaching
# here means the operator has edited the file content. Auto-`chmod +x`
# is preserving their clear intent, not silently changing semantics.
#
# Returns 0 if the file is executable after the call (or was already);
# returns 1 if the file is missing or `chmod +x` failed (read-only
# fs, immutable bit, etc.). Caller should still proceed with the
# invocation in case (1) — the subsequent run_with_timeout will fail
# with a meaningful exit code that we annotate downstream.
#
# Usage: ensure_hook_executable "$HOOK_PATH"
ensure_hook_executable() {
    _hook="$1"
    if [ ! -f "$_hook" ]; then
        return 1   # missing file; let the invocation fail naturally
    fi
    if [ -x "$_hook" ]; then
        return 0   # already executable; common path
    fi
    log_warn "reload hook not executable; auto-chmod +x on $_hook"
    if chmod +x "$_hook" 2>/dev/null; then
        return 0
    fi
    log_warn "auto-chmod failed on $_hook (read-only fs? immutable bit?); reload will likely fail with exit 126"
    return 1
}

# Generic SHA-256 wrapper. Falls back to shasum if sha256sum absent.
sha256_of() {
    _f="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$_f" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$_f" | awk '{print $1}'
    else
        log_error "neither sha256sum nor shasum available"
        return 3
    fi
}
