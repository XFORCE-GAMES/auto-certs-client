# auto-certs report-back assembly + send — POSIX sh.
# Sourced (not executed). Caller has set: AUTO_CERTS_LOG, APP_CODE,
# BASE_DOMAIN, CERT_DIR, HOOK_PATH (etc., from /etc/auto-certs/conf.d/<app>.conf).

# Generate a UUID for attempt_id. Same primitives as ensure_machine_uuid.
generate_attempt_id() {
    if [ -r /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
    elif command -v uuidgen >/dev/null 2>&1; then
        uuidgen
    else
        # Fall back to a random hex if we have nothing else; the server
        # validates UUID format, so this would 422 — but we should never
        # get here on a Linux system.
        printf "00000000-0000-4000-8000-%012x" "$(date +%s%N 2>/dev/null || date +%s)0000"
    fi
}

# Append a phase event to the JSON-array string we'll embed in the report.
# Caller builds up $PHASE_EVENTS_JSON across the run.
phase_event() {
    _name="$1"
    _detail="${2:-}"
    _ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "0")
    if [ -n "$_detail" ]; then
        # JSON-escape the detail string crudely (works for ASCII; no shell
        # tooling for full JSON escape is available without jq).
        _det_esc=$(printf "%s" "$_detail" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/[[:cntrl:]]//g')
        _evt="{\"event\":\"${_name}\",\"ts\":\"${_ts}\",\"detail\":\"${_det_esc}\"}"
    else
        _evt="{\"event\":\"${_name}\",\"ts\":\"${_ts}\"}"
    fi
    if [ -z "${PHASE_EVENTS_JSON:-}" ]; then
        PHASE_EVENTS_JSON="[${_evt}]"
    else
        PHASE_EVENTS_JSON=$(printf "%s" "$PHASE_EVENTS_JSON" | sed -E "s/]\$//")
        PHASE_EVENTS_JSON="${PHASE_EVENTS_JSON},${_evt}]"
    fi
    log_info "phase: $_name${_detail:+ — $_detail}"
}

# Build the environment fingerprint JSON. Best-effort; missing tools just
# get null values. NEVER includes secrets. Output is a JSON object.
build_environment_json() {
    _os="unknown"
    _osver="unknown"
    if [ -r /etc/os-release ]; then
        # Source /etc/os-release in a subshell to avoid polluting our env.
        _os=$(sh -c '. /etc/os-release 2>/dev/null; echo "${ID:-unknown}"')
        _osver=$(sh -c '. /etc/os-release 2>/dev/null; echo "${VERSION_ID:-unknown}"')
    fi
    _kernel=$(uname -r 2>/dev/null || echo "unknown")
    _arch=$(uname -m 2>/dev/null || echo "unknown")
    _ssl=$(openssl version 2>/dev/null | head -n 1 || echo "unknown")
    _curl=$(curl --version 2>/dev/null | head -n 1 | cut -d' ' -f1-2 || echo "unknown")
    _tar=$(tar --version 2>/dev/null | head -n 1 | cut -d' ' -f1-3 || echo "unknown")
    _bash=$(bash --version 2>/dev/null | head -n 1 | cut -d' ' -f1-4 || echo "n/a")
    _init=$(cat /proc/1/comm 2>/dev/null || echo "unknown")
    cat <<JSON
{"os":"${_os}","os_version":"${_osver}","kernel":"${_kernel}","arch":"${_arch}","openssl":"${_ssl}","curl":"${_curl}","tar":"${_tar}","bash":"${_bash}","init":"${_init}"}
JSON
}

# Build the config-snapshot JSON. CRITICAL: NEVER includes API_TOKEN /
# BUNDLE_PASSWORD / JKS_PASSWORD. These are filtered by name from the
# input env.
build_config_snapshot_json() {
    cat <<JSON
{"app_code":"${APP_CODE:-}","base_domain":"${BASE_DOMAIN:-}","cert_dir":"${CERT_DIR:-}","hook_path":"${HOOK_PATH:-}","server_url":"${SERVER_URL:-}"}
JSON
}

# Tail the local log file, redact any token-shaped substrings, return up
# to ~50 lines as a JSON-safe string.
build_recent_log_tail() {
    if [ -z "${AUTO_CERTS_LOG:-}" ] || [ ! -r "$AUTO_CERTS_LOG" ]; then
        echo ""
        return 0
    fi
    tail -n 50 "$AUTO_CERTS_LOG" 2>/dev/null \
        | redact \
        | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/[[:cntrl:]]//g'
}

# Compose the full report payload as a JSON file at $1.
# $2 = bundle_hash (hex)
# $3 = applied (true|false)
# $4 = error string or empty
# $5 = failure_category (one of FC_* or empty)
# $6 = hook_output (string) or empty
# $7 = tls_self_test_result (json) or empty
build_report_payload() {
    _outfile="$1"
    _bundle_hash="$2"
    _applied="$3"
    _error="$4"
    _failure_cat="$5"
    _hook_output="$6"
    _tls_result="$7"

    _machine_uuid=$(cat /etc/auto-certs/machine_id 2>/dev/null || echo "")
    _attempt_id=$(generate_attempt_id)
    _reported_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    _client_version=$(payload_version)
    _env=$(build_environment_json)
    _conf=$(build_config_snapshot_json)
    _logtail=$(build_recent_log_tail)
    _phase="${PHASE_EVENTS_JSON:-[]}"

    # Escape error + hook_output for JSON
    _err_esc=$(printf "%s" "$_error"      | redact | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/[[:cntrl:]]//g')
    _hook_esc=$(printf "%s" "$_hook_output" | redact | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/[[:cntrl:]]//g')
    _tls_compact="${_tls_result:-{}}"

    # Build the payload. Optional fields are null if empty.
    {
        printf '{'
        printf '"machine_uuid":"%s",' "$_machine_uuid"
        printf '"attempt_id":"%s",' "$_attempt_id"
        printf '"bundle_hash":"%s",' "$_bundle_hash"
        printf '"applied":%s,' "$_applied"
        printf '"reported_at":"%s",' "$_reported_at"
        if [ -n "$_error" ]; then
            printf '"error":"%s",' "$_err_esc"
        fi
        if [ -n "$_failure_cat" ]; then
            printf '"failure_category":"%s",' "$_failure_cat"
        fi
        if [ -n "$_hook_output" ]; then
            printf '"hook_output":"%s",' "$_hook_esc"
        fi
        if [ -n "$_tls_result" ] && [ "$_tls_result" != "{}" ]; then
            printf '"tls_self_test_result":%s,' "$_tls_compact"
        fi
        printf '"phase_events":%s,' "$_phase"
        printf '"environment":%s,' "$_env"
        printf '"config_snapshot":%s,' "$_conf"
        printf '"recent_log_tail":"%s",' "$_logtail"
        printf '"client_version":"%s"' "$_client_version"
        printf '}'
    } > "$_outfile"
}

# Send a built report to the server. Retries once on 5xx; queues to disk
# on persistent failure.
#
# send_report <payload_file> <queue_dir>
send_report() {
    _payload="$1"
    _queue="$2"
    _url="${SERVER_URL:-https://auto-certs.xforce-games.com}/api/v1/report"

    if http_post_json "$_url" "$_payload" "$API_TOKEN"; then
        log_info "report sent"
        return 0
    fi
    # Retry once with a small jitter.
    sleep 2
    if http_post_json "$_url" "$_payload" "$API_TOKEN"; then
        log_info "report sent (retry)"
        return 0
    fi
    # Queue. Filename is <timestamp>-<pid>-<rand>.json:
    #   - $_ts: epoch seconds (collisions only across processes inside
    #     the same second).
    #   - $$: PID (distinguishes parallel cron ticks if any).
    #   - awk-driven 5-digit random: belt-and-suspenders entropy in case
    #     two siblings inherit the same PID-modulo behavior.
    # We avoid $RANDOM (bash-only; not POSIX).
    mkdir -p "$_queue" 2>/dev/null || true
    _ts=$(date +%s)
    _rand=$(awk 'BEGIN{srand(); printf "%05d\n", int(rand()*100000)}' 2>/dev/null || echo "00000")
    _qfile="$_queue/${_ts}-$$-${_rand}.json"
    if cp "$_payload" "$_qfile" 2>/dev/null; then
        log_warn "report send failed twice; queued at $_qfile"
    else
        log_error "report send failed AND queue write failed"
    fi
    return 1
}

# Drain the queue. Called at the start of each launcher tick.
drain_report_queue() {
    _queue="$1"
    if [ ! -d "$_queue" ]; then
        return 0
    fi
    _url="${SERVER_URL:-https://auto-certs.xforce-games.com}/api/v1/report"
    for _qfile in "$_queue"/*.json; do
        if [ ! -r "$_qfile" ]; then
            continue
        fi
        if http_post_json "$_url" "$_qfile" "$API_TOKEN"; then
            rm -f "$_qfile" 2>/dev/null || true
            log_info "queued report $_qfile drained"
        else
            log_warn "queued report $_qfile still failing; will retry next tick"
            # Stop on first failure — the server is probably down.
            break
        fi
    done
}

# Build a /api/v1/self_check_report payload (Phase 6 Step 4 / B3).
#
# Distinct from build_report_payload because the natural key + endpoint
# semantics are different: self-check is per-(machine, launcher-version-
# flip), not per-cert-update-attempt.
#
# build_self_check_payload <outfile> <result> <new_version>
#                          <previous_version> <failure_reason> <env_fp_json>
#
# Required: result (pass|fail), new_version (vX.Y.Z[-rcN]).
# Optional: previous_version, failure_reason, env_fp_json.
#
# Output is a JSON object conforming to SelfCheckPayloadValidator's
# ALLOWED_TOP_LEVEL keys.
build_self_check_payload() {
    _outfile="$1"
    _result="$2"
    _new_version="$3"
    _previous_version="${4:-}"
    _failure_reason="${5:-}"
    _env_fp_json="${6:-}"

    _machine_uuid=$(cat /etc/auto-certs/machine_id 2>/dev/null || echo "")
    _reported_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    _launcher_version=$(payload_version)

    _reason_esc=$(printf "%s" "$_failure_reason" | redact \
        | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/[[:cntrl:]]//g')

    {
        printf '{'
        printf '"phase":"self_check",'
        printf '"result":"%s",' "$_result"
        printf '"machine_uuid":"%s",' "$_machine_uuid"
        printf '"new_version":"%s",' "$_new_version"
        printf '"reported_at":"%s",' "$_reported_at"
        if [ -n "$_previous_version" ]; then
            printf '"previous_version":"%s",' "$_previous_version"
        fi
        if [ -n "$_failure_reason" ]; then
            printf '"failure_reason":"%s",' "$_reason_esc"
        fi
        if [ -n "$_env_fp_json" ]; then
            printf '"env_fingerprint":%s,' "$_env_fp_json"
        fi
        printf '"launcher_version":"%s"' "$_launcher_version"
        printf '}'
    } > "$_outfile"
}

# POST a self-check report. Same retry + queue semantics as send_report.
# On persistent failure, queues to <queue_dir>/sc-<ts>-<pid>-<rand>.json.
#
# send_self_check_report <payload_file> <queue_dir>
send_self_check_report() {
    _payload="$1"
    _queue="$2"
    _url="${SERVER_URL:-https://auto-certs.xforce-games.com}/api/v1/self_check_report"

    if http_post_json "$_url" "$_payload" "$API_TOKEN"; then
        log_info "self_check_report sent"
        return 0
    fi
    sleep 2
    if http_post_json "$_url" "$_payload" "$API_TOKEN"; then
        log_info "self_check_report sent (retry)"
        return 0
    fi
    # Queue. Distinct prefix `sc-` so drain_self_check_queue can
    # filter — drain_report_queue's `*.json` glob would otherwise
    # try to POST self-check payloads to /api/v1/report and 422.
    mkdir -p "$_queue" 2>/dev/null || true
    _ts=$(date +%s)
    _rand=$(awk 'BEGIN{srand(); printf "%05d\n", int(rand()*100000)}' 2>/dev/null || echo "00000")
    _qfile="$_queue/sc-${_ts}-$$-${_rand}.json"
    if cp "$_payload" "$_qfile" 2>/dev/null; then
        log_warn "self_check_report send failed twice; queued at $_qfile"
    else
        log_error "self_check_report send failed AND queue write failed"
    fi
    return 1
}

# Drain the self-check queue (sc-*.json) into /api/v1/self_check_report.
# Same shape as drain_report_queue but on a different endpoint + glob.
drain_self_check_queue() {
    _queue="$1"
    if [ ! -d "$_queue" ]; then
        return 0
    fi
    _url="${SERVER_URL:-https://auto-certs.xforce-games.com}/api/v1/self_check_report"
    for _qfile in "$_queue"/sc-*.json; do
        if [ ! -r "$_qfile" ]; then
            continue
        fi
        if http_post_json "$_url" "$_qfile" "$API_TOKEN"; then
            rm -f "$_qfile" 2>/dev/null || true
            log_info "queued self_check_report $_qfile drained"
        else
            log_warn "queued self_check_report $_qfile still failing"
            break
        fi
    done
}
