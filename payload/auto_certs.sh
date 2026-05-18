#!/bin/sh
# auto-certs main payload.
#
# Polled by /opt/auto-certs/launcher.sh on a daily cron tick. Iterates
# every /etc/auto-certs/conf.d/*.conf, polls /api/v1/check for each app,
# downloads + verifies + decrypts + installs new bundles, runs the
# CP-configured reload hook, and reports the outcome back to the server.
#
# Modes (Phase 4 Step 8):
#   (no args)         — process every configured app once. Default.
#   --once            — same as default; explicit.
#   --app <code>      — process only the named app.
#   --diagnose        — emit redacted env/connectivity report; exit.
#   --self-check      — validate config + tools + on-disk bundle; report.
#   --validate-config — read every *.conf, report missing required fields,
#                       exit non-zero if any conf is incomplete. CP-friendly
#                       sanity check after install + manual conf edit.
#
# All operating constraints enforced here:
#   - POSIX sh only (no bashisms)
#   - Standard small toolset assumed: openssl, curl|wget, tar, mv,
#     mktemp, sha256sum|shasum, awk, grep, sed, cut, tr
#   - Reload hook is opaque to us (we just exec it)
#   - NO auto-rollback — failure stays on disk + reports back
#
# Runtime state directories:
#   - $CONF_DIR     (/etc/auto-certs/conf.d)        — per-app .conf files (CP-managed)
#   - $LOG_DIR_BASE (/var/log/auto-certs)           — per-app rotating logs
#   - $QUEUE_DIR    (/var/lib/auto-certs/queue)     — deferred-report queue
#   - $STATE_DIR    (/var/lib/auto-certs/state)     — §115 per-app server-
#                                                     authoritative BASE_DOMAIN
#                                                     cache (cache wins over
#                                                     conf-file BASE_DOMAIN
#                                                     for self-check CERT_DIR
#                                                     resolution)

set -eu

# ---- Locate ourselves + source libs --------------------------------------
PAYLOAD_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$PAYLOAD_DIR/lib"
PUBKEY_FILE="$LIB_DIR/server-pubkey.pem"

# NEW-39 (CHANGELOG §43): point http.sh's curl/wget at the bundled
# Mozilla CA bundle. CentOS 6's 2013-era ca-certificates package
# can't validate GitHub's modern cert chain; the bundled cacert.pem
# fixes that without falling back to --insecure. On modern hosts
# (CentOS 7+, Ubuntu 16+) the bundled CA bundle works equally well
# as the system CA, so no platform-specific branching is needed.
# http.sh checks $AUTO_CERTS_CACERT and uses it if readable; falls
# through to system CA otherwise.
# §104 (v0.4.0-rc5): prefer the cross-version, auto-refreshed bundle at
# ${INSTALL_ROOT}/cacert.pem (written by install.sh on first install,
# refreshed by updater.sh on every tick from /cacert.pem on our server).
# Falls back to the payload-bundled cacert.pem for rc4-or-earlier installs
# that didn't yet seed ${INSTALL_ROOT}/cacert.pem.
_install_root="${AUTO_CERTS_INSTALL_ROOT:-/opt/auto-certs}"
if [ -r "${_install_root}/cacert.pem" ]; then
    export AUTO_CERTS_CACERT="${_install_root}/cacert.pem"
else
    export AUTO_CERTS_CACERT="$LIB_DIR/cacert.pem"
fi

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
# §115 (v0.4.0-rc11): per-app cache of server-authoritative BASE_DOMAIN,
# written by process_app after every successful /check, read by process_app
# before self-check. Lets self-check resolve CERT_DIR correctly even when
# the conf file omits BASE_DOMAIN (the §75 server-authoritative pattern).
STATE_DIR="${AUTO_CERTS_STATE_DIR:-/var/lib/auto-certs/state}"

# §117 (v0.4.0-rc13): augment PATH so CP reload hooks calling `service`,
# `systemctl`, `iptables`, or any other /usr/sbin- or /sbin-resident
# command work under cron. Cron's default PATH on Debian/Ubuntu is
# `/usr/bin:/bin` only — CPs typically test their reload.sh interactively
# (where PATH includes /usr/sbin) and don't notice the discrepancy until
# the next 03:46 tick when `service nginx reload` exits "command not
# found". Surfaced by jsny (成都重錘) 2026-05-18: hook worked on
# 2026-05-15 16:53 manual ssh test, then silently failed every 03:46
# cron tick for 4 consecutive nights with "FATAL: service command not
# in PATH". The cert had been on disk that whole time; nginx kept
# serving the prior cert because the hook couldn't move + reload.
#
# Defense-in-depth — the proximate fix is the CP editing their own
# reload.sh, but auto-certs can prevent the entire class of failure for
# every current + future CP by augmenting once here. Idempotent: only
# prepends entries not already in PATH, so re-execution under richer
# shells (operator SSH) doesn't bloat PATH with duplicates.
case ":${PATH:-}:" in
    *:/usr/sbin:*) : ;;
    *)             PATH="/usr/sbin${PATH:+:$PATH}" ;;
esac
case ":$PATH:" in
    *:/sbin:*) : ;;
    *)         PATH="$PATH:/sbin" ;;
esac
export PATH

# ---- CLI parsing ---------------------------------------------------------
MODE="run"
APP_FILTER=""
while [ $# -gt 0 ]; do
    case "$1" in
        --once)             MODE="run"; shift ;;
        --app)              APP_FILTER="$2"; shift 2 ;;
        --diagnose)         MODE="diagnose"; shift ;;
        --self-check)       MODE="self_check"; shift ;;
        --validate-config)  MODE="validate_config"; shift ;;
        -h|--help)
            cat <<'HELP'
auto-certs payload — usage:
  auto_certs.sh                    # process every configured app
  auto_certs.sh --once             # same as default; explicit
  auto_certs.sh --app <code>       # process one app only
  auto_certs.sh --diagnose         # print redacted env report
  auto_certs.sh --self-check       # validate config/tools/bundles, report
  auto_certs.sh --validate-config  # check every *.conf has required fields
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

# ---- run / self-check / validate-config mode ----------------------------
#
# Required-fields check shared by --validate-config and process_app.
# Sets _MISSING_FIELDS to a space-separated list of missing field names
# (empty => everything required is present). Caller is responsible for
# `.`-sourcing the conf into the current shell first.
check_required_fields() {
    _MISSING_FIELDS=""
    [ -z "${APP_CODE:-}" ]        && _MISSING_FIELDS="${_MISSING_FIELDS} APP_CODE"
    [ -z "${API_TOKEN:-}" ]       && _MISSING_FIELDS="${_MISSING_FIELDS} API_TOKEN"
    [ -z "${BUNDLE_PASSWORD:-}" ] && _MISSING_FIELDS="${_MISSING_FIELDS} BUNDLE_PASSWORD"
    # BASE_DOMAIN is NO LONGER required — post-§75 the server returns the
    # authoritative base_domain in every /api/v1/check response. The conf
    # field is now an optional override (delegated-CNAME / custom-domain
    # CPs) or a back-compat fallback for old servers that don't return
    # the field. Without it AND without server-provided value, process_app
    # errors precisely with a "no base_domain" message; check_required_fields
    # no longer flags it pre-/check.
    # Trim leading space.
    _MISSING_FIELDS=$(echo "$_MISSING_FIELDS" | sed 's/^ *//')
}

# Multi-line CP-actionable error pointing the CP MIS back to the
# install-instructions email (the canonical credential delivery channel).
# Goes to stderr AND the per-app log (when one is reachable — we're
# called pre-LOG_DIR-default-resolution in --validate-config, so we
# tolerate its absence).
print_incomplete_config_error() {
    _conf="$1"
    _missing="$2"
    cat >&2 <<ERR
auto-certs: config $_conf is incomplete:
  Missing or empty: $_missing

To fix:
  1. Open the file in an editor:  sudo \$EDITOR $_conf
  2. Paste the values from the install-instructions email into the
     empty lines:
       API_TOKEN=...
       BUNDLE_PASSWORD=...
  3. Save and re-run:
       sudo /opt/auto-certs/launcher.sh --once --app <app_code>

Note: launcher.sh does not accept secrets on the command line. They
live at-rest in this 0600 file only.
ERR
}

# ---- validate-config mode -----------------------------------------------
if [ "$MODE" = "validate_config" ]; then
    _validate_any_failed=0
    _validate_count=0
    for c in "$CONF_DIR"/*.conf; do
        [ -r "$c" ] || continue
        _validate_count=$((_validate_count + 1))
        # Source each conf in a subshell to avoid bleeding state.
        # Capture missing-fields list back via a temp file (POSIX has no
        # easy way to return a string from a subshell).
        _tmp_missing=$(mktemp)
        (
            APP_CODE=""
            BASE_DOMAIN=""
            API_TOKEN=""
            BUNDLE_PASSWORD=""
            # shellcheck disable=SC1090
            . "$c"
            check_required_fields
            printf '%s' "$_MISSING_FIELDS" > "$_tmp_missing"
        )
        _missing=$(cat "$_tmp_missing")
        rm -f "$_tmp_missing"
        if [ -n "$_missing" ]; then
            print_incomplete_config_error "$c" "$_missing"
            _validate_any_failed=1
        else
            echo "OK  $c"
        fi
    done
    if [ "$_validate_count" -eq 0 ]; then
        echo "auto-certs --validate-config: no *.conf files found in $CONF_DIR" >&2
        exit 1
    fi
    exit $_validate_any_failed
fi

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

    check_required_fields
    if [ -n "$_MISSING_FIELDS" ]; then
        print_incomplete_config_error "$_conf" "$_MISSING_FIELDS"
        return 1
    fi

    # Filter for --app mode.
    if [ -n "$APP_FILTER" ] && [ "$APP_CODE" != "$APP_FILTER" ]; then
        return 0
    fi

    # Defaults. CERT_DIR is resolved AFTER /check (post-§75) — the
    # server's authoritative base_domain comes from the response, and
    # the conf-file BASE_DOMAIN is an optional override / back-compat
    # fallback. We use a tentative directory here just for the
    # pre-/check local-bundle-hash compute; if the conf BASE_DOMAIN was
    # wrong (the popstone-shared problem), the local hash will read
    # empty, /check will return "update", and we'll re-resolve CERT_DIR
    # using the server's base_domain before the install lands.
    : "${SERVER_URL:=https://auto-certs.xforce-games.com}"
    : "${HOOK_PATH:=/opt/auto-certs/reload.sh}"
    : "${LOG_DIR:=$LOG_DIR_BASE}"
    # §115 (v0.4.0-rc11): always prefer the cached server-authoritative
    # BASE_DOMAIN over the conf-file value. Cache is written by the
    # previous successful /check (Fix B-write below); when it exists it
    # is by definition newer + correct vs. whatever the conf-file says.
    # The conf-file BASE_DOMAIN is purely a fallback for fresh installs
    # (cache absent) or pre-§75 servers (which never return base_domain).
    #
    # Post-review (Issue 4) refinement: the original Fix B-read only
    # consulted cache when conf-file BASE_DOMAIN was empty. That left
    # a false-negative-PASS hole for hosts whose conf carries a STALE
    # BASE_DOMAIN (popstone-shared → per_app migration scenario) — the
    # stale conf value won + self-check tested the wrong CERT_DIR + got
    # a misleading pass. Cache-always-wins eliminates that hole.
    _bd_cache="$STATE_DIR/$APP_CODE/server_base_domain"
    if [ -r "$_bd_cache" ]; then
        _cached_bd=$(head -n 1 "$_bd_cache" 2>/dev/null | tr -d '\r\n')
        if [ -n "$_cached_bd" ]; then
            if [ -n "${BASE_DOMAIN:-}" ] && [ "$BASE_DOMAIN" != "$_cached_bd" ]; then
                log_warn "conf BASE_DOMAIN ($BASE_DOMAIN) differs from cached server value ($_cached_bd) — using cached"
            fi
            BASE_DOMAIN="$_cached_bd"
        fi
    fi

    # Tentative CERT_DIR for the pre-/check hash compute. Only used if
    # CERT_DIR isn't explicitly set in the conf AND BASE_DOMAIN is set
    # there. Re-resolved authoritatively after /check.
    if [ -z "${CERT_DIR:-}" ] && [ -n "${BASE_DOMAIN:-}" ]; then
        CERT_DIR="/etc/auto-certs/$BASE_DOMAIN"
    fi

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

    # JKS Phase B: also compute the local jks_hash if a keystore is
    # installed. Empty string when the conf doesn't enable JKS or no
    # keystore has been delivered yet — server treats either as
    # "client doesn't have it" and emits extras.jks.
    _current_jks_hash=$(compute_local_jks_hash "$CERT_DIR" || echo "")

    phase_event "check_started"

    # Call /api/v1/check.
    #
    # We send X-Auto-Certs-Running-Ref so the server-side
    # ApiController::check() can populate launcher_assignments via the
    # heartbeat-tube path (/check is the per-tick heartbeat anchor
    # for every CP machine; without the header the worker skips the
    # launcher_assignments INSERT branch and the rollout state machine
    # never sees the machine). Header value is the canonical git-tag
    # form maintained by updater.sh on every flip; fall back to the
    # bare-semver VERSION prefixed with `v` for pre-Phase-6 layouts
    # without a .launcher_target file. Header-sending added in
    # v0.3.0-rc4.
    _install_root="${AUTO_CERTS_INSTALL_ROOT:-/opt/auto-certs}"
    _running_ref=""
    if [ -r "${_install_root}/.launcher_target" ]; then
        _running_ref=$(head -n 1 "${_install_root}/.launcher_target" | tr -d '\r\n')
    fi
    if [ -z "$_running_ref" ]; then
        _running_ref="v$(payload_version 2>/dev/null || echo 0.0.0)"
    fi
    _hdr_file=$(mktemp)
    echo "X-Auto-Certs-Running-Ref: $_running_ref" > "$_hdr_file"

    # §108 (v0.4.0-rc8): one-shot install-intent header. install.sh
    # drops /etc/auto-certs/.install_intent with the version the
    # operator just installed; the launcher reads it here and forwards
    # to the server as X-Auto-Certs-Install-Intent. The server uses
    # this as the authoritative declaration "this machine should be on
    # this version" — overrides any stale assigned_ref from a paused
    # rollout. After the /check returns 2xx (below) the file is
    # unlinked so the header is sent at-most-once per manual install.
    # Per-machine, not per-app: the very first app on the launcher's
    # iteration carries it, after success the file is gone for
    # subsequent apps' /check calls in the same tick.
    # §108 intent file path: prefer the same $AUTO_CERTS_ETC_ROOT env
    # install.sh honors (`${AUTO_CERTS_ETC_ROOT:-/etc/auto-certs}`).
    # Fall back to `dirname $MACHINE_ID_PATH` for hosts where only
    # AUTO_CERTS_MACHINE_ID is customized — the default-empty case
    # resolves both paths to the same `/etc/auto-certs/` so this is a
    # no-op in standard installs. Custom-env deployments need to set
    # AUTO_CERTS_ETC_ROOT consistently between install.sh and the
    # launcher's environment for the intent header to land.
    _intent_path="${AUTO_CERTS_ETC_ROOT:-$(dirname "$MACHINE_ID_PATH")}/.install_intent"
    _install_intent_value=""
    if [ -r "$_intent_path" ]; then
        _install_intent_value=$(head -n 1 "$_intent_path" | tr -d '\r\n')
        if [ -n "$_install_intent_value" ]; then
            echo "X-Auto-Certs-Install-Intent: $_install_intent_value" >> "$_hdr_file"
        fi
    fi

    _tmp=$(mktemp)
    # JKS Phase B (rc15+): include jks_hash query parameter so server can
    # gate extras.jks emission. Pre-rc15 servers ignore unknown params.
    _check_url="${SERVER_URL}/api/v1/check?machine_uuid=$(cat "$MACHINE_ID_PATH")&hash=${_current_hash}&jks_hash=${_current_jks_hash}"
    if ! http_get "$_check_url" "$_tmp" "$API_TOKEN" "$_hdr_file"; then
        log_error "/check failed (network or HTTP error)"
        phase_event "check_failed" "network or HTTP error"
        _payload_file=$(mktemp)
        build_report_payload "$_payload_file" \
            "${_current_hash:-0000000000000000000000000000000000000000000000000000000000000000}" \
            "false" "/check request failed" "$FC_NETWORK" "" ""
        send_report "$_payload_file" "$QUEUE_DIR" || true
        rm -f "$_tmp" "${_tmp}.headers" "$_payload_file" "${_payload_file}.resp" "$_hdr_file" 2>/dev/null || true
        return 1
    fi
    rm -f "$_hdr_file" 2>/dev/null || true
    phase_event "check_completed"

    # §108: /check returned 2xx, so the server has consumed the
    # X-Auto-Certs-Install-Intent header (if sent). Unlink the file
    # so the next tick (and all subsequent apps on this same tick)
    # don't re-send it. If the file is absent / unreadable / wasn't
    # set, this is a harmless no-op. We only unlink on success —
    # network/HTTP failures above already `return 1` before this
    # point, leaving the file for the next tick to retry.
    if [ -n "$_install_intent_value" ]; then
        rm -f "$_intent_path" 2>/dev/null || true
    fi

    _resp=$(cat "$_tmp" 2>/dev/null || echo "{}")
    rm -f "$_tmp" "${_tmp}.headers" 2>/dev/null || true
    log_info "check response: $(echo "$_resp" | redact)"

    # Server-authoritative base_domain (added in §75). Empty if the server
    # is pre-§75 — fall back to conf BASE_DOMAIN. If the server's value
    # differs from the conf's (the popstone-shared scenario), use the
    # server's: it's the source of truth for the cert's actual subject
    # and therefore the correct install path.
    _server_base_domain=""
    case "$_resp" in
        *'"base_domain":"'*)
            _server_base_domain=$(echo "$_resp" | sed -E 's/.*"base_domain":"([^"]*)".*/\1/')
            ;;
    esac
    if [ -n "$_server_base_domain" ]; then
        if [ -n "${BASE_DOMAIN:-}" ] && [ "$BASE_DOMAIN" != "$_server_base_domain" ]; then
            log_warn "conf BASE_DOMAIN ($BASE_DOMAIN) differs from server's ($_server_base_domain) — using server value"
        fi
        BASE_DOMAIN="$_server_base_domain"
        # §115 (v0.4.0-rc11): cache server-authoritative BASE_DOMAIN so the
        # NEXT launcher-flip's --self-check (which runs BEFORE /check on the
        # new payload) can resolve CERT_DIR without depending on a conf-file
        # BASE_DOMAIN field. Best-effort: a read-only or full filesystem
        # silently skips the write rather than failing the whole tick.
        _bd_cache_dir="$STATE_DIR/$APP_CODE"
        mkdir -p "$_bd_cache_dir" 2>/dev/null || true
        printf '%s\n' "$BASE_DOMAIN" > "$_bd_cache_dir/server_base_domain" 2>/dev/null || true
    fi
    # Final guard: SOMETHING must have provided base_domain. If neither
    # the conf nor the server did, we can't proceed (no CERT_DIR target,
    # no env var for the reload hook). Should only fire on pre-§75
    # server + a conf without BASE_DOMAIN, which is a misconfiguration.
    if [ -z "${BASE_DOMAIN:-}" ]; then
        log_error "no base_domain — server didn't return one and conf doesn't set BASE_DOMAIN"
        return 1
    fi
    # Authoritative CERT_DIR resolution. If the conf set CERT_DIR
    # explicitly (override case), we keep that. Otherwise derive from
    # the now-known base_domain. (If the conf BASE_DOMAIN was wrong
    # initially, this re-resolves to the right path here.)
    : "${CERT_DIR:=/etc/auto-certs/$BASE_DOMAIN}"

    # Extract optional extras.jks block (JKS Phase B). May be present
    # with EITHER status:current OR status:update per PLAN.jks.md
    # §4.2.2 6-row matrix.
    _jks_url=""
    _jks_hash=""
    case "$_resp" in
        *'"jks":{'*)
            _jks_hash=$(echo "$_resp" | sed -nE 's/.*"jks":\{"hash":"([0-9a-f]{64})".*/\1/p')
            _jks_url=$(echo "$_resp" | sed -nE 's/.*"jks":\{"hash":"[0-9a-f]+","url":"([^"]+)".*/\1/p')
            ;;
    esac

    # Crude JSON parse — POSIX sh doesn't have jq.
    case "$_resp" in
        *'"status":"current"'*)
            if [ -n "$_jks_url" ] && [ -n "$_jks_hash" ]; then
                # JKS-only update path: PEM unchanged, server says
                # client's JKS is stale. Fetch only the keystore.
                log_info "$APP_CODE: PEM current; JKS update available (hash=${_jks_hash})"
                phase_event "jks_only_update"
                process_jks_only_update "$_jks_url" "$_jks_hash" "$_current_hash"
                return $?
            fi
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
    if [ -n "$_jks_url" ] && [ -n "$_jks_hash" ]; then
        log_info "  + JKS update available (hash=${_jks_hash})"
    fi
    process_update "$_dl_url" "$_new_hash" "$_jks_url" "$_jks_hash"
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

# JKS Phase B. Read the locally-stamped jks_hash, written at install
# time alongside keystore.jks. Same approach as compute_local_bundle_hash:
# we don't try to derive the hash from the file bytes (HMAC-keyed by
# a password we don't have on the client side anyway). Server pinned
# the hash at /check time; we record it on disk and read it back.
compute_local_jks_hash() {
    _dir="$1"
    if [ -r "$_dir/.jks_hash" ]; then
        head -n 1 "$_dir/.jks_hash" | tr -d '\r\n '
    else
        echo ""
    fi
}

# JKS Phase B — fetch keystore.jks from /api/v1/download/jks/<token>,
# verify signature, decrypt envelope, write to <staging>/keystore.jks
# AND stamp <staging>/.jks_hash. On any failure, returns non-zero AND
# emits a failure report. The caller bails before atomic_install so
# PEM doesn't commit either.
#
# Args:
#   $1 — extras.jks.url
#   $2 — expected jks_hash (server-pinned at /check time)
#   $3 — _work dir (workspace; envelope.bin lands here)
#   $4 — _staging dir (where keystore.jks + .jks_hash MUST land)
#   $5 — _expected_pem_hash (for failure-report context)
fetch_and_stage_jks() {
    _jks_dl="$1"
    _expected_jks_hash="$2"
    _work_dir="$3"
    _stg="$4"
    _pem_hash="$5"

    _jks_envelope="${_work_dir}/keystore.bin"
    _jks_sigfile="${_work_dir}/keystore.sig"

    phase_event "jks_download_started"
    if ! http_get "$_jks_dl" "$_jks_envelope" "$API_TOKEN"; then
        log_error "JKS download failed"
        phase_event "jks_download_failed" "network error"
        emit_failure "$_pem_hash" "/download/jks request failed" "$FC_NETWORK" "" ""
        return 1
    fi
    phase_event "jks_download_completed"

    # Per-response X-Bundle-Hash + X-Signature.
    _jks_sig_b64=$(http_header_value "${_jks_envelope}.headers" "X-Signature")
    _jks_resp_hash=$(http_header_value "${_jks_envelope}.headers" "X-Bundle-Hash")
    if [ -z "$_jks_sig_b64" ] || [ -z "$_jks_resp_hash" ]; then
        log_error "JKS download missing X-Signature or X-Bundle-Hash"
        emit_failure "$_pem_hash" "JKS X-* headers missing" "$FC_INTEGRITY" "" ""
        return 1
    fi

    # Layer 1: hash echo check — server's response header should match
    # what /check told the client to expect. Mismatch indicates a server
    # bug or a sophisticated rollback attack on /check.
    if [ "$_jks_resp_hash" != "$_expected_jks_hash" ]; then
        log_error "JKS X-Bundle-Hash mismatch (got=${_jks_resp_hash}, expected=${_expected_jks_hash})"
        emit_failure "$_pem_hash" "JKS hash echo mismatch" "$FC_INTEGRITY" "" ""
        return 1
    fi

    # Decode signature.
    printf "%s" "$_jks_sig_b64" | base64 -d > "$_jks_sigfile" 2>/dev/null || \
        printf "%s" "$_jks_sig_b64" | openssl base64 -d -A > "$_jks_sigfile" 2>/dev/null || {
            log_error "could not base64-decode JKS X-Signature"
            emit_failure "$_pem_hash" "bad JKS X-Signature" "$FC_INTEGRITY" "" ""
            return 1
        }

    # Layer 2: RSA-4096 detached signature verify (HARD pre-condition).
    if ! verify_signature "$_jks_envelope" "$_jks_sigfile" "$PUBKEY_FILE"; then
        log_error "JKS signature verification FAILED — refusing to decrypt"
        phase_event "jks_signature_failed"
        emit_failure "$_pem_hash" "JKS signature verify failed" "$FC_INTEGRITY" "" ""
        return 1
    fi
    phase_event "jks_signature_ok"

    # Decrypt the envelope → keystore bytes.
    if ! decrypt_envelope "$_jks_envelope" "$BUNDLE_PASSWORD" "${_stg}/keystore.jks"; then
        log_error "JKS decrypt FAILED"
        emit_failure "$_pem_hash" "JKS decrypt failed" "$FC_INTEGRITY" "" ""
        return 1
    fi
    phase_event "jks_decrypt_ok"

    # NOTE: we don't sha256 the keystore bytes for verification — keytool
    # output is non-deterministic (timestamp + random PBE salt). Server
    # signature + hash-echo check above are the integrity layers.
    # Per PLAN.jks.md §4.7 implementation note 1.

    # Stamp the jks_hash so next tick can short-circuit.
    printf "%s\n" "$_expected_jks_hash" > "${_stg}/.jks_hash"
    return 0
}

# JKS-only update: PEM is current on disk, but extras.jks said the
# keystore is stale. Stage a copy of the live CERT_DIR plus the new
# keystore.jks, then atomic_install.
#
# Args:
#   $1 — extras.jks.url
#   $2 — expected jks_hash
#   $3 — current PEM bundle_hash (for failure-report context only)
process_jks_only_update() {
    _jks_url="$1"
    _jks_hash="$2"
    _pem_hash="$3"

    # Same staging-on-same-fs discipline as process_update.
    _cert_parent=$(dirname "$CERT_DIR")
    mkdir -p "$_cert_parent" 2>/dev/null || true
    if _work=$(mktemp -d "${_cert_parent}/.auto-certs-staging.XXXXXX" 2>/dev/null); then
        :
    else
        _work=$(mktemp -d)
        log_warn "JKS-only staging fell back to tmpfs"
    fi
    _staging="$_work/staging"
    mkdir -p "$_staging"

    _cleanup() { rm -rf "$_work" 2>/dev/null || true; }

    # Copy live PEM files into staging so atomic_install's dir-rename
    # swap preserves them. Empty-CERT_DIR case is impossible here
    # because /check returned status:current (PEM is on disk).
    if ! cp -p "$CERT_DIR"/. "$_staging/" 2>/dev/null; then
        # POSIX `cp /dir/. dst/` is the GNU way; for portability use a
        # plain glob.
        for _f in "$CERT_DIR"/* "$CERT_DIR"/.bundle_hash; do
            [ -e "$_f" ] || continue
            cp -p "$_f" "$_staging/" 2>/dev/null || {
                log_error "could not copy live $_f to staging"
                emit_failure "$_pem_hash" "JKS-only staging copy failed" "$FC_OTHER" "" ""
                _cleanup
                return 1
            }
        done
    fi

    # Now fetch + stage keystore.
    if ! fetch_and_stage_jks "$_jks_url" "$_jks_hash" "$_work" "$_staging" "$_pem_hash"; then
        _cleanup
        return 1
    fi

    # Atomic install (replaces CERT_DIR with PEM-copied + new keystore).
    if ! atomic_install "$_staging" "$CERT_DIR"; then
        emit_failure "$_pem_hash" "JKS-only atomic_install failed" "$FC_OTHER" "" ""
        _cleanup
        return 1
    fi
    phase_event "atomic_install_ok"

    # Run reload hook so the JVM stack picks up the new keystore.
    # §100 (v0.4.0-rc2): auto-fix missing +x bit on the hook so an
    # otherwise-edited hook doesn't fail the rollout with exit 126.
    if ensure_hook_executable "$HOOK_PATH"; then
        :
    else
        phase_event "reload_hook_autochmod_failed" "path=$HOOK_PATH"
    fi
    _hook_log="$_work/hook.log"
    # §107 (v0.4.0-rc7): wrap in `if` so `set -e` (line 26) doesn't kill the
    # parent shell when the hook exits non-zero — without this, the launcher
    # silently exits after `atomic_install_ok` and the failure is invisible
    # to both the local log and the server's report-back. Same pattern as
    # the §103 updater.sh `set -e` fix.
    #
    # §113 (v0.4.0-rc10): `VAR=val func` syntax sets VAR in the function's
    # LOCAL scope only — POSIX does NOT export it to func's external
    # children. So `AUTO_CERTS_APP_CODE="$APP_CODE" run_with_timeout
    # /path/to/hook` leaves the hook seeing AUTO_CERTS_APP_CODE as UNSET
    # (the hook then falls back to `${VAR:-default}`, masking the bug).
    # Fix: explicit `export` before the call, `unset` after. Verified on
    # dev VM: `VAR=val func` → grandchild sees unset; `export VAR; func`
    # → grandchild sees the value. Latent on this JKS-only path since
    # v0.3.0-rc1 (Phase 4) but invisible because the only hook writers
    # in the wild (jljj/nyamusou) use the default cert path anyway.
    export AUTO_CERTS_APP_CODE="$APP_CODE"
    export AUTO_CERTS_BASE_DOMAIN="$BASE_DOMAIN"
    export AUTO_CERTS_CERT_DIR="$CERT_DIR"
    export AUTO_CERTS_PREVIOUS_DIR="${CERT_DIR}.previous"
    export AUTO_CERTS_BUNDLE_HAS_JKS=1
    if run_with_timeout "$HOOK_TIMEOUT_SECONDS" "$HOOK_PATH" >"$_hook_log" 2>&1; then
        _hook_rc=0
    else
        _hook_rc=$?
    fi
    unset AUTO_CERTS_APP_CODE AUTO_CERTS_BASE_DOMAIN AUTO_CERTS_CERT_DIR \
          AUTO_CERTS_PREVIOUS_DIR AUTO_CERTS_BUNDLE_HAS_JKS
    _hook_output=$(tail -n 50 "$_hook_log" 2>/dev/null || echo "")
    if [ "$_hook_rc" -ne 0 ]; then
        # §100 (v0.4.0-rc2): annotate the most common cause of exit 126
        # in failure_reason so MIS sees an actionable hint in the alert.
        if [ "$_hook_rc" -eq 126 ] && [ -f "$HOOK_PATH" ] && [ ! -x "$HOOK_PATH" ]; then
            _hook_hint=" (hint: chmod +x $HOOK_PATH — file exists but not executable)"
        else
            _hook_hint=""
        fi
        log_error "reload hook (JKS-only update) exited $_hook_rc$_hook_hint"
        phase_event "reload_hook_failed" "exit=$_hook_rc"
        emit_failure "$_pem_hash" "JKS-only reload hook exit $_hook_rc$_hook_hint" "$FC_RELOAD_HOOK" "$_hook_output" ""
        _cleanup
        return 1
    fi
    phase_event "reload_hook_ok"

    # Report success. Use the PEM bundle_hash (unchanged) as the report
    # key — this is a "still on cert N, just refreshed JKS" event.
    _payload_file=$(mktemp)
    build_report_payload "$_payload_file" "$_pem_hash" "true" "" "" "$_hook_output" '{"jks_only":"true"}'
    send_report "$_payload_file" "$QUEUE_DIR" || true
    rm -f "$_payload_file" "${_payload_file}.resp" 2>/dev/null || true

    _cleanup
    return 0
}

# Process an "update" response from /check.
#
# Args:
#   $1 — PEM download URL (required)
#   $2 — expected PEM bundle_hash (required)
#   $3 — JKS download URL (optional; empty when no extras.jks)
#   $4 — expected JKS hash (optional; empty when no extras.jks)
process_update() {
    _dl_url="$1"
    _expected_hash="$2"
    _jks_url="${3:-}"
    _jks_hash="${4:-}"

    # IMPORTANT for atomic_install: $_work MUST be on the SAME
    # filesystem as $CERT_DIR for the atomic-mv-of-staging to be
    # atomic at the kernel level. tmpfs vs persistent-disk crossover
    # silently degrades to copy+unlink.
    # Per PLAN.jks.md §4.9: stage under the parent of $CERT_DIR.
    _cert_parent=$(dirname "$CERT_DIR")
    mkdir -p "$_cert_parent" 2>/dev/null || true
    if _work=$(mktemp -d "${_cert_parent}/.auto-certs-staging.XXXXXX" 2>/dev/null); then
        :
    else
        # Fallback: tmpfs is fine for a worktree but log it.
        _work=$(mktemp -d)
        log_warn "staging fell back to tmpfs (mktemp under ${_cert_parent} failed) — atomic_install may degrade to copy+unlink across mounts"
    fi
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

    # 6.5 JKS Phase B — if the /check response carried extras.jks, fetch
    # and stage keystore.jks alongside the PEM files. Stage-both-then-
    # commit semantics: any failure here aborts the whole install
    # (PEM doesn't atomic_install either). Per PLAN.jks.md §4.7.
    #
    # If the conf file has bundle_format_jks=0 OR the local keystore
    # was unwanted, $_jks_url is empty and we skip. If a keystore was
    # previously installed and the operator turned JKS off server-side,
    # the old keystore stays on disk (we DON'T delete — could brick
    # the JVM that's still consuming it).
    if [ -n "$_jks_url" ] && [ -n "$_jks_hash" ]; then
        if ! fetch_and_stage_jks "$_jks_url" "$_jks_hash" "$_work" "$_staging" "$_expected_hash"; then
            _cleanup
            return 1
        fi
        phase_event "jks_staged"
    fi

    # 7. Atomic install.
    if ! atomic_install "$_staging" "$CERT_DIR"; then
        emit_failure "$_expected_hash" "atomic_install failed" "$FC_OTHER" "" ""
        _cleanup
        return 1
    fi
    phase_event "atomic_install_ok"

    # 8. Run reload hook. Pass AUTO_CERTS_BUNDLE_HAS_JKS=1 when this
    # cycle installed a keystore (additive env var per PLAN.jks.md
    # §4.8). Hook can branch on it to restart the JVM stack.
    #
    # §100 (v0.4.0-rc2): auto-fix missing +x bit on the hook so an
    # otherwise-edited hook doesn't fail the rollout with exit 126.
    if ensure_hook_executable "$HOOK_PATH"; then
        :
    else
        phase_event "reload_hook_autochmod_failed" "path=$HOOK_PATH"
    fi
    _hook_log="$_work/hook.log"
    # §107 (v0.4.0-rc7): wrap in `if` so `set -e` (line 26) doesn't kill the
    # parent shell when the hook exits non-zero — without this, the launcher
    # silently exits after `atomic_install_ok` and the failure is invisible
    # to both the local log and the server's report-back. Same pattern as
    # the §103 updater.sh `set -e` fix. Drove the 2026-05-14 popstone diag.
    #
    # §113 (v0.4.0-rc10): TWO bugs fixed at this site simultaneously:
    #
    # 1. The previous `${_hook_jks_env}` expansion was placed in
    #    env-var-prefix position — but POSIX only recognizes
    #    variable-assignment prefix on LITERAL `WORD=WORD` source text,
    #    NOT on tokens produced by expansion. So `${_hook_jks_env}`
    #    expanding to `AUTO_CERTS_BUNDLE_HAS_JKS=1` made the shell try
    #    to exec a command LITERALLY NAMED `AUTO_CERTS_BUNDLE_HAS_JKS=1`
    #    → not found → exit 127. Only fired on JKS-on apps. Latent
    #    since v0.4.0-rc1 (§92 multi-step JKS) and surfaced 2026-05-15
    #    when jljj became the first CP exercising the JKS reload path
    #    end-to-end. Captured server-side as
    #    `auto_certs.sh: line 865: AUTO_CERTS_BUNDLE_HAS_JKS=1:
    #     command not found` in client_update_log.hook_output.
    # 2. `VAR=val func` syntax sets VAR in the function's LOCAL scope
    #    only — POSIX does NOT export it to func's external children.
    #    The hook never received AUTO_CERTS_* vars; the only reason
    #    no CP noticed is that hooks use `${VAR:-default}` fallbacks
    #    that happen to match the launcher's defaults.
    #
    # Fix: explicit `export` before the call + `unset` after. Verified
    # on dev VM: `VAR=val func` → grandchild sees unset; `export VAR;
    # func` → grandchild sees the value. `unset` is required because
    # the launcher iterates apps in one process (per CLAUDE.md "the
    # launcher iterates over all enabled app configs on each cron
    # tick") — without it, app A's env leaks into app B.
    export AUTO_CERTS_APP_CODE="$APP_CODE"
    export AUTO_CERTS_BASE_DOMAIN="$BASE_DOMAIN"
    export AUTO_CERTS_CERT_DIR="$CERT_DIR"
    export AUTO_CERTS_PREVIOUS_DIR="${CERT_DIR}.previous"
    if [ -n "${_jks_url:-}" ]; then
        export AUTO_CERTS_BUNDLE_HAS_JKS=1
    fi
    if run_with_timeout "$HOOK_TIMEOUT_SECONDS" "$HOOK_PATH" >"$_hook_log" 2>&1; then
        _hook_rc=0
    else
        _hook_rc=$?
    fi
    unset AUTO_CERTS_APP_CODE AUTO_CERTS_BASE_DOMAIN AUTO_CERTS_CERT_DIR \
          AUTO_CERTS_PREVIOUS_DIR AUTO_CERTS_BUNDLE_HAS_JKS
    _hook_output=$(tail -n 50 "$_hook_log" 2>/dev/null || echo "")
    if [ "$_hook_rc" -ne 0 ]; then
        # §100 (v0.4.0-rc2): annotate the most common cause of exit 126
        # in failure_reason so MIS sees an actionable hint in the alert.
        if [ "$_hook_rc" -eq 126 ] && [ -f "$HOOK_PATH" ] && [ ! -x "$HOOK_PATH" ]; then
            _hook_hint=" (hint: chmod +x $HOOK_PATH — file exists but not executable)"
        else
            _hook_hint=""
        fi
        log_error "reload hook exited $_hook_rc$_hook_hint"
        phase_event "reload_hook_failed" "exit=$_hook_rc"
        emit_failure "$_expected_hash" "reload hook exit $_hook_rc$_hook_hint" "$FC_RELOAD_HOOK" "$_hook_output" ""
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

# ---- self-check mode (Phase 4 Step 8 / Phase 6 Step 4) -----------------
#
# Runs validation checks; reports result to /api/v1/self_check_report
# (NOT /api/v1/report — different natural key, different endpoint per
# Phase 6 plan §4 Step 1 / B3). On fail, exits non-zero so updater.sh
# (the caller) knows to revert to the previous payload.
#
# Note: run_self_check exits 0 OR 1; the OUTPUT is a side effect — a
# POST to /self_check_report. updater.sh interprets the exit code; the
# server interprets the POSTed result field.
run_self_check() {
    # new_version MUST match the rollout's `target_ref` shape (git-tag
    # form, e.g. `v0.3.0-rc4`) for the server-side gate-1 self-check-
    # pass JOIN to fire. The .launcher_target file written by updater.sh
    # post-flip carries the canonical tag form (`v0.3.0-rc4`); fall back
    # to `v$(payload_version)` for paths where .launcher_target hasn't
    # been written (pre-Phase-6 layout, fresh install). Bare-semver from
    # payload/VERSION (the prior code) didn't match tag-form target_ref
    # — surfaced during Phase 6 first-rollout: self-check reports landed
    # but launcher_self_checks.new_version='0.3.0-rc4' didn't equal
    # launcher_rollouts.target_ref='v0.3.0-rc4', so the S5-2 UPDATE
    # filter excluded the row + the rollout never paused on fail.
    _install_root="${AUTO_CERTS_INSTALL_ROOT:-/opt/auto-certs}"
    _new_version=""
    if [ -r "${_install_root}/.launcher_target" ]; then
        _new_version=$(head -n 1 "${_install_root}/.launcher_target" | tr -d '\r\n')
    fi
    if [ -z "$_new_version" ]; then
        _new_version="v$(payload_version 2>/dev/null || echo 0.0.0)"
    fi
    _previous_version=$(head -n 1 "${_install_root}/.previous_target" 2>/dev/null | tr -d '\r\n')
    log_info "$APP_CODE: self-check (new_version=${_new_version})"

    _failures=""
    # §115 (v0.4.0-rc11): only flag cert_dir_missing when BASE_DOMAIN is
    # locally known. Post-§75 the server is authoritative for BASE_DOMAIN
    # (returned by /api/v1/check); the conf-file field is OPTIONAL. If the
    # conf omits BASE_DOMAIN AND we have no cached server value (Fix B at
    # process_app), self-check runs before /check can populate it — and
    # CERT_DIR would be empty, generating a false-positive cert_dir_missing.
    # The cert_dir is verified by the regular /check + /download flow
    # regardless (mkdir at install time); deferring the check here is safe.
    # Surfaced by jljj 2026-05-17: conf had APP_CODE but no BASE_DOMAIN,
    # self-check on rc10 reported cert_dir_missing while the cert was happily
    # landing at /etc/auto-certs/cyzgame.wakool.net/ via the regular path.
    if [ -n "${BASE_DOMAIN:-}" ] && [ ! -d "$CERT_DIR" ]; then
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

    _env_fp=$(build_environment_json)

    if [ -n "$_failures" ]; then
        log_error "self-check FAIL:$_failures"
        # POST fail report FIRST, THEN decide the launcher-stay exit code.
        #
        # §103 (v0.4.0-rc4) introduced rc=2 as the "controlled fail / stay"
        # signal, and updater.sh's post-flip handler treats rc=2 as "stay
        # on new payload". On paper that handles every current failure
        # category. In the field, popstone-1ca839d5 still thrashed nightly
        # for 3 nights (rc1/rc10/rc11 each reverted) — its
        # **installer-era updater.sh** (from the original `install.sh` run)
        # mishandles rc=2 and reverts on hook_placeholder regardless of
        # what the new payload signals. launcher.sh + updater.sh are
        # installed ONCE per host and don't get auto-updated by the
        # rolling payload flip, so we cannot rely on the launcher-side
        # rc=2 behavior on existing hosts. The only way out is for the
        # PAYLOAD to return rc=0 (universally-honored "pass") on the
        # categories where staying is unambiguously correct.
        #
        # §116 (v0.4.0-rc12): host-state-only failures
        # (`hook_placeholder`, `hook_missing_or_not_exec`,
        # `cert_dir_missing`) return rc=0. Reverting the payload never
        # fixes them — they're CP-side onboarding gaps or fresh-host
        # transients that are identical pre- and post-flip. The fail
        # report has already POSTed above, so the server-side §99
        # AlertSink, /admin/rollouts dashboard, fleet-pattern detector,
        # and rollout state machine all still see the failure; only
        # the launcher revert decision changes. MIS chases the CP via
        # the per-app chat group exactly as before.
        #
        # Non-host-state categories (`missing_openssl`, `no_http_client`,
        # …) keep rc=2: the host is genuinely broken in a way that
        # affects both the new and old payloads equally, so an older
        # buggy updater.sh reverting on rc=2 is no worse than staying.
        # rc11+ updater.sh stays on rc=2 per §103.
        #
        # Principle (unchanged from §103): the update mechanism is the
        # lifeline for fixing problems in the field; it should almost
        # always succeed. Auto-revert is reserved for cases where the
        # new payload is so broken it CAN'T REACH a controlled return
        # point — sh syntax error, missing interpreter, signal kill,
        # OOM, etc. Those produce uncontrolled exit codes (1, 127, 137,
        # 139, …); updater.sh treats anything non-(0|2) as catastrophic.
        #
        # Real client regressions are caught by:
        #   1. The rollout state machine — pauses on any self-check
        #      fail at canary stage. Operator sees `/admin/rollouts`
        #      and decides.
        #   2. Fleet-pattern detector — flags many hosts reporting
        #      the same failure category in <1h.
        #   3. Operator can manually revert per-host (SSH + symlink
        #      flip) as an emergency. Never automated.
        _payload_file=$(mktemp)
        build_self_check_payload "$_payload_file" "fail" "$_new_version" \
            "$_previous_version" "self_check_failures:$_failures" "$_env_fp"
        send_self_check_report "$_payload_file" "$QUEUE_DIR" || true
        rm -f "$_payload_file" "${_payload_file}.resp" 2>/dev/null || true
        if classify_host_state_only "$_failures"; then
            log_info "self-check failures are host-state-only ($_failures); update is not blocked, staying on $_new_version"
            return 0
        fi
        log_info "self-check fail is controlled (categories:$_failures); staying on $_new_version"
        return 2
    fi

    log_info "self-check OK"
    # POST pass report.
    _payload_file=$(mktemp)
    build_self_check_payload "$_payload_file" "pass" "$_new_version" \
        "$_previous_version" "" "$_env_fp"
    send_self_check_report "$_payload_file" "$QUEUE_DIR" || true
    rm -f "$_payload_file" "${_payload_file}.resp" 2>/dev/null || true
    return 0
}

# ---- main loop ---------------------------------------------------------
#
# §102 (v0.4.0-rc3): aggregate per-app rc with precedence:
#   1 (revert) beats 2 (stay) beats 0 (pass).
#
# Reasoning: if ANY app's self-check returns 1 (client-regression
# suspected), we want updater.sh to revert — even if another app
# returned 2 (host-state-only). Conversely, if all apps return 0 or 2,
# we stay on the new payload (no client regression detected).
_overall_rc=0
_apps_processed=0
for _conf in "$CONF_DIR"/*.conf; do
    [ -r "$_conf" ] || continue
    _apps_processed=$((_apps_processed + 1))
    # Each app's failure is isolated — subshell so a `set -e` inside
    # `process_app` can't bring down the loop.
    #
    # §115 (v0.4.0-rc11): wrap the subshell call in `if` so the SUBSHELL's
    # own non-zero return doesn't trigger the OUTER `set -e` (line 26)
    # before _app_rc=$? can capture the code. Without this wrap,
    # run_self_check's `return 2` (controlled stay-on-new per §103)
    # propagates up through the subshell → outer set -e fires → script
    # exits 1 → updater.sh interprets as "uncontrolled fail" and reverts.
    # This silently broke §103 stay-vs-revert for every controlled-fail
    # host (cert_dir_missing / hook_placeholder / missing-tool) from rc4
    # (2026-05-14) through rc10. The §107 fix added the same wrap-pattern
    # at the reload hook call sites but missed this main-loop call site.
    # Surfaced empirically on jljj 2026-05-17 (rc10 revert despite the
    # payload's own log line "self-check fail is controlled ... staying").
    if ( process_app "$_conf" ); then
        _app_rc=0
    else
        _app_rc=$?
    fi
    case "$_app_rc" in
        0) ;;
        2) [ "$_overall_rc" -eq 0 ] && _overall_rc=2 ;;
        *) _overall_rc=1 ;;   # any non-zero non-2 → revert
    esac
done
if [ "$_apps_processed" -eq 0 ]; then
    echo "auto-certs: no configs in $CONF_DIR" >&2
fi
exit "$_overall_rc"
