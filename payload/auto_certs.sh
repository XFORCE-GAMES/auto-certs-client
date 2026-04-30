#!/bin/sh
# auto-certs main payload.
#
# Polled by /opt/auto-certs/launcher.sh on a daily cron tick. Iterates
# every /etc/auto-certs/conf.d/*.conf, polls /api/v1/check for each app,
# downloads + verifies + decrypts + installs new bundles, runs the
# CP-configured reload hook, and reports the outcome back to the server.
#
# Modes (Phase 4 Step 8):
#   (no args)        — process every configured app once. Default.
#   --once           — same as default; explicit.
#   --app <code>     — process only the named app.
#   --diagnose       — emit redacted env/connectivity report; exit.
#   --self-check     — validate config + tools + on-disk bundle; report.
#
# All operating constraints enforced here:
#   - POSIX sh only (no bashisms)
#   - Standard small toolset assumed: openssl, curl|wget, tar, mv,
#     mktemp, sha256sum|shasum, awk, grep, sed, cut, tr
#   - Reload hook is opaque to us (we just exec it)
#   - NO auto-rollback — failure stays on disk + reports back

set -eu

# ---- Locate ourselves + source libs --------------------------------------
PAYLOAD_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$PAYLOAD_DIR/lib"
PUBKEY_FILE="$LIB_DIR/server-pubkey.pem"

# shellcheck disable=SC1091
. "$LIB_DIR/common.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/http.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/crypto.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/atomic.sh"
# shellcheck disable=SC1091
. "$LIB_DIR/report.sh"

# ---- Globals (config dir + log dir + queue) ------------------------------
CONF_DIR="${AUTO_CERTS_CONF_DIR:-/etc/auto-certs/conf.d}"
LOG_DIR_BASE="${AUTO_CERTS_LOG_DIR:-/var/log/auto-certs}"
QUEUE_DIR="${AUTO_CERTS_QUEUE_DIR:-/var/lib/auto-certs/queue}"
MACHINE_ID_PATH="${AUTO_CERTS_MACHINE_ID:-/etc/auto-certs/machine_id}"

# ---- CLI parsing ---------------------------------------------------------
MODE="run"
APP_FILTER=""
while [ $# -gt 0 ]; do
    case "$1" in
        --once)         MODE="run"; shift ;;
        --app)          APP_FILTER="$2"; shift 2 ;;
        --diagnose)     MODE="diagnose"; shift ;;
        --self-check)   MODE="self_check"; shift ;;
        -h|--help)
            cat <<'HELP'
auto-certs payload — usage:
  auto_certs.sh                # process every configured app
  auto_certs.sh --once         # same as default; explicit
  auto_certs.sh --app <code>   # process one app only
  auto_certs.sh --diagnose     # print redacted env report
  auto_certs.sh --self-check   # validate config/tools/bundles, report
HELP
            exit 0
            ;;
        *)
            echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

# ---- Ensure machine_uuid -------------------------------------------------
ensure_machine_uuid "$MACHINE_ID_PATH" || {
    echo "auto-certs: cannot ensure machine_id at $MACHINE_ID_PATH" >&2
    exit 1
}

# ---- diagnose mode -------------------------------------------------------
if [ "$MODE" = "diagnose" ]; then
    echo "=== auto-certs --diagnose ==="
    echo
    echo "Payload version : $(payload_version)"
    echo "machine_id      : $(cat "$MACHINE_ID_PATH" 2>/dev/null)"
    echo "Config dir      : $CONF_DIR"
    echo
    echo "--- Environment ---"
    build_environment_json
    echo
    echo
    echo "--- Configs ---"
    for c in "$CONF_DIR"/*.conf; do
        [ -r "$c" ] || continue
        printf "  %s — " "$(basename "$c")"
        if grep -q "^APP_CODE=" "$c"; then
            grep "^APP_CODE=" "$c" | head -n 1 | redact
        else
            echo "MALFORMED (no APP_CODE)"
        fi
    done
    echo
    echo "--- Server connectivity (best-effort) ---"
    # Pick any config to read SERVER_URL from.
    for c in "$CONF_DIR"/*.conf; do
        [ -r "$c" ] || continue
        # shellcheck disable=SC1090
        ( . "$c" 2>/dev/null
          if [ -n "${SERVER_URL:-}" ]; then
              echo "Trying $SERVER_URL/api/v1/health ..."
              _tmp=$(mktemp)
              if http_get "${SERVER_URL}/api/v1/health" "$_tmp" "" 2>/dev/null; then
                  echo "Health OK; body:"
                  cat "$_tmp"
                  echo
              else
                  echo "Health request FAILED."
              fi
              rm -f "$_tmp" "${_tmp}.headers" 2>/dev/null || true
          fi
        )
        break
    done
    exit 0
fi

# ---- run / self-check mode ----------------------------------------------
process_app() {
    _conf="$1"

    # Source the per-app config in a subshell-friendly way (we don't want
    # to bleed APP_CODE et al. across iterations of the parent loop).
    APP_CODE=""
    BASE_DOMAIN=""
    API_TOKEN=""
    BUNDLE_PASSWORD=""
    SERVER_URL=""
    CERT_DIR=""
    HOOK_PATH=""
    HOOK_TIMEOUT_SECONDS=60
    LOCAL_TLS_TARGETS=""
    LOG_DIR=""
    JKS_PASSWORD=""
    # shellcheck disable=SC1090
    . "$_conf"

    if [ -z "$APP_CODE" ] || [ -z "$BASE_DOMAIN" ] || [ -z "$API_TOKEN" ] || [ -z "$BUNDLE_PASSWORD" ]; then
        echo "config $_conf missing required keys (APP_CODE/BASE_DOMAIN/API_TOKEN/BUNDLE_PASSWORD)" >&2
        return 1
    fi

    # Filter for --app mode.
    if [ -n "$APP_FILTER" ] && [ "$APP_CODE" != "$APP_FILTER" ]; then
        return 0
    fi

    # Defaults.
    : "${SERVER_URL:=https://auto-certs.xforce-games.com}"
    : "${CERT_DIR:=/etc/auto-certs/$BASE_DOMAIN}"
    : "${HOOK_PATH:=/opt/auto-certs/reload.sh}"
    : "${LOG_DIR:=$LOG_DIR_BASE}"

    AUTO_CERTS_LOG="$LOG_DIR/${APP_CODE}.log"
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    mkdir -p "$QUEUE_DIR" 2>/dev/null || true

    PHASE_EVENTS_JSON=""
    log_info "=== ${APP_CODE} tick start ==="

    # Drain any queued reports first.
    drain_report_queue "$QUEUE_DIR"

    if [ "$MODE" = "self_check" ]; then
        run_self_check
        return $?
    fi

    # Compute current bundle hash (if any).
    _current_hash=$(compute_local_bundle_hash "$CERT_DIR" || echo "")

    phase_event "check_started"

    # Call /api/v1/check.
    _tmp=$(mktemp)
    _check_url="${SERVER_URL}/api/v1/check?machine_uuid=$(cat "$MACHINE_ID_PATH")&hash=${_current_hash}"
    if ! http_get "$_check_url" "$_tmp" "$API_TOKEN"; then
        log_error "/check failed (network or HTTP error)"
        phase_event "check_failed" "network or HTTP error"
        _payload_file=$(mktemp)
        build_report_payload "$_payload_file" \
            "${_current_hash:-0000000000000000000000000000000000000000000000000000000000000000}" \
            "false" "/check request failed" "$FC_NETWORK" "" ""
        send_report "$_payload_file" "$QUEUE_DIR" || true
        rm -f "$_tmp" "${_tmp}.headers" "$_payload_file" "${_payload_file}.resp" 2>/dev/null || true
        return 1
    fi
    phase_event "check_completed"

    _resp=$(cat "$_tmp" 2>/dev/null || echo "{}")
    rm -f "$_tmp" "${_tmp}.headers" 2>/dev/null || true
    log_info "check response: $(echo "$_resp" | redact)"

    # Crude JSON parse — POSIX sh doesn't have jq.
    case "$_resp" in
        *'"status":"current"'*)
            log_info "$APP_CODE: bundle is current; no update needed"
            phase_event "current"
            return 0
            ;;
        *'"status":"update"'*)
            ;;
        *)
            log_error "/check returned unexpected response"
            log_error "  $_resp"
            return 1
            ;;
    esac

    # Extract download_url and bundle_hash from the response.
    _dl_url=$(echo "$_resp" | sed -E 's/.*"download_url":"([^"]+)".*/\1/')
    _new_hash=$(echo "$_resp" | sed -E 's/.*"bundle_hash":"([0-9a-f]{64})".*/\1/')
    if [ -z "$_dl_url" ] || [ -z "$_new_hash" ]; then
        log_error "could not parse /check update response"
        return 1
    fi

    log_info "update available: bundle_hash=${_new_hash}"
    process_update "$_dl_url" "$_new_hash"
    return $?
}

# Compute SHA-256 of the deterministic PemBundle tar at $cert_dir/.bundle.tar.
# In v1 the inner tar isn't kept on disk after install; we instead hash a
# canonical form composed from the four PEM files. This MUST match
# Wakool\Cert\PemBundle::assemble's deterministic output.
#
# Implementation note: rebuilding PemBundle's exact tar bytes in pure shell
# is fragile (POSIX ustar header construction + checksum). A simpler v1
# approach: store the bundle_hash AT INSTALL TIME alongside the cert files
# in $CERT_DIR/.bundle_hash. Read that.
compute_local_bundle_hash() {
    _dir="$1"
    if [ -r "$_dir/.bundle_hash" ]; then
        head -n 1 "$_dir/.bundle_hash" | tr -d '\r\n '
    else
        echo ""
    fi
}

# Process an "update" response from /check.
process_update() {
    _dl_url="$1"
    _expected_hash="$2"

    _work=$(mktemp -d)
    _envelope="$_work/envelope.bin"
    _tar="$_work/bundle.tar"
    _staging="$_work/staging"
    mkdir -p "$_staging"

    # Cleanup helper at the end of process_update.
    _cleanup() {
        rm -rf "$_work" 2>/dev/null || true
    }

    # 1. Download the envelope.
    phase_event "download_started"
    if ! http_get "$_dl_url" "$_envelope" "$API_TOKEN"; then
        log_error "download failed"
        phase_event "download_failed" "network error"
        emit_failure "$_expected_hash" "/download request failed" "$FC_NETWORK" "" ""
        _cleanup
        return 1
    fi
    phase_event "download_completed"

    # The signature came down in the X-Signature response header.
    _sig_b64=$(http_header_value "${_envelope}.headers" "X-Signature")
    if [ -z "$_sig_b64" ]; then
        log_error "download missing X-Signature header"
        emit_failure "$_expected_hash" "X-Signature header missing" "$FC_INTEGRITY" "" ""
        _cleanup
        return 1
    fi
    _sigfile="$_work/envelope.sig"
    printf "%s" "$_sig_b64" | base64 -d > "$_sigfile" 2>/dev/null || \
        printf "%s" "$_sig_b64" | openssl base64 -d -A > "$_sigfile" 2>/dev/null || {
            log_error "could not base64-decode X-Signature"
            emit_failure "$_expected_hash" "bad X-Signature" "$FC_INTEGRITY" "" ""
            _cleanup
            return 1
        }

    # 2. Verify signature FIRST — HARD pre-condition on decrypt.
    if ! verify_signature "$_envelope" "$_sigfile" "$PUBKEY_FILE"; then
        log_error "signature verification FAILED — refusing to decrypt"
        phase_event "signature_failed"
        emit_failure "$_expected_hash" "signature verify failed" "$FC_INTEGRITY" "" ""
        _cleanup
        return 1
    fi
    phase_event "signature_ok"

    # 3. Decrypt the envelope.
    if ! decrypt_envelope "$_envelope" "$BUNDLE_PASSWORD" "$_tar"; then
        log_error "decrypt FAILED"
        emit_failure "$_expected_hash" "decrypt failed" "$FC_INTEGRITY" "" ""
        _cleanup
        return 1
    fi
    phase_event "decrypt_ok"

    # 4. Extract the tar to staging.
    if ! tar -xf "$_tar" -C "$_staging"; then
        log_error "tar extraction failed"
        emit_failure "$_expected_hash" "tar extract failed" "$FC_EXTRACTION" "" ""
        _cleanup
        return 1
    fi
    phase_event "extract_ok"

    # 5. Validate cert + key pair.
    if [ ! -r "$_staging/cert.pem" ] || [ ! -r "$_staging/privkey.pem" ]; then
        log_error "extracted bundle missing cert.pem or privkey.pem"
        emit_failure "$_expected_hash" "incomplete bundle" "$FC_VALIDATION" "" ""
        _cleanup
        return 1
    fi
    if ! validate_cert_health "$_staging/cert.pem"; then
        emit_failure "$_expected_hash" "cert health check failed" "$FC_VALIDATION" "" ""
        _cleanup
        return 1
    fi
    if ! validate_cert_key_pair "$_staging/cert.pem" "$_staging/privkey.pem"; then
        emit_failure "$_expected_hash" "cert/key modulus mismatch" "$FC_VALIDATION" "" ""
        _cleanup
        return 1
    fi
    phase_event "validate_ok"

    # 6. Stamp the bundle hash so next tick can compare without re-deriving.
    printf "%s\n" "$_expected_hash" > "$_staging/.bundle_hash"

    # 7. Atomic install.
    if ! atomic_install "$_staging" "$CERT_DIR"; then
        emit_failure "$_expected_hash" "atomic_install failed" "$FC_OTHER" "" ""
        _cleanup
        return 1
    fi
    phase_event "atomic_install_ok"

    # 8. Run reload hook.
    _hook_log="$_work/hook.log"
    AUTO_CERTS_APP_CODE="$APP_CODE" \
    AUTO_CERTS_BASE_DOMAIN="$BASE_DOMAIN" \
    AUTO_CERTS_CERT_DIR="$CERT_DIR" \
    AUTO_CERTS_PREVIOUS_DIR="${CERT_DIR}.previous" \
        run_with_timeout "$HOOK_TIMEOUT_SECONDS" "$HOOK_PATH" >"$_hook_log" 2>&1
    _hook_rc=$?
    _hook_output=$(tail -n 50 "$_hook_log" 2>/dev/null || echo "")
    if [ "$_hook_rc" -ne 0 ]; then
        log_error "reload hook exited $_hook_rc"
        phase_event "reload_hook_failed" "exit=$_hook_rc"
        emit_failure "$_expected_hash" "reload hook exit $_hook_rc" "$FC_RELOAD_HOOK" "$_hook_output" ""
        _cleanup
        return 1
    fi
    phase_event "reload_hook_ok"

    # 9. Local TLS self-test.
    _tls_result=$(run_local_tls_selftest "$_expected_hash" "$_staging/cert.pem" 2>/dev/null || echo '{"all":"skipped"}')
    phase_event "tls_selftest_done"

    # 10. Report success.
    _payload_file=$(mktemp)
    build_report_payload "$_payload_file" \
        "$_expected_hash" "true" "" "" "$_hook_output" "$_tls_result"
    send_report "$_payload_file" "$QUEUE_DIR" || true
    rm -f "$_payload_file" "${_payload_file}.resp" 2>/dev/null || true
    log_info "$APP_CODE: update applied successfully"
    _cleanup
    return 0
}

# Run the local TLS self-test against each LOCAL_TLS_TARGETS host:port.
# Returns a JSON object: {"target":{"status":"ok|mismatch|error", "fingerprint":"…"}}
run_local_tls_selftest() {
    _expected_hash="$1"
    _cert_pem="$2"
    if [ -z "${LOCAL_TLS_TARGETS:-}" ]; then
        echo '{"all":"skipped"}'
        return 0
    fi
    _expected_fp=$(cert_fingerprint_sha256 "$_cert_pem" 2>/dev/null)
    if [ -z "$_expected_fp" ]; then
        echo '{"all":"skipped:no_expected_fingerprint"}'
        return 0
    fi
    _result="{"
    _first=1
    for _target in $LOCAL_TLS_TARGETS; do
        _host=$(echo "$_target" | cut -d: -f1)
        _port=$(echo "$_target" | cut -d: -f2)
        _status="error"
        _seen=""
        _seen=$(echo "" | run_with_timeout 10 \
                openssl s_client -servername "$_host" -connect "${_host}:${_port}" 2>/dev/null \
                | openssl x509 -noout -fingerprint -sha256 2>/dev/null \
                | sed -E "s/^[^=]+=//" || echo "")
        if [ -n "$_seen" ]; then
            if [ "$_seen" = "$_expected_fp" ]; then
                _status="ok"
            else
                _status="mismatch"
            fi
        fi
        if [ "$_first" -eq 0 ]; then _result="${_result},"; fi
        _first=0
        _result="${_result}\"${_target}\":{\"status\":\"${_status}\",\"fingerprint\":\"${_seen}\"}"
    done
    _result="${_result}}"
    echo "$_result"
}

# Helper: emit a failure report for the current app + cleanup.
emit_failure() {
    _expected_hash="$1"
    _err="$2"
    _failure_cat="$3"
    _hook_output="$4"
    _tls_result="$5"
    _payload_file=$(mktemp)
    build_report_payload "$_payload_file" \
        "$_expected_hash" "false" "$_err" "$_failure_cat" "$_hook_output" "$_tls_result"
    send_report "$_payload_file" "$QUEUE_DIR" || true
    rm -f "$_payload_file" "${_payload_file}.resp" 2>/dev/null || true
}

# ---- self-check mode (Phase 4 Step 8 / Phase 6 prep) -------------------
run_self_check() {
    log_info "$APP_CODE: self-check"
    _failures=""
    if [ ! -d "$CERT_DIR" ]; then
        _failures="${_failures} cert_dir_missing"
    fi
    if [ ! -x "$HOOK_PATH" ]; then
        _failures="${_failures} hook_missing_or_not_exec"
    elif grep -q "PLACEHOLDER" "$HOOK_PATH" 2>/dev/null; then
        _failures="${_failures} hook_placeholder"
    fi
    for _tool in openssl tar mv mktemp; do
        command -v "$_tool" >/dev/null 2>&1 || _failures="${_failures} missing_${_tool}"
    done
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        _failures="${_failures} no_http_client"
    fi
    if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
        _failures="${_failures} no_sha256"
    fi
    if [ -n "$_failures" ]; then
        log_error "self-check FAIL:$_failures"
        # Report self-check fail.
        _payload_file=$(mktemp)
        build_report_payload "$_payload_file" \
            "0000000000000000000000000000000000000000000000000000000000000000" \
            "false" "self_check_fail:$_failures" "$FC_OTHER" "" ""
        send_report "$_payload_file" "$QUEUE_DIR" || true
        rm -f "$_payload_file" "${_payload_file}.resp" 2>/dev/null || true
        return 1
    fi
    log_info "self-check OK"
    return 0
}

# ---- main loop ---------------------------------------------------------
_overall_rc=0
_apps_processed=0
for _conf in "$CONF_DIR"/*.conf; do
    [ -r "$_conf" ] || continue
    _apps_processed=$((_apps_processed + 1))
    # Each app's failure is isolated — ( ... ) || true semantics.
    if ! ( process_app "$_conf" ); then
        _overall_rc=1
    fi
done
if [ "$_apps_processed" -eq 0 ]; then
    echo "auto-certs: no configs in $CONF_DIR" >&2
fi
exit "$_overall_rc"
