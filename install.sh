#!/bin/sh
# auto-certs installer.
#
# Two-step CP onboarding (per docs/plans/install-flow-redesign.md):
#
#   STEP 1 — install (no secrets in argv, so nothing leaks to ~/.bash_history):
#     curl -sSL https://github.com/XFORCE-GAMES/auto-certs-client/releases/latest/download/install.sh \
#       | sudo sh -s -- --app <app_code>
#
#   STEP 2 — fill in the per-app config (the CP MIS pastes values from the
#   per-app chat group into the placeholder file dropped here):
#     sudo $EDITOR /etc/auto-certs/conf.d/<app_code>.conf
#       # set API_TOKEN= and BUNDLE_PASSWORD=
#
#   STEP 3 — verify:
#     sudo /opt/auto-certs/launcher.sh --once --app <app_code>
#
# Why two steps: secrets passed on a command line land in ~/.bash_history,
# show up in `ps aux` for any local user during install, and get tee'd
# into any session-recording. Editing the config file in place keeps
# them at-rest in a 0600 file — the same shape every credential-aware
# tool ships (kubectl, gh, doctl, etc.).
#
# Idempotent re-run:
#   - Upgrades the launcher + payload tree.
#   - Drops the placeholder reload hook IFF none exists (preserves CP edits).
#   - Drops a placeholder per-app conf IFF the named conf doesn't exist
#     (preserves CP-pasted secrets across upgrades).
#
# Per CLAUDE.md "Operating constraints":
#   - POSIX sh
#   - Standard small toolset only
#   - The installer's footprint:
#       /opt/auto-certs/launcher.sh
#       /opt/auto-certs/payload-<version>/   (versioned dir)
#       /opt/auto-certs/current               (symlink to active payload)
#       /opt/auto-certs/reload.sh             (placeholder if absent — CP edits)
#       /etc/auto-certs/conf.d/<app>.conf     (placeholder if absent — CP fills in)
#       /etc/auto-certs/machine_id            (lazy-generated; SEAL EXCLUDE)
#       /var/log/auto-certs/                  (per-app log dir)
#       /var/lib/auto-certs/queue/            (failed-report queue)
#       /etc/cron.d/auto-certs OR root crontab entry

set -eu

# ---- arg parsing ---------------------------------------------------------
APP_CODE=""
SERVER_URL="https://auto-certs.xforce-games.com"
INSTALL_ROOT="${AUTO_CERTS_INSTALL_ROOT:-/opt/auto-certs}"
ETC_ROOT="${AUTO_CERTS_ETC_ROOT:-/etc/auto-certs}"
LOG_ROOT="${AUTO_CERTS_LOG_ROOT:-/var/log/auto-certs}"
LIB_ROOT="${AUTO_CERTS_LIB_ROOT:-/var/lib/auto-certs}"
SOURCE_DIR="${AUTO_CERTS_SOURCE_DIR:-}"  # local dir to copy from (testing only)

usage() {
    cat <<USAGE
auto-certs install.sh — usage:

  install.sh \\
    --app <app_code> \\
    [--server-url <url>] \\
    [--source-dir <path>]   # for local testing — copy from here instead of net

Required: --app

Secrets (API_TOKEN, BUNDLE_PASSWORD) are NOT taken on the command line —
they would leak into ~/.bash_history and \`ps aux\`. Instead this installer
drops a placeholder /etc/auto-certs/conf.d/<app_code>.conf with the
required fields blank; you edit that file (mode 0600) to paste the
values from the per-app chat group.

Multi-app on one host: re-run with --app <other_code>. Existing
configs are preserved.
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --app)             APP_CODE="$2"; shift 2 ;;
        --server-url)      SERVER_URL="$2"; shift 2 ;;
        --source-dir)      SOURCE_DIR="$2"; shift 2 ;;
        # Friendly hard-fails on the old flag set so anyone copy-pasting a
        # stale install one-liner gets a clear pointer to the new flow.
        --token|--bundle-password|--base-domain|--cert-dir|--hook)
            echo "auto-certs install: --$(echo "$1" | sed 's/^--//') is no longer accepted on the command line." >&2
            echo "  Secrets and per-app config now live in /etc/auto-certs/conf.d/<app>.conf — see usage:" >&2
            echo >&2
            usage >&2
            exit 2
            ;;
        -h|--help)         usage; exit 0 ;;
        *)                 echo "unknown arg: $1" >&2; usage; exit 2 ;;
    esac
done

if [ -z "$APP_CODE" ]; then
    echo "auto-certs install: --app is required" >&2
    usage >&2
    exit 2
fi

# Reject app_codes that would trip the conf-file naming convention.
case "$APP_CODE" in
    *[!a-zA-Z0-9_-]*|""|.|..|*/*)
        echo "auto-certs install: --app must match [a-zA-Z0-9_-]+" >&2
        exit 2
        ;;
esac

# Default base_domain auto-derived from --app (per_app convention).
# Recorded in the placeholder conf; CP can override post-install for
# delegated-CNAME / custom-domain setups.
BASE_DOMAIN_DEFAULT="${APP_CODE}.wakool.net"

# ---- preflight ----------------------------------------------------------
for _tool in openssl tar mv mktemp; do
    if ! command -v "$_tool" >/dev/null 2>&1; then
        echo "auto-certs install: required tool missing: $_tool" >&2
        exit 1
    fi
done
if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    echo "auto-certs install: need curl or wget" >&2
    exit 1
fi

# ---- create dirs ----------------------------------------------------------
for _d in "$INSTALL_ROOT" "$ETC_ROOT/conf.d" "$LOG_ROOT" "$LIB_ROOT/queue"; do
    mkdir -p "$_d"
done

# ---- copy / fetch source --------------------------------------------------
# Two paths:
#   (a) --source-dir <path> given (testing / re-install from local tree).
#   (b) Auto-fetch from GitHub Releases (the curl|sh one-liner path).
#
# Auto-fetch flow (path b):
#   1. Download SHA256SUMS from /releases/${REL}/download/SHA256SUMS
#      where REL defaults to "latest" (or AUTO_CERTS_INSTALL_RELEASE for
#      pinning). The /latest/download/<asset> URL pattern transparently
#      redirects to whichever tag is the most recent published release.
#   2. Parse the tarball entry from SHA256SUMS (line ending in `.tar.gz`).
#   3. Download the tarball.
#   4. SHA-256 verify against the value from SHA256SUMS. The trust anchor
#      is the GitHub TLS chain — same shape as `rustup`, `nvm`, `helm`,
#      etc. SHA-256 verification is defense-in-depth that catches
#      mid-transfer corruption + signed-but-misuploaded artifact mixups.
#   5. Extract to a temp dir; set SOURCE_DIR to that.
#
# CentOS 6 / old-trust-store hosts:
#   GitHub TLS doesn't validate against pre-2018 ca-certificates. For that
#   case set AUTO_CERTS_INSECURE_BOOTSTRAP=1 — install.sh will use
#   `curl --insecure` / `wget --no-check-certificate`. In that mode the
#   SHA-256 check is the SOLE trust anchor; the CP MIS MUST verify the
#   expected hash out-of-band against a trusted channel (e.g. the GitHub
#   release page viewed from a modern browser, or a hash communicated
#   through the per-app chat group). See cp-onboarding-flow.md §"Special
#   cases — CentOS 6 first-install bootstrap".
#
# Override repo / release for testing:
#   AUTO_CERTS_INSTALL_REPO    default: XFORCE-GAMES/auto-certs-client
#   AUTO_CERTS_INSTALL_RELEASE default: latest  (or a tag like v0.3.0-rc9)
if [ -z "$SOURCE_DIR" ]; then
    BOOT_TMP=$(mktemp -d)
    # Cleanup on any exit path. Quoted-single-quote inside the trap so the
    # path expands now (when BOOT_TMP is set), not later.
    trap "rm -rf '$BOOT_TMP'" EXIT INT TERM
    GH_REPO="${AUTO_CERTS_INSTALL_REPO:-XFORCE-GAMES/auto-certs-client}"
    INS_FLAG=""; WGET_INS=""
    if [ "${AUTO_CERTS_INSECURE_BOOTSTRAP:-0}" = "1" ]; then
        INS_FLAG="--insecure"; WGET_INS="--no-check-certificate"
        echo "auto-certs install: WARNING — bootstrap fetches use --insecure (AUTO_CERTS_INSECURE_BOOTSTRAP=1)." >&2
        echo "  SHA-256 check is the SOLE trust anchor; expected-hash MUST come from a trusted channel." >&2
    fi
    _ac_fetch() {  # _ac_fetch <url> <out>
        if command -v curl >/dev/null 2>&1; then
            # shellcheck disable=SC2086  # INS_FLAG must word-split when set
            curl -sSL --fail $INS_FLAG "$1" -o "$2"
        else
            # shellcheck disable=SC2086  # WGET_INS must word-split when set
            wget $WGET_INS -q -O "$2" "$1"
        fi
    }
    # Resolve which release to install. Default: the most recent release
    # (including pre-releases — pre-1.0 every tag is `v0.3.0-rcN` so
    # `/releases/latest/download/` doesn't resolve, since GitHub's "latest"
    # excludes prereleases). Use the GitHub API which returns
    # all releases newest-first; the first `"tag_name"` match is the most
    # recent. AUTO_CERTS_INSTALL_RELEASE pins to a specific tag for
    # reproducible installs and bypasses the API call.
    GH_REL="${AUTO_CERTS_INSTALL_RELEASE:-}"
    if [ -z "$GH_REL" ]; then
        echo "auto-certs install: discovering latest release via GitHub API..."
        _ac_fetch "https://api.github.com/repos/${GH_REPO}/releases" "${BOOT_TMP}/releases.json" || {
            echo "auto-certs install: failed to query GitHub API for releases" >&2
            echo "  fix: pin AUTO_CERTS_INSTALL_RELEASE=<tag> (e.g. v0.3.0-rc9) and re-run" >&2
            exit 1
        }
        GH_REL=$(grep -m1 '"tag_name"' "${BOOT_TMP}/releases.json" \
            | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')
        [ -n "$GH_REL" ] || { echo "auto-certs install: could not parse latest tag from API response" >&2; exit 1; }
        echo "auto-certs install: latest release: ${GH_REL}"
    fi
    GH_BASE="https://github.com/${GH_REPO}/releases/download/${GH_REL}"
    echo "auto-certs install: fetching SHA256SUMS from ${GH_BASE}/SHA256SUMS"
    _ac_fetch "${GH_BASE}/SHA256SUMS" "${BOOT_TMP}/SHA256SUMS" || {
        echo "auto-certs install: failed to fetch SHA256SUMS" >&2; exit 1
    }
    LINE=$(grep -E '  auto-certs-client-v?[0-9]+\.[0-9]+\.[0-9]+(-(rc|beta|alpha)[0-9]+)?\.tar\.gz$' "${BOOT_TMP}/SHA256SUMS" | head -n 1)
    [ -n "$LINE" ] || { echo "auto-certs install: no tarball entry found in SHA256SUMS" >&2; exit 1; }
    EXP_HASH=$(printf '%s' "$LINE" | awk '{print $1}')
    TGZ_NAME=$(printf '%s' "$LINE" | awk '{print $2}')
    echo "auto-certs install: bootstrapping from ${TGZ_NAME} (expected SHA-256 ${EXP_HASH})"
    _ac_fetch "${GH_BASE}/${TGZ_NAME}" "${BOOT_TMP}/${TGZ_NAME}" || {
        echo "auto-certs install: failed to fetch ${TGZ_NAME}" >&2; exit 1
    }
    if command -v sha256sum >/dev/null 2>&1; then
        echo "${EXP_HASH}  ${BOOT_TMP}/${TGZ_NAME}" | sha256sum -c - >/dev/null \
            || { echo "auto-certs install: tarball SHA-256 mismatch — refusing to install" >&2; exit 1; }
    elif command -v shasum >/dev/null 2>&1; then
        ACT=$(shasum -a 256 "${BOOT_TMP}/${TGZ_NAME}" | awk '{print $1}')
        [ "$ACT" = "$EXP_HASH" ] \
            || { echo "auto-certs install: tarball SHA-256 mismatch — refusing to install" >&2; exit 1; }
    else
        # openssl is in the preflight list above so this branch always works.
        ACT=$(openssl dgst -sha256 "${BOOT_TMP}/${TGZ_NAME}" | awk '{print $NF}')
        [ "$ACT" = "$EXP_HASH" ] \
            || { echo "auto-certs install: tarball SHA-256 mismatch — refusing to install" >&2; exit 1; }
    fi
    echo "auto-certs install: SHA-256 verified"
    tar -xzf "${BOOT_TMP}/${TGZ_NAME}" -C "$BOOT_TMP"
    SOURCE_DIR="${BOOT_TMP}/${TGZ_NAME%.tar.gz}"
    [ -d "$SOURCE_DIR" ] || { echo "auto-certs install: extracted dir missing: $SOURCE_DIR" >&2; exit 1; }
fi
if [ ! -d "$SOURCE_DIR/payload" ] || [ ! -r "$SOURCE_DIR/launcher.sh" ]; then
    echo "install: --source-dir does not look like an auto-certs client tree" >&2
    exit 2
fi

# VERSION file ships BARE semver ("0.3.0-rc5"); we use TAG form ("v0.3.0-rc5")
# everywhere on disk + on the wire so that:
#   - .launcher_target matches launcher_rollouts.target_ref shape (TAG)
#   - payload-vX.Y.Z dir names match what updater.sh creates on a flip
#     (so auto-revert can find the previous payload reliably)
#   - X-Auto-Certs-Running-Ref header sent by updater.sh is TAG form
#     (so launcherCheck's running_ref vs assigned_ref compare matches)
#
# Pre-NEW-31 history (CHANGELOG §38): install.sh used `payload-$VERSION`
# (BARE) and never wrote .launcher_target. Re-installs left stale BARE
# values from prior auto-revert paths (which wrote $CURRENT_TARGET
# unnormalized). The mixed-shape state on canaries surfaced as flip-revert
# loops every cron tick. Fixed by normalizing both directory naming +
# .launcher_target write to TAG form here.
VERSION=$(head -n 1 "$SOURCE_DIR/payload/VERSION" 2>/dev/null || echo "0.0.0")
case "$VERSION" in
    v*) TAG_VERSION="$VERSION" ;;
    *)  TAG_VERSION="v$VERSION" ;;
esac
PAYLOAD_DEST="$INSTALL_ROOT/payload-$TAG_VERSION"

# Drop the launcher.
cp "$SOURCE_DIR/launcher.sh" "$INSTALL_ROOT/launcher.sh"
chmod 755 "$INSTALL_ROOT/launcher.sh"

# Drop the Phase 6 updater sidecar (idempotent — overwrites on re-run).
# Order in cron: `updater.sh ; launcher.sh` — updater fetches a new
# launcher version IF assigned; launcher runs the (possibly-just-flipped)
# payload. See client/updater.sh for the full flow.
if [ -r "$SOURCE_DIR/updater.sh" ]; then
    cp "$SOURCE_DIR/updater.sh" "$INSTALL_ROOT/updater.sh"
    chmod 755 "$INSTALL_ROOT/updater.sh"
fi

# Drop the payload.
mkdir -p "$PAYLOAD_DEST"
cp -R "$SOURCE_DIR/payload/." "$PAYLOAD_DEST/"
chmod 755 "$PAYLOAD_DEST/auto_certs.sh"
chmod -R u+rw,go-w "$PAYLOAD_DEST"

# Compute payload checksum for the launcher to integrity-check against.
if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$PAYLOAD_DEST/auto_certs.sh" > "$PAYLOAD_DEST/auto_certs.sh.sha256"
elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$PAYLOAD_DEST/auto_certs.sh" > "$PAYLOAD_DEST/auto_certs.sh.sha256"
fi

# Atomic-flip the `current` symlink.
ln -sfT "$PAYLOAD_DEST" "$INSTALL_ROOT/current.tmp" 2>/dev/null || \
    ln -sf "$PAYLOAD_DEST" "$INSTALL_ROOT/current.tmp"
mv -T "$INSTALL_ROOT/current.tmp" "$INSTALL_ROOT/current" 2>/dev/null || \
    mv "$INSTALL_ROOT/current.tmp" "$INSTALL_ROOT/current"

# Reset Phase 6 state files (CHANGELOG §38 NEW-32 / NEW-33).
#
# .launcher_target: pin to the just-installed TAG_VERSION explicitly. Without
# this, fresh installs have an empty .launcher_target and updater.sh's
# CURRENT_TARGET fallback reads payload/VERSION (BARE) which polluted
# launcher_assignments.assigned_ref with bare-form rows on first /launcher_check.
# Re-installs additionally inherited stale values from prior auto-revert paths.
# Writing TAG form here is the only way to guarantee consistent shape across
# fresh-install + re-install + post-flip + post-revert states.
#
# .previous_target: clear it. After install.sh runs, "previous version" is
# undefined — the user just installed a fresh tree, there's no payload to
# revert to. Writing an empty file (or removing it) ensures updater.sh's
# auto-revert path sees the empty-string check + refuses to revert to a
# non-existent payload (per updater.sh's "no previous_target" branch).
echo "$TAG_VERSION" > "$INSTALL_ROOT/.launcher_target.tmp"
mv "$INSTALL_ROOT/.launcher_target.tmp" "$INSTALL_ROOT/.launcher_target"
chmod 644 "$INSTALL_ROOT/.launcher_target" 2>/dev/null || true
rm -f "$INSTALL_ROOT/.previous_target" 2>/dev/null || true

# Drop placeholder reload.sh (only if absent — CP-editable post-install).
HOOK_PATH_DEFAULT="${INSTALL_ROOT}/reload.sh"
if [ ! -f "$HOOK_PATH_DEFAULT" ]; then
    cp "$SOURCE_DIR/reload.sh.placeholder" "$HOOK_PATH_DEFAULT"
    chmod 755 "$HOOK_PATH_DEFAULT"
    echo "auto-certs install: dropped placeholder reload.sh — EDIT $HOOK_PATH_DEFAULT to suit your stack."
fi

# ---- per-app config placeholder -------------------------------------------
# This is the CP MIS's only edit target for secrets. The required fields
# (API_TOKEN, BUNDLE_PASSWORD) are blank; the launcher fails loudly with
# a CP-actionable error if they stay blank past install.
APP_CONF="$ETC_ROOT/conf.d/${APP_CODE}.conf"
TEMPLATE="$SOURCE_DIR/conf.d/example.conf.template"

if [ -f "$APP_CONF" ]; then
    echo "auto-certs install: $APP_CONF already exists — preserving CP edits."
elif [ -r "$TEMPLATE" ]; then
    # Fill the template's __APP_CODE__ / __BASE_DOMAIN__ / __SERVER_URL__
    # markers; everything else stays as the template author wrote it.
    # `sed` substitutions are literal — no shell interpretation of values
    # since the values are constrained by the [a-zA-Z0-9_-]+ check above.
    sed \
        -e "s|__APP_CODE__|${APP_CODE}|g" \
        -e "s|__BASE_DOMAIN__|${BASE_DOMAIN_DEFAULT}|g" \
        -e "s|__SERVER_URL__|${SERVER_URL}|g" \
        -e "s|__GENERATED_AT__|$(date)|g" \
        "$TEMPLATE" > "${APP_CONF}.tmp"
    mv "${APP_CONF}.tmp" "$APP_CONF"
    chmod 600 "$APP_CONF"
    echo "auto-certs install: dropped placeholder $APP_CONF (mode 600)"
    echo "auto-certs install: EDIT $APP_CONF — set API_TOKEN= and BUNDLE_PASSWORD= from the per-app chat group."
else
    # Fallback: emit a minimal placeholder inline so the installer is
    # robust against a missing/renamed template.
    {
        echo "# auto-certs per-app config — created by install.sh on $(date)"
        echo "# EDIT the EMPTY fields below, save, then verify with:"
        echo "#   sudo ${INSTALL_ROOT}/launcher.sh --once --app ${APP_CODE}"
        echo ""
        echo "APP_CODE=${APP_CODE}"
        echo "BASE_DOMAIN=${BASE_DOMAIN_DEFAULT}"
        echo "SERVER_URL=${SERVER_URL}"
        echo ""
        echo "# === REQUIRED — paste from the per-app chat group ==="
        echo "API_TOKEN="
        echo "BUNDLE_PASSWORD="
        echo ""
        echo "# === Optional ==="
        echo "# CERT_DIR=${ETC_ROOT}/${BASE_DOMAIN_DEFAULT}"
        echo "# HOOK_PATH=${HOOK_PATH_DEFAULT}"
        echo "# HOOK_TIMEOUT_SECONDS=60"
        echo "# JKS_PASSWORD="
        echo "# LOCAL_TLS_TARGETS=\"127.0.0.1:443\""
    } > "${APP_CONF}.tmp"
    mv "${APP_CONF}.tmp" "$APP_CONF"
    chmod 600 "$APP_CONF"
    echo "auto-certs install: dropped placeholder $APP_CONF (mode 600; inline fallback)"
    echo "auto-certs install: EDIT $APP_CONF — set API_TOKEN= and BUNDLE_PASSWORD= from the per-app chat group."
fi

# Lazy-generate machine_id.
MACHINE_ID="$ETC_ROOT/machine_id"
if [ ! -s "$MACHINE_ID" ]; then
    if [ -r /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid > "$MACHINE_ID.tmp"
    elif command -v uuidgen >/dev/null 2>&1; then
        uuidgen > "$MACHINE_ID.tmp"
    else
        echo "auto-certs install: could not generate machine_id" >&2
        exit 1
    fi
    mv "$MACHINE_ID.tmp" "$MACHINE_ID"
    chmod 600 "$MACHINE_ID"
    echo "auto-certs install: generated $MACHINE_ID"
    echo "auto-certs install: REMINDER — exclude $MACHINE_ID from any snapshot seal script"
fi

# Cron entry. We pick a 0-59min jitter so a fleet-wide install-day doesn't
# all hit the server at the same minute. Idempotent: re-running keeps the
# same jitter if the cron file already exists.
CRON_FILE="/etc/cron.d/auto-certs"
# Phase 6: cron line chains `updater.sh ; launcher.sh`. Semicolon (NOT
# `&&`) — launcher MUST run even if updater fails (network outage,
# fetch fail, etc.) so the prior payload still applies the cert.
CRON_CMD="${INSTALL_ROOT}/updater.sh ; ${INSTALL_ROOT}/launcher.sh"
if [ -f "$CRON_FILE" ]; then
    # Idempotent: only rewrite if we still see the OLD pre-Phase-6
    # single-launcher form. Don't clobber operator-customized entries.
    if grep -q "${INSTALL_ROOT}/launcher.sh >>" "$CRON_FILE" 2>/dev/null \
       && ! grep -q "${INSTALL_ROOT}/updater.sh ; ${INSTALL_ROOT}/launcher.sh" "$CRON_FILE" 2>/dev/null; then
        # Pre-Phase-6 entry — upgrade in place, preserving the jitter minute.
        sed -i.bak \
            -e "s|${INSTALL_ROOT}/launcher.sh \(>>.*\)|${CRON_CMD} \1|" \
            "$CRON_FILE" 2>/dev/null || true
        echo "auto-certs install: upgraded $CRON_FILE to Phase 6 cron form (updater.sh ; launcher.sh)"
    else
        echo "auto-certs install: $CRON_FILE already exists — preserving."
    fi
elif [ -w "$(dirname "$CRON_FILE")" ] 2>/dev/null; then
    JITTER=$(awk 'BEGIN{srand(); print int(rand()*60)}')
    cat > "$CRON_FILE" <<CRON
# auto-certs daily check — generated by install.sh
${JITTER} 3 * * * root ${CRON_CMD} >> ${LOG_ROOT}/cron.log 2>&1
CRON
    chmod 644 "$CRON_FILE"
    echo "auto-certs install: cron entry at $CRON_FILE (3:${JITTER} daily)"
else
    JITTER=$(awk 'BEGIN{srand(); print int(rand()*60)}')
    echo "auto-certs install: WARNING — could not write $CRON_FILE."
    echo "  Add this line to root's crontab manually:"
    echo "    ${JITTER} 3 * * * ${CRON_CMD} >> ${LOG_ROOT}/cron.log 2>&1"
fi

echo
echo "auto-certs install: DONE for $APP_CODE."
echo "  Next steps:"
echo "  1. EDIT ${APP_CONF}"
echo "       set API_TOKEN= and BUNDLE_PASSWORD= from the per-app chat group."
echo "  2. EDIT ${HOOK_PATH_DEFAULT}"
echo "       replace the 'exit 1' default with your reload command."
echo "  3. TEST: sudo ${INSTALL_ROOT}/launcher.sh --once --app ${APP_CODE}"
