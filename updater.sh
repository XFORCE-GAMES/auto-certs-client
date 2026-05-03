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

if "$NEW_PAYLOAD_BIN" --self-check; then
    log_info "post-flip self-check PASS"
    exit 0
fi

log_error "post-flip self-check FAIL on ${ASSIGNED}; attempting revert"

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
PREV_PAYLOAD_BIN="${INSTALL_ROOT}/current/auto_certs.sh"
if [ -x "$PREV_PAYLOAD_BIN" ] && "$PREV_PAYLOAD_BIN" --self-check; then
    log_info "post-revert self-check PASS"
else
    log_error "post-revert self-check ALSO FAIL — previous_target ${CURRENT_TARGET} is broken too"
    log_error "    operator MUST intervene; not looping further"
fi

exit 0
