#!/bin/sh
# auto-certs updater sidecar — Phase 6 Step 3.
#
# Polls /api/v1/launcher_check, verifies tarball RSA-4096 signature
# against the pinned server-pubkey.pem, atomic-flips `current`. Run
# BEFORE launcher.sh on every cron tick:
#
#     ${INSTALL_ROOT}/updater.sh ; ${INSTALL_ROOT}/launcher.sh
#
# Failure modes — ALL return 0 (the launcher continues running the
# prior payload): network unreachable, /launcher_check non-2xx,
# assigned_ref==current, signature verify fail, tar/flip error.
# Cosign-keyless + SLSA stay out-of-band; not in the runtime path.
#
# Writes .previous_target BEFORE the flip so a future auto-revert path
# has a defined source.

set -eu

INSTALL_ROOT="${AUTO_CERTS_INSTALL_ROOT:-/opt/auto-certs}"
CONF_DIR="${AUTO_CERTS_CONF_DIR:-/etc/auto-certs/conf.d}"
MACHINE_ID_PATH="${AUTO_CERTS_MACHINE_ID:-/etc/auto-certs/machine_id}"
LOG_FILE="${AUTO_CERTS_UPDATER_LOG:-/var/log/auto-certs/updater.log}"
PAYLOAD_LIB="${INSTALL_ROOT}/current/lib"

# NEW-39 (CHANGELOG §43): bundled Mozilla CA bundle for old hosts
# (CentOS 6's 2013-era ca-certificates can't validate GitHub TLS).
# Set BEFORE sourcing http.sh — http_get checks $AUTO_CERTS_CACERT
# and adds --cacert if readable. Falls through to system CA when
# unset/missing (modern-host installs that didn't bundle cacert).
export AUTO_CERTS_CACERT="${PAYLOAD_LIB}/cacert.pem"

if [ ! -r "${PAYLOAD_LIB}/common.sh" ]; then
    echo "updater: payload lib not readable at ${PAYLOAD_LIB}; aborting" >&2
    exit 0
fi
# shellcheck disable=SC1091
. "${PAYLOAD_LIB}/common.sh"
# shellcheck disable=SC1091
. "${PAYLOAD_LIB}/http.sh"
# shellcheck disable=SC1091
. "${PAYLOAD_LIB}/crypto.sh"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
AUTO_CERTS_LOG="$LOG_FILE"

log_info "=== updater tick start ==="

[ -s "$MACHINE_ID_PATH" ] || { log_warn "no $MACHINE_ID_PATH"; exit 0; }
MACHINE_UUID=$(head -n 1 "$MACHINE_ID_PATH" | tr -d '\r\n')

# Any conf works — /launcher_check answer is fleet-wide.
CONF_FILE=$(ls -1 "${CONF_DIR}"/*.conf 2>/dev/null | head -n 1 || true)
[ -n "$CONF_FILE" ] && [ -r "$CONF_FILE" ] || { log_warn "no conf in ${CONF_DIR}"; exit 0; }
API_TOKEN=""; SERVER_URL=""
# shellcheck disable=SC1090
. "$CONF_FILE"
[ -n "$API_TOKEN" ] && [ -n "$SERVER_URL" ] || { log_warn "no API_TOKEN/SERVER_URL"; exit 0; }

# §104 (v0.4.0-rc5): refresh the local CA bundle from our server before
# any other network operations. Uses the CURRENT /opt/auto-certs/cacert
# .pem to verify our server's cert — proper TLS verification, no TOFU
# window post-install. Fail-open: any error keeps the existing bundle
# rather than bricking the host. install-time TOFU (--insecure) is
# only acceptable during initial install.sh; updater.sh runs in
# steady-state where every cert chain MUST verify cleanly.
INSTALLED_CACERT="${INSTALL_ROOT}/cacert.pem"
refresh_cacert_bundle() {
    if [ ! -f "$INSTALLED_CACERT" ]; then
        # rc4-or-earlier host upgrading via cron: seed from bundled.
        _bundled="${PAYLOAD_LIB}/cacert.pem"
        if [ -r "$_bundled" ]; then
            cp "$_bundled" "$INSTALLED_CACERT" 2>/dev/null || return 0
            chmod 0644 "$INSTALLED_CACERT" 2>/dev/null || true
            log_info "seeded $INSTALLED_CACERT from bundled payload (rc4→rc5 migration)"
        else
            return 0  # no bundled CA → nothing to seed
        fi
    fi
    _new="${INSTALLED_CACERT}.new"
    # §110 (v0.4.0-rc9): clear any stale .new from a prior interrupted
    # run BEFORE the conditional fetch — the empty-file guard below
    # uses `[ -s "$_new" ]` to distinguish "304: server says current"
    # (curl writes nothing) from "200: server sent fresh bytes". A
    # leftover non-empty .new from a crashed prior tick would
    # spuriously pass the guard.
    rm -f "$_new" 2>/dev/null
    # §110: send `--time-cond` (curl's If-Modified-Since shortcut) with
    # the local cacert's mtime. Server (CloudFront edge) returns 304
    # when our copy is current — empirically verified on all 3 floor-
    # OS canaries (curl 7.19.7 / 7.29.0 / 7.47.0; NSS + GnuTLS). Cuts
    # steady-state cacert traffic 99.9%; full body only transfers on
    # the rare quarterly Mozilla NSS update. Server-side PHP doesn't
    # need a patch — CloudFront does the conditional GET at the edge
    # using the origin's `Last-Modified` + `Cache-Control: max-age=43200`.
    if curl --cacert "$INSTALLED_CACERT" -sSfL --connect-timeout 10 --max-time 60 \
            --time-cond "$INSTALLED_CACERT" \
            -o "$_new" "${SERVER_URL%/}/cacert.pem" 2>/dev/null; then
        # §110: 304 path — curl writes nothing when server says current.
        # No `.new` to validate, no rename needed; existing bundle stays.
        [ -s "$_new" ] || return 0
        _sz=$(wc -c < "$_new" 2>/dev/null || echo 0)
        # §105 (v0.4.0-rc6): no leading-dash pattern (CentOS 6 grep
        # treats it as flags — see install.sh _ac_try_bootstrap_cacert).
        _cn=$(grep -c 'BEGIN CERTIFICATE' "$_new" 2>/dev/null || echo 0)
        if [ "$_sz" -gt 100000 ] && [ "$_cn" -gt 100 ]; then
            mv "$_new" "$INSTALLED_CACERT"
            chmod 0644 "$INSTALLED_CACERT" 2>/dev/null || true
            # Don't log on success — silent steady-state is the goal.
        else
            log_warn "cacert.pem refresh validation failed (size=$_sz certs=$_cn); kept existing"
            rm -f "$_new"
        fi
    else
        # Network blip / server down / TLS verify fail — keep existing.
        # No insecure fallback here (asymmetric vs install.sh): post-install,
        # a TLS verify fail is a security event, not a degradation case.
        rm -f "$_new" 2>/dev/null
    fi
}
refresh_cacert_bundle

LAUNCHER_TARGET_FILE="${INSTALL_ROOT}/.launcher_target"
PREVIOUS_TARGET_FILE="${INSTALL_ROOT}/.previous_target"
CURRENT_TARGET=$(head -n 1 "$LAUNCHER_TARGET_FILE" 2>/dev/null | tr -d '\r\n')
# Fallback when .launcher_target hasn't been written yet (first install
# before any updater tick): read VERSION from the active payload tree.
# Note: payload_version() in http.sh derives from $0 — that's auto_certs
# .sh's dirname, not updater.sh's; we need the symlink target's VERSION.
#
# NEW-28 (CHANGELOG §36.7 #7): the on-disk VERSION file contains BARE
# semver ("0.3.0-rc5") — that's what client/payload/VERSION ships and
# what release.yml puts in the tarball. But rollouts use TAG form
# ("v0.3.0-rc5") in `launcher_rollouts.target_ref`, in
# `launcher_assignments.assigned_ref`, and on the line-93 equality check
# below (`[ "$ASSIGNED" = "$CURRENT_TARGET" ]`). If we leave CURRENT_TARGET
# bare on first install, that comparison always trips a needless re-flip
# AND `launcher_assignments` rows for first-sight tuples land with
# inconsistent `assigned_ref` shapes (some bare, some tag). Normalize to
# tag form here so the rest of the script sees one canonical shape.
if [ -z "$CURRENT_TARGET" ]; then
    CURRENT_TARGET=$(head -n 1 "${INSTALL_ROOT}/current/VERSION" 2>/dev/null | tr -d '\r\n')
    case "$CURRENT_TARGET" in
        v*|"") ;;
        *) CURRENT_TARGET="v${CURRENT_TARGET}" ;;
    esac
    [ -z "$CURRENT_TARGET" ] && CURRENT_TARGET="v0.0.0"
fi

# /launcher_check.
#
# We send `X-Auto-Certs-Running-Ref: $CURRENT_TARGET` so the server's
# first-sight INSERT branch (`ApiController::launcherCheck`) can
# populate `launcher_assignments.assigned_ref` for new machines that
# haven't yet hit /check via the heartbeat tube. Without this the
# launcher_check feature is half-broken: a fresh-install machine
# never gets a launcher_assignments row created via the /launcher_check
# path. Header-sending added in v0.3.0-rc3.
RESP=$(mktemp)
HDR_FILE=$(mktemp)
URL="${SERVER_URL%/}/api/v1/launcher_check?machine_uuid=${MACHINE_UUID}"
echo "X-Auto-Certs-Running-Ref: $CURRENT_TARGET" > "$HDR_FILE"
if ! http_get "$URL" "$RESP" "$API_TOKEN" "$HDR_FILE"; then
    log_warn "launcher_check unreachable; skipping"
    rm -f "$RESP" "${RESP}.headers" "$HDR_FILE"; exit 0
fi
rm -f "$HDR_FILE"
ASSIGNED=$(sed -n 's/.*"assigned_ref"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$RESP" | head -n 1)
REL_URL=$(sed -n 's/.*"release_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$RESP" | head -n 1)
SIG_URL=$(sed -n 's/.*"release_sig_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$RESP" | head -n 1)
# PHP's json_encode emits escaped slashes by default ("http:\/\/host/path").
# Unescape \/ → / so curl sees a valid URL. (Matches the convention in
# auto_certs.sh's response parsing.)
REL_URL=$(printf '%s' "$REL_URL" | sed 's#\\/#/#g')
SIG_URL=$(printf '%s' "$SIG_URL" | sed 's#\\/#/#g')
rm -f "$RESP" "${RESP}.headers"

[ -n "$ASSIGNED" ] || { log_info "no assignment; assigned_ref:null"; exit 0; }
[ "$ASSIGNED" = "$CURRENT_TARGET" ] && { log_info "already on $ASSIGNED"; exit 0; }
[ -n "$REL_URL" ] && [ -n "$SIG_URL" ] || { log_error "URLs missing in launcher_check response"; exit 0; }

log_info "update available: ${CURRENT_TARGET} → ${ASSIGNED}"

STAGING="${INSTALL_ROOT}/staging/${ASSIGNED}"
mkdir -p "$STAGING"
TARBALL="${STAGING}/release.tar.gz"
SIG="${STAGING}/release.tar.gz.release.sig"
http_get "$REL_URL" "$TARBALL" || { log_error "tarball fetch failed"; rm -rf "$STAGING"; exit 0; }
http_get "$SIG_URL" "$SIG"     || { log_error "sig fetch failed";     rm -rf "$STAGING"; exit 0; }

# Verify against the pinned RSA-4096 server pubkey (same as bundle envelope).
PUBKEY="${PAYLOAD_LIB}/server-pubkey.pem"
if ! verify_signature "$TARBALL" "$SIG" "$PUBKEY"; then
    log_error "release signature verification FAILED for ${ASSIGNED}; refusing to flip"
    rm -rf "$STAGING"; exit 0
fi
log_info "signature verified"

PAYLOAD_NEW="${INSTALL_ROOT}/payload-${ASSIGNED}"
rm -rf "$PAYLOAD_NEW" 2>/dev/null || true
mkdir -p "$PAYLOAD_NEW"
if ! tar -xzf "$TARBALL" -C "$PAYLOAD_NEW" 2>/dev/null; then
    log_error "tar extract failed"; rm -rf "$STAGING" "$PAYLOAD_NEW"; exit 0
fi
# Bubble up if the archive is wrapped. The release.yml tarball wraps
# everything in `auto-certs-client-<ver>/` AND puts `auto_certs.sh`
# under `auto-certs-client-<ver>/payload/`, so the canonical depth
# from PAYLOAD_NEW is 3. -maxdepth 4 tolerates:
#   (a) flat shape (PAYLOAD_NEW/auto_certs.sh) — depth 1
#   (b) wrapped only (PAYLOAD_NEW/<top>/auto_certs.sh) — depth 2
#   (c) wrapped + payload/ (PAYLOAD_NEW/<top>/payload/auto_certs.sh) — depth 3
#       — this is the actual release.yml shape today.
# After the move, the leftover sibling files in <top>/ (README, LICENSE,
# install.sh, launcher.sh, updater.sh, conf.d/) sit unused at
# PAYLOAD_NEW/<top>/ — harmless clutter; launcher.sh is treated as
# immutable post-install per Phase 6 design and updater.sh manages
# itself via the install root, not the payload subtree.
if [ ! -f "${PAYLOAD_NEW}/auto_certs.sh" ]; then
    INNER=$(find "$PAYLOAD_NEW" -maxdepth 4 -name auto_certs.sh -print -quit 2>/dev/null)
    if [ -n "$INNER" ]; then
        INNER_DIR=$(dirname "$INNER")
        mv "$INNER_DIR"/* "$PAYLOAD_NEW/" 2>/dev/null || true
    fi
fi
[ -f "${PAYLOAD_NEW}/auto_certs.sh" ] || {
    log_error "extracted payload missing auto_certs.sh"
    rm -rf "$STAGING" "$PAYLOAD_NEW"; exit 0
}
chmod 755 "${PAYLOAD_NEW}/auto_certs.sh" 2>/dev/null || true

if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${PAYLOAD_NEW}/auto_certs.sh" > "${PAYLOAD_NEW}/auto_certs.sh.sha256"
elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${PAYLOAD_NEW}/auto_certs.sh" > "${PAYLOAD_NEW}/auto_certs.sh.sha256"
fi

# E3: capture pre-flip target BEFORE flip.
echo "$CURRENT_TARGET" > "${PREVIOUS_TARGET_FILE}.tmp"
mv "${PREVIOUS_TARGET_FILE}.tmp" "$PREVIOUS_TARGET_FILE"

# Atomic same-FS rename.
ln -sfT "$PAYLOAD_NEW" "${INSTALL_ROOT}/current.tmp" 2>/dev/null || \
    ln -sf "$PAYLOAD_NEW" "${INSTALL_ROOT}/current.tmp"
mv -T "${INSTALL_ROOT}/current.tmp" "${INSTALL_ROOT}/current" 2>/dev/null || \
    mv "${INSTALL_ROOT}/current.tmp" "${INSTALL_ROOT}/current"

echo "$ASSIGNED" > "${LAUNCHER_TARGET_FILE}.tmp"
mv "${LAUNCHER_TARGET_FILE}.tmp" "$LAUNCHER_TARGET_FILE"

log_info "flip complete: now on ${ASSIGNED} (was ${CURRENT_TARGET})"
rm -rf "$STAGING"

# ---- auto-revert harness (Phase 6 Step 4) -------------------------------
#
# After the symlink flip + .launcher_target write, exec the just-flipped
# auto_certs.sh in --self-check mode. Non-zero exit means the new payload
# is broken; revert the symlink to .previous_target so the launcher (next
# in the cron chain) runs the prior known-good payload.
#
# `auto_certs.sh --self-check` POSTs the result to /api/v1/self_check_
# report ITSELF — we don't need to construct a payload here. updater.sh
# only reads the exit code.
#
# A few apps' configs may exist; --self-check iterates each; ANY app's
# self-check fail produces a non-zero exit (per the main loop's
# _overall_rc tracking). Sufficient for "is this payload broken on this
# machine."
NEW_PAYLOAD_BIN="${INSTALL_ROOT}/current/auto_certs.sh"
if [ ! -x "$NEW_PAYLOAD_BIN" ]; then
    log_error "post-flip self-check: ${NEW_PAYLOAD_BIN} not executable"
    exit 0
fi

# `set -e` would abort on non-zero from --self-check; wrap in if/else
# so we can inspect the exit code (rc=0 pass, rc=2 controlled-fail-stay,
# anything else → revert).
if "$NEW_PAYLOAD_BIN" --self-check; then
    _selfcheck_rc=0
else
    _selfcheck_rc=$?
fi

if [ "$_selfcheck_rc" -eq 0 ]; then
    log_info "post-flip self-check PASS"
    exit 0
fi

# §103 (v0.4.0-rc4): exit code 2 = controlled self-check fail (any
# category — hook_placeholder, cert_dir_missing, missing tools, etc.).
# Stay on the new payload.
#
# Principle: the update mechanism is the lifeline for fixing problems
# in the field; it should almost always succeed. If --self-check
# returned 2, the new payload was healthy enough to diagnose its
# environment — that's "client is fine, host needs attention."
# Server-side §99 / fleet-pattern detector / rollout state machine
# handle the fail report.
#
# Auto-revert is reserved for the catastrophic case where the new
# payload couldn't even reach the controlled rc=2 return — sh
# syntax error, missing interpreter, signal kill, OOM. Those
# produce uncontrolled exit codes (1, 127, 137, 139, …) caught by
# the fallthrough `*)` branch below.
if [ "$_selfcheck_rc" -eq 2 ]; then
    log_info "post-flip self-check returned controlled-fail (rc=2) on ${ASSIGNED}; staying"
    log_info "    (auto-revert reserved for uncontrolled exits — sh crash, missing interpreter, etc.)"
    exit 0
fi

log_error "post-flip self-check UNCONTROLLED FAIL on ${ASSIGNED} (rc=${_selfcheck_rc}); attempting revert"
log_error "    (new payload likely broken — couldn't reach controlled rc=2 return)"

# Empty .previous_target (first-install case): nothing to revert to.
# The fail report has already been POSTed by --self-check itself.
if [ -z "$CURRENT_TARGET" ] || [ "$CURRENT_TARGET" = "v0.0.0" ]; then
    log_error "post-flip self-check fail + no previous_target — leaving current at ${ASSIGNED}"
    log_error "    (rollout-frozen alert will fire server-side; operator decides next step)"
    exit 0
fi

# Revert.
PAYLOAD_PREV="${INSTALL_ROOT}/payload-${CURRENT_TARGET}"
if [ ! -d "$PAYLOAD_PREV" ]; then
    log_error "revert target ${PAYLOAD_PREV} missing — cannot revert"
    exit 0
fi

ln -sfT "$PAYLOAD_PREV" "${INSTALL_ROOT}/current.tmp" 2>/dev/null || \
    ln -sf "$PAYLOAD_PREV" "${INSTALL_ROOT}/current.tmp"
mv -T "${INSTALL_ROOT}/current.tmp" "${INSTALL_ROOT}/current" 2>/dev/null || \
    mv "${INSTALL_ROOT}/current.tmp" "${INSTALL_ROOT}/current"

# .launcher_target = previous; .previous_target STAYS the same so a
# subsequent updater tick still sees the same revert target if needed
# (per Phase 6 plan §4 Step 4 sub-step 4).
echo "$CURRENT_TARGET" > "${LAUNCHER_TARGET_FILE}.tmp"
mv "${LAUNCHER_TARGET_FILE}.tmp" "$LAUNCHER_TARGET_FILE"

log_info "reverted: now on ${CURRENT_TARGET} (failed target was ${ASSIGNED})"

# Confirm the previous payload is healthy. If it ALSO fails self-check,
# we DO NOT loop — log + exit 0; the fail report from this re-exec lands
# server-side as `failure_reason='revert_target_also_failed'`.
#
# §103 (v0.4.0-rc4): rc=2 on the revert target ALSO means a controlled
# self-check fail (same as post-flip semantics — see above). Log it
# distinctly — "operator MUST intervene" phrasing is reserved for
# uncontrolled exits indicating a genuinely broken payload, not for
# controlled host-state diagnostics. No "DON'T LOOP" warning either —
# we've already reverted; there's nothing to loop on.
PREV_PAYLOAD_BIN="${INSTALL_ROOT}/current/auto_certs.sh"
if [ ! -x "$PREV_PAYLOAD_BIN" ]; then
    log_error "post-revert: ${PREV_PAYLOAD_BIN} not executable — operator MUST intervene"
    exit 0
fi
# Same set -e wrapping as the post-flip check above.
if "$PREV_PAYLOAD_BIN" --self-check; then
    _revert_rc=0
else
    _revert_rc=$?
fi
case "$_revert_rc" in
    0)
        log_info "post-revert self-check PASS"
        ;;
    2)
        log_info "post-revert self-check returned controlled-fail (rc=2) on ${CURRENT_TARGET}"
        log_info "    (host has same controlled categories pre- and post-revert — not a revert-failure signal)"
        ;;
    *)
        log_error "post-revert self-check UNCONTROLLED FAIL (rc=${_revert_rc}) — previous_target ${CURRENT_TARGET} appears broken too"
        log_error "    operator MUST intervene; not looping further"
        ;;
esac

exit 0
