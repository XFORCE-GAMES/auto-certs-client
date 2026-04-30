#!/bin/sh
# auto-certs launcher.
#
# Locates the active payload, integrity-checks it against the install-time
# checksum, then execs it. Treated as IMMUTABLE post-install — Phase 6's
# staged-rollout updates only the payload directory, never this file.
#
# This script must NEVER break. A bad launcher strands every CP that has
# us installed. Therefore: tiny (≤50 lines), POSIX-only, no clever bits,
# no language features past `set -eu` and `exec`.
#
# Exit codes (also documented in payload/lib/common.sh):
#   0   payload exec'd successfully (so we never see this — exec replaces us)
#   1   payload binary missing or not executable
#   2   payload checksum mismatch
#   3   neither sha256sum nor shasum available

set -eu

PAYLOAD_DIR="${AUTO_CERTS_PAYLOAD_DIR:-/opt/auto-certs/current}"
PAYLOAD_BIN="$PAYLOAD_DIR/auto_certs.sh"
CHECKSUM_FILE="$PAYLOAD_DIR/auto_certs.sh.sha256"

if [ ! -x "$PAYLOAD_BIN" ]; then
    echo "auto-certs launcher: payload missing or not executable: $PAYLOAD_BIN" >&2
    exit 1
fi

# Integrity check — only enforced if the sidecar exists. Install-time and
# Phase 6 staged updates write it; missing is treated as a fresh install
# that hasn't pinned yet (warn + proceed).
if [ -r "$CHECKSUM_FILE" ]; then
    EXPECTED=$(awk '{print $1}' "$CHECKSUM_FILE")
    # Linux has sha256sum; macOS / BSD have `shasum -a 256`. Try in order.
    if command -v sha256sum >/dev/null 2>&1; then
        ACTUAL=$(sha256sum "$PAYLOAD_BIN" | awk '{print $1}')
    elif command -v shasum >/dev/null 2>&1; then
        ACTUAL=$(shasum -a 256 "$PAYLOAD_BIN" | awk '{print $1}')
    else
        echo "auto-certs launcher: neither sha256sum nor shasum found" >&2
        exit 3
    fi
    if [ "$EXPECTED" != "$ACTUAL" ]; then
        echo "auto-certs launcher: payload checksum mismatch" >&2
        echo "  expected: $EXPECTED" >&2
        echo "  actual:   $ACTUAL" >&2
        exit 2
    fi
else
    echo "auto-certs launcher: warning — no checksum sidecar at $CHECKSUM_FILE" >&2
fi

exec "$PAYLOAD_BIN" "$@"
