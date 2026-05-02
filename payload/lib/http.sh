# auto-certs HTTP client — POSIX sh, curl-or-wget abstraction.
# Sourced (not executed).
#
# We construct argument lists via `set --` / `"$@"` so that values
# containing whitespace (e.g. the bearer token if it ever contained
# them; or the User-Agent string with embedded spaces) survive without
# shell-mangling. The earlier `_auth="-H Authorization:Bearer\\ $_token"`
# + unquoted-expansion pattern was buggy — the literal backslash
# survived and curl received a malformed header name.
#
# Curl flag floor: --fail (1996, curl 7.0). NOT --fail-with-body
# (curl 7.76, April 2021) — the floor fleet has curl 7.19.7 (CentOS 6),
# 7.29.0 (CentOS 7), 7.47.0 (Ubuntu 16). A regression to a post-7.76
# flag would silently fail every API call on those hosts; the smoke
# test `cli/test/client_curl_floor_compat_test.php` is the guard.

# http_get <url> <output_file> [bearer_token] [extra_header_file]
#
# Returns 0 on 2xx, non-zero on any other status / network failure.
# Writes the response body to <output_file>. Writes captured response
# headers to <output_file>.headers (so caller can read X-Bundle-Hash etc.).
#
# extra_header_file (optional, since v0.3.0-rc3): path to a file with
# one `Header: value` line per row. Blank lines + lines starting with
# `#` are skipped. Each line is appended to the request as `-H` (curl)
# or `--header=` (wget). Used by `updater.sh` to send
# `X-Auto-Certs-Running-Ref` to /launcher_check.
http_get() {
    _url="$1"
    _out="$2"
    _token="${3:-}"
    _extra_hdr_file="${4:-}"
    _hdrout="${_out}.headers"

    if command -v curl >/dev/null 2>&1; then
        # Build the args list. `set --` resets "$@" to the listed
        # values; subsequent `set -- "$@" ...` appends. Quoting around
        # each "$@" reference is required to preserve whitespace.
        #
        # --location follows 30x redirects — load-bearing for GitHub
        # release downloads which always 302 from
        # github.com/.../releases/download/... to
        # objects.githubusercontent.com/.../. Without it the body never
        # lands on disk and verify_signature trips "missing inputs".
        # wget follows redirects by default; only curl needs the flag.
        set -- --silent --show-error --fail --location \
               --user-agent "auto-certs/$(payload_version 2>/dev/null || echo 0.0.0)" \
               --connect-timeout 10 --max-time 60 \
               --dump-header "$_hdrout" \
               -o "$_out"
        if [ -n "$_token" ]; then
            set -- "$@" -H "Authorization: Bearer $_token"
        fi
        if [ -n "$_extra_hdr_file" ] && [ -r "$_extra_hdr_file" ]; then
            # `|| [ -n "$_hline" ]` handles a trailing-newline-less last line.
            while IFS= read -r _hline || [ -n "$_hline" ]; do
                [ -z "$_hline" ] && continue
                case "$_hline" in
                    \#*) continue ;;
                esac
                set -- "$@" -H "$_hline"
            done < "$_extra_hdr_file"
        fi
        set -- "$@" "$_url"
        curl "$@"
        return $?
    fi
    if command -v wget >/dev/null 2>&1; then
        # wget doesn't write response headers as cleanly; use --server-response
        # which emits them on stderr, capture there.
        set -- --quiet \
               --user-agent="auto-certs/$(payload_version 2>/dev/null || echo 0.0.0)" \
               --connect-timeout=10 --read-timeout=60 \
               --server-response \
               -O "$_out"
        if [ -n "$_token" ]; then
            set -- "$@" --header="Authorization: Bearer $_token"
        fi
        if [ -n "$_extra_hdr_file" ] && [ -r "$_extra_hdr_file" ]; then
            while IFS= read -r _hline || [ -n "$_hline" ]; do
                [ -z "$_hline" ] && continue
                case "$_hline" in
                    \#*) continue ;;
                esac
                set -- "$@" --header="$_hline"
            done < "$_extra_hdr_file"
        fi
        set -- "$@" "$_url"
        wget "$@" 2> "$_hdrout"
        return $?
    fi
    log_error "neither curl nor wget available"
    return 1
}

# Read a header value from <output_file>.headers. Returns empty if not found.
http_header_value() {
    _hdrfile="$1"
    _name="$2"
    if [ ! -r "$_hdrfile" ]; then
        echo ""
        return 0
    fi
    # Headers may be multi-line; just look for the last occurrence.
    grep -i "^${_name}:" "$_hdrfile" 2>/dev/null \
        | tail -n 1 \
        | sed -E "s/^[^:]+:[[:space:]]*//" \
        | tr -d '\r'
}

# http_post_json <url> <payload_file> [bearer_token] [extra_header_file]
# Returns 0 on 2xx.
#
# extra_header_file (optional, since v0.3.0-rc3): same shape as
# http_get's — one `Header: value` line per row, blank/`#` lines
# skipped. Forward-looking parity for the `X-Auto-Certs-Running-Ref`
# pipeline; not yet wired up by /report or /self_check_report callers.
http_post_json() {
    _url="$1"
    _payload="$2"
    _token="${3:-}"
    _extra_hdr_file="${4:-}"
    _resp="${_payload}.resp"

    if command -v curl >/dev/null 2>&1; then
        set -- --silent --show-error --fail \
               --user-agent "auto-certs/$(payload_version 2>/dev/null || echo 0.0.0)" \
               --connect-timeout 10 --max-time 60 \
               -H "Content-Type: application/json" \
               --data-binary "@$_payload" \
               -o "$_resp"
        if [ -n "$_token" ]; then
            set -- "$@" -H "Authorization: Bearer $_token"
        fi
        if [ -n "$_extra_hdr_file" ] && [ -r "$_extra_hdr_file" ]; then
            while IFS= read -r _hline || [ -n "$_hline" ]; do
                [ -z "$_hline" ] && continue
                case "$_hline" in
                    \#*) continue ;;
                esac
                set -- "$@" -H "$_hline"
            done < "$_extra_hdr_file"
        fi
        set -- "$@" "$_url"
        curl "$@"
        return $?
    fi
    if command -v wget >/dev/null 2>&1; then
        set -- --quiet \
               --user-agent="auto-certs/$(payload_version 2>/dev/null || echo 0.0.0)" \
               --connect-timeout=10 --read-timeout=60 \
               --header="Content-Type: application/json" \
               --post-file="$_payload" \
               -O "$_resp"
        if [ -n "$_token" ]; then
            set -- "$@" --header="Authorization: Bearer $_token"
        fi
        if [ -n "$_extra_hdr_file" ] && [ -r "$_extra_hdr_file" ]; then
            while IFS= read -r _hline || [ -n "$_hline" ]; do
                [ -z "$_hline" ] && continue
                case "$_hline" in
                    \#*) continue ;;
                esac
                set -- "$@" --header="$_hline"
            done < "$_extra_hdr_file"
        fi
        set -- "$@" "$_url"
        wget "$@"
        return $?
    fi
    log_error "neither curl nor wget available"
    return 1
}

# Read VERSION from the payload directory.
#
# `$0` in shell is the calling script's path (sourcing this lib does NOT
# change $0). The caller is `auto_certs.sh` which lives at
# `<payload_dir>/auto_certs.sh`, so one `dirname` lands on the payload
# directory where VERSION is sibling. Two dirname's (the original code)
# would skip past the payload dir to its parent — a real bug that
# surfaced during Phase 6 first-rollout: payload_version() returned
# "0.0.0" because it was reading a non-existent /opt/auto-certs/VERSION
# instead of /opt/auto-certs/current/VERSION.
#
# Fallback override `AUTO_CERTS_PAYLOAD_DIR` lets edge invocations point
# at an explicit dir (e.g. updater.sh post-flip when $0 isn't auto_certs.sh).
payload_version() {
    _payload_dir="${AUTO_CERTS_PAYLOAD_DIR:-$(dirname "$0")}"
    _verfile="${_payload_dir}/VERSION"
    if [ -r "$_verfile" ]; then
        head -n 1 "$_verfile"
    else
        echo "0.0.0"
    fi
}
