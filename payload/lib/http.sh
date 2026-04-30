# auto-certs HTTP client — POSIX sh, curl-or-wget abstraction.
# Sourced (not executed).

# http_get <url> <output_file> [bearer_token] [extra_header_file]
#
# Returns 0 on 2xx, non-zero on any other status / network failure.
# Writes the response body to <output_file>. Writes captured response
# headers to <output_file>.headers (so caller can read X-Bundle-Hash etc.).
http_get() {
    _url="$1"
    _out="$2"
    _token="${3:-}"
    _hdrout="${_out}.headers"

    if command -v curl >/dev/null 2>&1; then
        _auth=""
        if [ -n "$_token" ]; then
            _auth="-H Authorization:Bearer\\ $_token"
        fi
        # We use curl's --dump-header to capture response headers.
        # eval is needed only because we want to splice $_auth conditionally;
        # shell quoting around $_token is correct because we already
        # ensured no shell-meaningful chars are present (token is acert_live_+base62).
        # shellcheck disable=SC2086
        curl --silent --show-error --fail-with-body \
             --user-agent "auto-certs/$(payload_version 2>/dev/null || echo 0.0.0)" \
             --connect-timeout 10 --max-time 60 \
             --dump-header "$_hdrout" \
             $_auth \
             -o "$_out" \
             "$_url"
        return $?
    fi
    if command -v wget >/dev/null 2>&1; then
        _auth=""
        if [ -n "$_token" ]; then
            _auth="--header=Authorization:\\ Bearer\\ $_token"
        fi
        # wget doesn't write response headers as cleanly; use --server-response
        # which emits them on stderr, capture there.
        # shellcheck disable=SC2086
        wget --quiet \
             --user-agent="auto-certs/$(payload_version 2>/dev/null || echo 0.0.0)" \
             --connect-timeout=10 --read-timeout=60 \
             --server-response \
             $_auth \
             -O "$_out" \
             "$_url" 2> "$_hdrout"
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

# http_post_json <url> <payload_file> [bearer_token]
# Returns 0 on 2xx.
http_post_json() {
    _url="$1"
    _payload="$2"
    _token="${3:-}"
    _resp="${_payload}.resp"

    if command -v curl >/dev/null 2>&1; then
        _auth=""
        if [ -n "$_token" ]; then
            _auth="-H Authorization:Bearer\\ $_token"
        fi
        # shellcheck disable=SC2086
        curl --silent --show-error --fail-with-body \
             --user-agent "auto-certs/$(payload_version 2>/dev/null || echo 0.0.0)" \
             --connect-timeout 10 --max-time 60 \
             -H "Content-Type: application/json" \
             $_auth \
             --data-binary "@$_payload" \
             -o "$_resp" \
             "$_url"
        return $?
    fi
    if command -v wget >/dev/null 2>&1; then
        _hdrs="--header=Content-Type:\\ application/json"
        if [ -n "$_token" ]; then
            _hdrs="$_hdrs --header=Authorization:\\ Bearer\\ $_token"
        fi
        # shellcheck disable=SC2086
        wget --quiet \
             --user-agent="auto-certs/$(payload_version 2>/dev/null || echo 0.0.0)" \
             --connect-timeout=10 --read-timeout=60 \
             $_hdrs \
             --post-file="$_payload" \
             -O "$_resp" \
             "$_url"
        return $?
    fi
    log_error "neither curl nor wget available"
    return 1
}

# Read VERSION from the payload directory (relative to this lib dir).
payload_version() {
    _verfile="$(dirname "$(dirname "$0")")/VERSION"
    if [ -r "$_verfile" ]; then
        head -n 1 "$_verfile"
    else
        echo "0.0.0"
    fi
}
