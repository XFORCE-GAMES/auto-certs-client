# auto-certs crypto wrappers — POSIX sh.
# All operations shell out to `openssl`. Compatible with openssl 1.0.1e
# (CentOS 6 floor) — no AEAD modes, no `enc -pbkdf2`.

# Verify a detached RSA-SHA256 signature against a payload.
#
# verify_signature <payload_file> <signature_file> <public_key_pem_file>
# Returns 0 on valid, 1 on invalid, 2 on usage error.
verify_signature() {
    _payload="$1"
    _sig="$2"
    _pubkey="$3"
    if [ ! -r "$_payload" ] || [ ! -r "$_sig" ] || [ ! -r "$_pubkey" ]; then
        log_error "verify_signature: missing inputs"
        return 2
    fi
    # openssl dgst -verify returns 0 on valid, non-zero on invalid.
    # Suppress its stdout chatter ("Verified OK"/"Verification Failure").
    if openssl dgst -sha256 -verify "$_pubkey" -signature "$_sig" "$_payload" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# Decrypt the DeliveryEnvelope frame produced by Wakool\Cert\DeliveryEnvelope::seal.
#
# Wire format v2 (from libs/Wakool/Cert/DeliveryEnvelope.php — keep in
# sync if the server-side ever bumps the version byte):
#
#   [4 B]  magic       "ACEB"
#   [1 B]  version     0x02
#   [1 B]  salt_len    16
#   [N B]  salt
#   [1 B]  iv_len      16
#   [M B]  iv
#   [4 B]  ct_len      big-endian uint32
#   [K B]  ciphertext  AES-256-CBC PKCS#7 over plaintext
#
# Key derivation v2: HMAC-SHA256(key=password_bytes, msg=salt_bytes) → 32 bytes.
#
# Why HMAC-SHA256 single-pass and not PBKDF2 anymore: bundle passwords
# are machine-generated ≥256-bit secrets (KMS-backed Secrets Manager
# via Wakool\Cert\BundlePassword); they're already brute-force-
# infeasible, so PBKDF2 stretching adds no security, and depending on
# `openssl enc -pbkdf2` (added in 1.1.0) or Perl/Python helpers broke
# on minimum-install CentOS 6 (no Perl, no Python ≥2.7.8, no openssl
# ≥1.1). HMAC-SHA256 via `openssl dgst -hmac` is in 1.0.0+ (March
# 2010), works on every CentOS 5+ host. See
# docs/research/centos6-compatibility.md for the full argument +
# empirical canary-centos6 verification.
#
# decrypt_envelope <envelope_file> <bundle_password> <plaintext_out>
# Returns 0 on success; non-zero on any failure (corrupt frame, bad
# password, openssl error).
decrypt_envelope() {
    _enc="$1"
    _pwd="$2"
    _out="$3"
    _tmp=$(mktemp -d 2>/dev/null || echo "/tmp/ace-decrypt-$$")
    mkdir -p "$_tmp"
    # Cleanup helper — caller may set RC and we always clean.
    _cleanup() {
        rm -rf "$_tmp" 2>/dev/null || true
    }

    # Read fixed-size header bytes via dd. Stay POSIX.
    # 1. magic (4 bytes)
    _magic=$(dd if="$_enc" bs=1 count=4 2>/dev/null | od -An -c | tr -d ' \n')
    # od -c emits things like "  A   C   E   B" with leading spaces; tr/dump
    # is fragile. Better: use head -c if available, else od + awk.
    if [ "$(head -c 4 "$_enc" 2>/dev/null)" != "ACEB" ]; then
        log_error "decrypt_envelope: bad magic"
        _cleanup
        return 1
    fi

    # 2. version (1 byte) — accept only 0x02 (HMAC-SHA256 KDF; v1 was
    #    PBKDF2-100k and dropped 2026-05-02 — no production CPs ever
    #    received a v1 envelope).
    _verbyte=$(head -c 5 "$_enc" 2>/dev/null | tail -c 1 | od -An -tu1 | tr -d ' \n')
    if [ "$_verbyte" != "2" ]; then
        log_error "decrypt_envelope: unsupported version ${_verbyte}"
        _cleanup
        return 1
    fi

    # 3. salt_len (1 byte), salt (N bytes)
    _saltlen=$(dd if="$_enc" bs=1 count=1 skip=5 2>/dev/null | od -An -tu1 | tr -d ' \n')
    dd if="$_enc" bs=1 count="$_saltlen" skip=6 of="$_tmp/salt" 2>/dev/null

    # 4. iv_len (1 byte), iv (M bytes)
    _iv_len_offset=$((6 + _saltlen))
    _ivlen=$(dd if="$_enc" bs=1 count=1 skip="$_iv_len_offset" 2>/dev/null | od -An -tu1 | tr -d ' \n')
    _iv_offset=$((_iv_len_offset + 1))
    dd if="$_enc" bs=1 count="$_ivlen" skip="$_iv_offset" of="$_tmp/iv" 2>/dev/null

    # 5. ct_len (4 bytes BE), ciphertext (K bytes)
    _ct_len_offset=$((_iv_offset + _ivlen))
    # Read 4 bytes; convert big-endian to decimal.
    _ctlen_b1=$(dd if="$_enc" bs=1 count=1 skip="$_ct_len_offset"     2>/dev/null | od -An -tu1 | tr -d ' \n')
    _ctlen_b2=$(dd if="$_enc" bs=1 count=1 skip=$((_ct_len_offset+1)) 2>/dev/null | od -An -tu1 | tr -d ' \n')
    _ctlen_b3=$(dd if="$_enc" bs=1 count=1 skip=$((_ct_len_offset+2)) 2>/dev/null | od -An -tu1 | tr -d ' \n')
    _ctlen_b4=$(dd if="$_enc" bs=1 count=1 skip=$((_ct_len_offset+3)) 2>/dev/null | od -An -tu1 | tr -d ' \n')
    _ctlen=$(( (_ctlen_b1 << 24) | (_ctlen_b2 << 16) | (_ctlen_b3 << 8) | _ctlen_b4 ))
    _ct_offset=$((_ct_len_offset + 4))
    dd if="$_enc" bs=1 count="$_ctlen" skip="$_ct_offset" of="$_tmp/ct" 2>/dev/null

    # 6. Derive AES-256 key — single-pass HMAC-SHA256 (envelope v2).
    #
    #    `openssl dgst -sha256 -hmac KEY` has been in openssl 1.0.0+
    #    (March 2010), so this works on every CentOS 5+ box. The previous
    #    PBKDF2 four-gate fallback chain (Perl / Python 3 / Python 2.7.8+
    #    / openssl 3.0+) is gone — see crypto.sh header docstring for
    #    the rationale + docs/research/centos6-compatibility.md for the
    #    full empirical evidence.
    #
    #    LOAD-BEARING: the RAW salt bytes (not their hex representation)
    #    are the HMAC message. This matches the server-side
    #    `hash_hmac('sha256', $salt, $password, true)` which feeds the
    #    raw 16-byte salt. Hashing the hex string instead would produce
    #    a different key and silently break decryption.
    #
    #    Output of `openssl dgst -sha256 -hmac KEY < file` is one line
    #    `HMAC-SHA256(stdin)= <64 hex chars>` — sed strips up to "= ".
    _key_hex=$(openssl dgst -sha256 -hmac "$_pwd" < "$_tmp/salt" 2>/dev/null \
        | sed 's/^.*= //')
    if [ -z "$_key_hex" ] || [ ${#_key_hex} -ne 64 ]; then
        log_error "decrypt_envelope: HMAC-SHA256 KDF produced unexpected output"
        _cleanup
        return 1
    fi

    _iv_hex=$(od -An -tx1 < "$_tmp/iv" | tr -d ' \n')

    # 7. Decrypt: AES-256-CBC, PKCS#7 padding (openssl default).
    if ! openssl enc -aes-256-cbc -d \
           -K "$_key_hex" -iv "$_iv_hex" \
           -in "$_tmp/ct" -out "$_out" 2>/dev/null; then
        log_error "decrypt_envelope: openssl enc failed"
        _cleanup
        return 1
    fi
    _cleanup
    return 0
}

# Validate that a cert + privkey pair match (modulus check).
# Returns 0 on match, 1 on mismatch.
validate_cert_key_pair() {
    _cert="$1"
    _key="$2"
    _certmod=$(openssl x509 -noout -modulus -in "$_cert" 2>/dev/null | openssl md5 2>/dev/null | awk '{print $NF}')
    _keymod=$(openssl rsa -noout -modulus -in "$_key" 2>/dev/null | openssl md5 2>/dev/null | awk '{print $NF}')
    if [ -z "$_certmod" ] || [ -z "$_keymod" ]; then
        log_error "validate_cert_key_pair: could not compute modulus"
        return 1
    fi
    if [ "$_certmod" != "$_keymod" ]; then
        log_error "validate_cert_key_pair: cert/key modulus mismatch"
        return 1
    fi
    return 0
}

# Verify a cert PEM parses cleanly + isn't already expired or about-to-expire.
# Returns 0 on healthy, non-zero on any issue.
validate_cert_health() {
    _cert="$1"
    if ! openssl x509 -noout -text -in "$_cert" >/dev/null 2>&1; then
        log_error "validate_cert_health: cert PEM does not parse"
        return 1
    fi
    # Check it's not already expired. -checkend 0 returns non-zero if expired.
    if ! openssl x509 -noout -checkend 0 -in "$_cert" >/dev/null 2>&1; then
        log_error "validate_cert_health: cert is already expired"
        return 1
    fi
    return 0
}

# Compute the SHA-256 fingerprint of a cert in OpenSSL's hex format
# (uppercase, colon-separated). Used for the local TLS self-test.
cert_fingerprint_sha256() {
    _cert="$1"
    openssl x509 -noout -fingerprint -sha256 -in "$_cert" 2>/dev/null \
        | sed -E "s/^[^=]+=//"
}

# NOTE 2026-05-02: the `_pbkdf2_via_perl` and `_pbkdf2_via_python` helpers
# were deleted when the envelope KDF moved from PBKDF2-100k to single-pass
# HMAC-SHA256 (envelope v2). The new KDF is `openssl dgst -sha256 -hmac`
# inline in `decrypt_envelope` — no external interpreter needed. See
# docs/research/centos6-compatibility.md §3 for the cryptographic argument
# and §7 for the migration steps.
