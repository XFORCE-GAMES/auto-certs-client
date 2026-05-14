#!/bin/sh
# auto-certs installer.
#
# Two install paths — the public README documents the two-step path; the
# email-installer fast-path is documented ONLY in the install-instructions
# email body (private channel — not in the public README).
#
# === Public path (two-step, per docs/plans/install-flow-redesign.md) ===
#
#   STEP 1 — install (no secrets in argv, so nothing leaks to ~/.bash_history):
#     curl -sSL https://github.com/XFORCE-GAMES/auto-certs-client/releases/latest/download/install.sh \
#       | sudo sh -s -- --app <app_code>
#
#   STEP 2 — fill in the per-app config (the CP MIS pastes values from
#   the install-instructions email into the placeholder file dropped here):
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
# === Email-installer fast-path (one-line install, opt-in via --api-token + --bundle-password) ===
#
# When the per-app install email is sent (admin "Email install instructions
# to MIS" button, CHANGELOG §60), the email body includes a one-liner that
# pre-fills the conf with the credentials and uses `history -d` to scrub
# the line from shell history afterwards:
#
#   curl -sSL <release-url>/install.sh | sudo sh -s -- \
#     --app <app_code> \
#     --api-token '<API_TOKEN>' \
#     --bundle-password '<BUNDLE_PASSWORD>' \
#   ; history -d $(history 1 | awk '{print $1}') 2>/dev/null; history -w 2>/dev/null
#
# Tradeoff: the secrets ride argv (visible in `ps aux` during the brief
# install window — single-user CP boxes only) in exchange for skipping
# Step 2. The email itself already carries the secrets in plaintext so
# this path doesn't add new leak surface beyond the email channel.
# These flags are deliberately NOT advertised in the public README — the
# audience for the README is CP MIS auditing the install path, who
# should see the safe two-step flow first.
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
# Email-installer fast-path inputs (see header comment). Both required
# together when used; either both empty or both non-empty. Captured into
# the per-app conf during the WRITE STAGE below. Default empty → standard
# two-step flow (placeholder conf, CP MIS edits in Step 2).
API_TOKEN=""
BUNDLE_PASSWORD=""

usage() {
    cat <<USAGE
auto-certs install.sh — usage:

  install.sh \\
    --app <app_code> \\
    [--server-url <url>] \\
    [--source-dir <path>]   # for local testing — copy from here instead of net

Required: --app

By default the standard two-step flow applies: this installer drops a
placeholder /etc/auto-certs/conf.d/<app_code>.conf (mode 0600) with the
required fields blank; you edit that file to paste API_TOKEN and
BUNDLE_PASSWORD from the install-instructions email.

Email-installer fast-path (used by the install-instructions email):
    install.sh --app <app_code> \\
        --api-token '<API_TOKEN>' \\
        --bundle-password '<BUNDLE_PASSWORD>'
This populates the conf file directly, skipping Step 2. Both flags must
appear together. Caller is expected to scrub the command from shell
history afterwards (the email one-liner does this with \`history -d\`).

Multi-app on one host: re-run with --app <other_code>. Existing
configs are preserved (the secret lines are patched in if --api-token /
--bundle-password are passed; other fields are preserved as-is).
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --app)             APP_CODE="$2"; shift 2 ;;
        --server-url)      SERVER_URL="$2"; shift 2 ;;
        --source-dir)      SOURCE_DIR="$2"; shift 2 ;;
        --api-token)       API_TOKEN="$2"; shift 2 ;;
        --bundle-password) BUNDLE_PASSWORD="$2"; shift 2 ;;
        # Friendly hard-fails on legacy flag spellings — these had different
        # semantics in pre-§28 install.sh and exist here only to give a clear
        # error to anyone copy-pasting a stale one-liner. The new spellings
        # above (`--api-token`) replace `--token`; the per-app config-file
        # fields like `--base-domain`, `--cert-dir`, `--hook` are now in the
        # conf.d/<app>.conf file, not on the command line.
        --token|--base-domain|--cert-dir|--hook)
            echo "auto-certs install: --$(echo "$1" | sed 's/^--//') is no longer accepted on the command line." >&2
            echo "  See usage:" >&2
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

# --api-token and --bundle-password are paired: either both or neither.
if [ -n "$API_TOKEN" ] && [ -z "$BUNDLE_PASSWORD" ]; then
    echo "auto-certs install: --api-token requires --bundle-password (paired)" >&2
    exit 2
fi
if [ -z "$API_TOKEN" ] && [ -n "$BUNDLE_PASSWORD" ]; then
    echo "auto-certs install: --bundle-password requires --api-token (paired)" >&2
    exit 2
fi

# Reject app_codes that would trip the conf-file naming convention.
case "$APP_CODE" in
    *[!a-zA-Z0-9_-]*|""|.|..|*/*)
        echo "auto-certs install: --app must match [a-zA-Z0-9_-]+" >&2
        exit 2
        ;;
esac

# Default base_domain auto-derived from --app — `<app_code>.wakool.net` IS
# the per_app convention, and recording it as the placeholder example helps
# CP MIS recognise the typical shape. The line lands COMMENTED OUT in the
# placeholder conf; CPs who need to OVERRIDE the server's value (delegated
# CNAME / custom-domain setups) uncomment + edit. Issuance uses
# `apps.base_domain` directly (§81 regression test pins this), not a
# recomputed default — so even if the placeholder differs from the actual
# base_domain (shared / custom CPs), the runtime path is correct.
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
# CentOS 6 / old-trust-store hosts (§104 auto-detect, v0.4.0-rc5):
#   GitHub TLS doesn't validate against pre-2018 ca-certificates. Rather
#   than make the operator know about + opt into a special flag, install.sh
#   auto-detects via curl exit codes (60 / 35 / 51 / 58 / 77 = TLS-trust
#   failure) and falls back to fetching a fresh Mozilla CA bundle from
#   our own server (https://${SERVER_URL_HOST}/cacert.pem, refreshed daily
#   from curl.se by the auto-certs server's cron). The bundle fetch itself
#   is `--insecure` (TOFU same trust posture as the outer
#   `curl --insecure ... install.sh | sh`), but every subsequent fetch
#   uses `--cacert <bootstrap>` for proper TLS verification.
#
#   Manual override: AUTO_CERTS_INSECURE_BOOTSTRAP=1 — forces blanket
#   --insecure on every fetch from the start (skips the secure attempt).
#   Only useful for edge cases where even reaching our server requires
#   --insecure first (e.g. weird MITM proxy).
#
# Override repo / release for testing:
#   AUTO_CERTS_INSTALL_REPO    default: XFORCE-GAMES/auto-certs-client
#   AUTO_CERTS_INSTALL_RELEASE default: latest  (or a tag like v0.3.0-rc9)
if [ -z "$SOURCE_DIR" ]; then
    BOOT_TMP=$(mktemp -d)
    # Cleanup on any exit path. Single-quoted to defer $BOOT_TMP expansion
    # to trap-fire time (shellcheck SC2064). Functionally equivalent since
    # BOOT_TMP is never reassigned.
    trap 'rm -rf "$BOOT_TMP"' EXIT INT TERM
    GH_REPO="${AUTO_CERTS_INSTALL_REPO:-XFORCE-GAMES/auto-certs-client}"
    INS_FLAG=""; WGET_INS=""
    CACERT_FILE=""
    BOOTSTRAP_TRIED=0
    INSTALLED_CACERT="${INSTALL_ROOT}/cacert.pem"
    if [ "${AUTO_CERTS_INSECURE_BOOTSTRAP:-0}" = "1" ]; then
        INS_FLAG="--insecure"; WGET_INS="--no-check-certificate"
        echo "auto-certs install: WARNING — AUTO_CERTS_INSECURE_BOOTSTRAP=1; all fetches use --insecure (legacy override)." >&2
    fi
    # §104: try to bootstrap a fresh CA bundle from our server when system
    # CA fails. Idempotent — only attempted once per install run.
    _ac_try_bootstrap_cacert() {
        BOOTSTRAP_TRIED=1
        echo "" >&2
        echo "=================================================================" >&2
        echo "auto-certs install: system CA verification FAILED" >&2
        echo "auto-certs install:   → fetching fresh CA bundle from ${SERVER_URL}/cacert.pem" >&2
        echo "auto-certs install:   → TOFU posture (same trust as your outer" >&2
        echo "auto-certs install:     curl --insecure install.sh | sh); subsequent" >&2
        echo "auto-certs install:     fetches will use proper TLS verification" >&2
        echo "=================================================================" >&2
        _bootstrap_tmp="${BOOT_TMP}/cacert.pem.bootstrap"
        if ! curl --insecure -sSfL --connect-timeout 10 --max-time 30 \
                -o "$_bootstrap_tmp" "${SERVER_URL}/cacert.pem" 2>/dev/null; then
            echo "auto-certs install: cacert bootstrap fetch FAILED" >&2
            rm -f "$_bootstrap_tmp"
            return 1
        fi
        # Shape validation: at least 100 CERTIFICATE blocks + 100KB.
        # §105 (v0.4.0-rc6): grep pattern must NOT start with `-` —
        # CentOS 6's grep (from 2010) interprets `-----BEGIN CERTIFICATE-----`
        # as command-line flags rather than the search pattern. The shorter
        # `BEGIN CERTIFICATE` matches the same lines (every line that's
        # "-----BEGIN CERTIFICATE-----" contains "BEGIN CERTIFICATE") and
        # doesn't trigger the leading-dash quirk on any grep version.
        _cn=$(grep -c 'BEGIN CERTIFICATE' "$_bootstrap_tmp" 2>/dev/null || echo 0)
        _sz=$(wc -c < "$_bootstrap_tmp" 2>/dev/null || echo 0)
        if [ "$_cn" -lt 100 ] || [ "$_sz" -lt 100000 ]; then
            echo "auto-certs install: bootstrap cacert validation FAILED (certs=$_cn, size=$_sz); refusing" >&2
            rm -f "$_bootstrap_tmp"
            return 1
        fi
        # Save to permanent location so the runtime (updater.sh + auto_certs.sh)
        # uses it from here on.
        mkdir -p "$(dirname "$INSTALLED_CACERT")" 2>/dev/null
        if ! mv "$_bootstrap_tmp" "$INSTALLED_CACERT"; then
            echo "auto-certs install: could not write $INSTALLED_CACERT" >&2
            rm -f "$_bootstrap_tmp"
            return 1
        fi
        chmod 0644 "$INSTALLED_CACERT" 2>/dev/null || true
        CACERT_FILE="$INSTALLED_CACERT"
        echo "auto-certs install: bootstrap CA ($_cn certs, $_sz bytes) saved to $INSTALLED_CACERT" >&2
        echo "" >&2
        return 0
    }
    _ac_fetch() {  # _ac_fetch <url> <out>
        if command -v curl >/dev/null 2>&1; then
            # Build CA arg from current state.
            _ca_arg=""
            if [ -n "$CACERT_FILE" ] && [ -r "$CACERT_FILE" ]; then
                _ca_arg="--cacert $CACERT_FILE"
            elif [ -n "$INS_FLAG" ]; then
                _ca_arg="$INS_FLAG"
            fi
            # shellcheck disable=SC2086  # _ca_arg must word-split
            curl -sSL --fail $_ca_arg "$1" -o "$2"
            _rc=$?
            if [ "$_rc" -eq 0 ]; then return 0; fi
            # §104: on TLS-trust failures, try to bootstrap a fresh CA
            # bundle from our server (once), then retry.
            case "$_rc" in
                60|35|51|58|77)
                    if [ "$BOOTSTRAP_TRIED" -eq 0 ] && [ -z "$CACERT_FILE" ] && [ -z "$INS_FLAG" ]; then
                        if _ac_try_bootstrap_cacert; then
                            curl -sSL --fail --cacert "$CACERT_FILE" "$1" -o "$2"
                            return $?
                        fi
                    fi
                    ;;
            esac
            return "$_rc"
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

# §104 (v0.4.0-rc5): seed /opt/auto-certs/cacert.pem if not already set up
# by the bootstrap path. Modern hosts (where _ac_fetch succeeded with
# system CA) didn't go through _ac_try_bootstrap_cacert, so the file
# doesn't exist yet. Seed from the bundled payload so updater.sh has
# something to refresh on the next tick.
if [ ! -f "${INSTALL_ROOT}/cacert.pem" ] && [ -r "$PAYLOAD_DEST/lib/cacert.pem" ]; then
    cp "$PAYLOAD_DEST/lib/cacert.pem" "${INSTALL_ROOT}/cacert.pem"
    chmod 0644 "${INSTALL_ROOT}/cacert.pem" 2>/dev/null || true
    echo "auto-certs install: seeded ${INSTALL_ROOT}/cacert.pem from bundled payload"
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

# --- WRITE STAGE: ensure conf file exists --------------------------------
# The conf file is created if absent. CP edits are preserved on re-run
# (the secret-patch step below is the ONLY thing that touches an existing
# conf, and only when --api-token / --bundle-password are explicitly
# provided on this invocation).
CONF_DROPPED_THIS_RUN=0
if [ -f "$APP_CONF" ]; then
    : # exists — preserve as-is; secret-patch step may patch in below.
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
    CONF_DROPPED_THIS_RUN=1
    echo "auto-certs install: dropped placeholder $APP_CONF (mode 600)"
else
    # Fallback: emit a minimal placeholder inline so the installer is
    # robust against a missing/renamed template.
    {
        echo "# auto-certs per-app config — created by install.sh on $(date)"
        echo "# EDIT the EMPTY fields below, save, then verify with:"
        echo "#   sudo ${INSTALL_ROOT}/launcher.sh --once --app ${APP_CODE}"
        echo ""
        echo "APP_CODE=${APP_CODE}"
        echo "SERVER_URL=${SERVER_URL}"
        echo ""
        echo "# BASE_DOMAIN is optional since v0.3.0-rc14 — server returns it"
        echo "# in /api/v1/check. Set this only to OVERRIDE."
        echo "# BASE_DOMAIN=${BASE_DOMAIN_DEFAULT}"
        echo ""
        echo "# === REQUIRED — paste from the install-instructions email ==="
        echo "API_TOKEN="
        echo "BUNDLE_PASSWORD="
        echo ""
        echo "# === Optional ==="
        echo "# CERT_DIR=${ETC_ROOT}/<server-base-domain>"
        echo "# HOOK_PATH=${HOOK_PATH_DEFAULT}"
        echo "# HOOK_TIMEOUT_SECONDS=60"
        echo "# JKS_PASSWORD="
        echo "# LOCAL_TLS_TARGETS=\"127.0.0.1:443\""
    } > "${APP_CONF}.tmp"
    mv "${APP_CONF}.tmp" "$APP_CONF"
    chmod 600 "$APP_CONF"
    CONF_DROPPED_THIS_RUN=1
    echo "auto-certs install: dropped placeholder $APP_CONF (mode 600; inline fallback)"
fi

# --- PATCH STAGE: populate API_TOKEN + BUNDLE_PASSWORD if provided -------
# Only runs when both --api-token and --bundle-password were on the
# command line (paired check above). Other CP edits (CERT_DIR, HOOK_PATH,
# JKS_PASSWORD, LOCAL_TLS_TARGETS, …) are preserved by filtering the
# existing file and appending the new secret lines at the end. Using
# `printf '%s\n'` avoids any shell-interpolation / sed-escaping concerns
# regardless of what charset the token / password use.
if [ -n "$API_TOKEN" ] && [ -n "$BUNDLE_PASSWORD" ]; then
    {
        # `|| true` because grep -v returns non-zero when its filter eats
        # all input lines (impossible with our conf shape, but harmless).
        grep -v -E '^(API_TOKEN|BUNDLE_PASSWORD)=' "$APP_CONF" || true
        echo ""
        echo "# Set by install.sh --api-token / --bundle-password on $(date)"
        printf 'API_TOKEN=%s\n' "$API_TOKEN"
        printf 'BUNDLE_PASSWORD=%s\n' "$BUNDLE_PASSWORD"
    } > "${APP_CONF}.tmp"
    mv "${APP_CONF}.tmp" "$APP_CONF"
    chmod 600 "$APP_CONF"
    echo "auto-certs install: populated API_TOKEN and BUNDLE_PASSWORD in $APP_CONF"
elif [ "$CONF_DROPPED_THIS_RUN" = "1" ]; then
    echo "auto-certs install: EDIT $APP_CONF — set API_TOKEN= and BUNDLE_PASSWORD= from the install-instructions email."
else
    echo "auto-certs install: $APP_CONF already exists — preserving CP edits."
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
# If the email-installer fast-path populated the conf already, skip the
# edit-config step — telling the CP MIS to edit a file we just filled
# in is confusing. Step numbering re-flows accordingly.
_step=1
if [ -z "$API_TOKEN" ] || [ -z "$BUNDLE_PASSWORD" ]; then
    echo "  ${_step}. EDIT ${APP_CONF}"
    echo "       set API_TOKEN= and BUNDLE_PASSWORD= from the install-instructions email."
    _step=$((_step + 1))
fi
echo "  ${_step}. EDIT ${HOOK_PATH_DEFAULT}"
echo "       replace the 'exit 1' default with your reload command."
_step=$((_step + 1))
echo "  ${_step}. TEST: sudo ${INSTALL_ROOT}/launcher.sh --once --app ${APP_CODE}"
