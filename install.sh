#!/bin/sh
# auto-certs installer.
#
# One-line install per CLAUDE.md "Quick start":
#   curl -sSL https://auto-certs.xforce-games.com/install.sh \
#     | sh -s -- --app <code> --token <…> --bundle-password <…> --base-domain <…>
#
# Idempotent: re-running upgrades the launcher + payload but never
# overwrites a CP-edited reload.sh.
#
# Per CLAUDE.md "Operating constraints":
#   - POSIX sh
#   - Standard small toolset only
#   - The installer's footprint:
#       /opt/auto-certs/launcher.sh
#       /opt/auto-certs/payload-<version>/   (versioned dir)
#       /opt/auto-certs/current               (symlink to active payload)
#       /opt/auto-certs/reload.sh             (placeholder if absent — CP edits)
#       /etc/auto-certs/conf.d/<app>.conf
#       /etc/auto-certs/machine_id            (lazy-generated; SEAL EXCLUDE)
#       /var/log/auto-certs/                  (per-app log dir)
#       /var/lib/auto-certs/queue/            (failed-report queue)
#       /etc/cron.d/auto-certs OR root crontab entry

set -eu

# ---- arg parsing ---------------------------------------------------------
APP_CODE=""
API_TOKEN=""
BUNDLE_PASSWORD=""
BASE_DOMAIN=""
CERT_DIR=""
HOOK_PATH=""
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
    --token <bearer_token> \\
    --bundle-password <password> \\
    --base-domain <subdomain.wakool.net> \\
    [--cert-dir <path>] \\
    [--hook <path>] \\
    [--server-url <url>] \\
    [--source-dir <path>]   # for local testing — copy from here instead of net

Required: --app, --token, --bundle-password, --base-domain.
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --app)             APP_CODE="$2"; shift 2 ;;
        --token)           API_TOKEN="$2"; shift 2 ;;
        --bundle-password) BUNDLE_PASSWORD="$2"; shift 2 ;;
        --base-domain)     BASE_DOMAIN="$2"; shift 2 ;;
        --cert-dir)        CERT_DIR="$2"; shift 2 ;;
        --hook)            HOOK_PATH="$2"; shift 2 ;;
        --server-url)      SERVER_URL="$2"; shift 2 ;;
        --source-dir)      SOURCE_DIR="$2"; shift 2 ;;
        -h|--help)         usage; exit 0 ;;
        *)                 echo "unknown arg: $1" >&2; usage; exit 2 ;;
    esac
done

if [ -z "$APP_CODE" ] || [ -z "$API_TOKEN" ] || [ -z "$BUNDLE_PASSWORD" ] || [ -z "$BASE_DOMAIN" ]; then
    echo "missing required arg(s)" >&2
    usage
    exit 2
fi

# Sensible defaults.
: "${CERT_DIR:=$ETC_ROOT/${BASE_DOMAIN}}"
: "${HOOK_PATH:=${INSTALL_ROOT}/reload.sh}"

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
# In v1 we ship from a local SOURCE_DIR (test path); the public-curl-pipe
# install fetches a tarball from a release URL once Phase 7 GitHub
# migration is done. For now SOURCE_DIR is required.
if [ -z "$SOURCE_DIR" ]; then
    echo "install: --source-dir required (Phase 7 will add GitHub fetch)" >&2
    exit 2
fi
if [ ! -d "$SOURCE_DIR/payload" ] || [ ! -r "$SOURCE_DIR/launcher.sh" ]; then
    echo "install: --source-dir does not look like an auto-certs client tree" >&2
    exit 2
fi

VERSION=$(head -n 1 "$SOURCE_DIR/payload/VERSION" 2>/dev/null || echo "0.0.0")
PAYLOAD_DEST="$INSTALL_ROOT/payload-$VERSION"

# Drop the launcher.
cp "$SOURCE_DIR/launcher.sh" "$INSTALL_ROOT/launcher.sh"
chmod 755 "$INSTALL_ROOT/launcher.sh"

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

# Drop placeholder reload.sh (only if absent — CP-editable post-install).
if [ ! -f "$HOOK_PATH" ]; then
    cp "$SOURCE_DIR/reload.sh.placeholder" "$HOOK_PATH"
    chmod 755 "$HOOK_PATH"
    echo "auto-certs install: dropped placeholder reload.sh — EDIT $HOOK_PATH to suit your stack."
fi

# Drop per-app config.
APP_CONF="$ETC_ROOT/conf.d/${APP_CODE}.conf"
{
    echo "# Auto-generated by install.sh on $(date)"
    echo "APP_CODE=${APP_CODE}"
    echo "BASE_DOMAIN=${BASE_DOMAIN}"
    echo "API_TOKEN=${API_TOKEN}"
    echo "BUNDLE_PASSWORD=${BUNDLE_PASSWORD}"
    echo "SERVER_URL=${SERVER_URL}"
    echo "CERT_DIR=${CERT_DIR}"
    echo "HOOK_PATH=${HOOK_PATH}"
    echo "HOOK_TIMEOUT_SECONDS=60"
    echo "# Optional: LOCAL_TLS_TARGETS=\"127.0.0.1:443\""
} > "$APP_CONF"
chmod 600 "$APP_CONF"
echo "auto-certs install: wrote $APP_CONF (mode 600)"

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
# all hit the server at the same minute.
JITTER=$(awk 'BEGIN{srand(); print int(rand()*60)}')
CRON_FILE="/etc/cron.d/auto-certs"
if [ -w "$(dirname "$CRON_FILE")" ] || [ -w "$CRON_FILE" ] 2>/dev/null; then
    cat > "$CRON_FILE" <<CRON
# auto-certs daily check — generated by install.sh
${JITTER} 3 * * * root ${INSTALL_ROOT}/launcher.sh >> ${LOG_ROOT}/cron.log 2>&1
CRON
    chmod 644 "$CRON_FILE"
    echo "auto-certs install: cron entry at $CRON_FILE (3:${JITTER} daily)"
else
    echo "auto-certs install: WARNING — could not write $CRON_FILE."
    echo "  Add this line to root's crontab manually:"
    echo "    ${JITTER} 3 * * * ${INSTALL_ROOT}/launcher.sh >> ${LOG_ROOT}/cron.log 2>&1"
fi

echo
echo "auto-certs install: DONE for $APP_CODE."
echo "  - Edit reload hook: $HOOK_PATH"
echo "  - Test now: ${INSTALL_ROOT}/launcher.sh --once --app ${APP_CODE}"
