# auto-certs HTTP client — POSIX sh, curl-or-wget abstraction.
# Sourced (not executed).
#
# We construct argument lists via `set --` / `"$@"` so that values
# containing whitespace (e.g. the bearer token if it ever contained
# them; or the User-Agent string with embedded spaces) survive without
# shell-mangling. The earlier `_auth="-H Authorization:Bearer\\ $_token"`
# + unquoted-expansion pattern was buggy — the literal backslash
# survived and curl received a malformed header name.

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
        # Build the args list. `set --` resets "$@" to the listed
        # values; subsequent `set -- "$@" ...` appends. Quoting around
        # each "$@" reference is required to preserve whitespace.
        set -- --silent --show-error --fail-with-body \
               --user-agent "auto-certs/$(payload_version 2>/dev/null || echo 0.0.0)" \
               --connect-timeout 10 --max-time 60 \
               --dump-header "$_hdrout" \
               -o "$_out"
        if [ -n "$_token" ]; then
            set -- "$@" -H "Authorization: Bearer $_token"
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

# http_post_json <url> <payload_file> [bearer_token]
# Returns 0 on 2xx.
http_post_json() {
    _url="$1"
    _payload="$2"
    _token="${3:-}"
    _resp="${_payload}.resp"

    if command -v curl >/dev/null 2>&1; then
        set -- --silent --show-error --fail-with-body \
               --user-agent "auto-certs/$(payload_version 2>/dev/null || echo 0.0.0)" \
               --connect-timeout 10 --max-time 60 \
               -H "Content-Type: application/json" \
               --data-binary "@$_payload" \
               -o "$_resp"
        if [ -n "$_token" ]; then
            set -- "$@" -H "Authorization: Bearer $_token"
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
        set -- "$@" "$_url"
        wget "$@"
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
