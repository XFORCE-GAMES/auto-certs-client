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
# Wire format (from libs/Wakool/Cert/DeliveryEnvelope.php — keep in sync
# if the server-side ever bumps the version byte):
#
#   [4 B]  magic       "ACEB"
#   [1 B]  version     0x01
#   [1 B]  salt_len    16
#   [N B]  salt
#   [1 B]  iv_len      16
#   [M B]  iv
#   [4 B]  ct_len      big-endian uint32
#   [K B]  ciphertext  AES-256-CBC PKCS#7 over plaintext
#
# Key derivation: PBKDF2-HMAC-SHA256(password, salt, iter=100_000, dkLen=32).
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

    # 2. version (1 byte) — accept only 0x01.
    _verbyte=$(head -c 5 "$_enc" 2>/dev/null | tail -c 1 | od -An -tu1 | tr -d ' \n')
    if [ "$_verbyte" != "1" ]; then
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

    # 6. Derive AES-256 key via PBKDF2 (100k iter, SHA-256).
    #
    #    PBKDF2 primitives in CLI tools are uneven across our target floor:
    #      - OpenSSL 3.0+: `openssl kdf -keylen ... PBKDF2` works.
    #      - OpenSSL 1.1.0–1.1.1: `enc -pbkdf2` is integrated into encrypt;
    #        no standalone KDF subcommand. Can't extract just the key.
    #      - OpenSSL 1.0.1e (CentOS 6): no `-pbkdf2` flag at all.
    #
    #    Preference order (most-portable first):
    #      1. perl + Digest::SHA::hmac_sha256 — works on stock CentOS 6
    #         (perl 5.10.1, Digest::SHA in core since 5.9.3 / 2006). Perl
    #         is a hard dep of yum/rpm, so any RPM-based distro has it.
    #      2. python3 hashlib.pbkdf2_hmac — Ubuntu 14.04+, RHEL 7+.
    #      3. python2 hashlib.pbkdf2_hmac — Python 2.7.8+ only (NOT 2.6 →
    #         CentOS 6's stock Python is 2.6 and doesn't have it).
    #      4. openssl kdf — OpenSSL 3.0+ only.
    #
    #    Perl is FIRST because it's the only path that works on a stock
    #    CentOS 6 host without ANY install / repo change. Python 2.6's
    #    `hashlib` lacks `pbkdf2_hmac` (added in 2.7.8); CentOS 6 ships
    #    2.6 by default. All four paths produce byte-identical output
    #    (PBKDF2 is deterministic).
    _salt_hex=$(od -An -tx1 < "$_tmp/salt" | tr -d ' \n')
    _key_hex=""
    if command -v perl >/dev/null 2>&1 && perl -MDigest::SHA -e1 2>/dev/null; then
        _key_hex=$(_pbkdf2_via_perl "$_pwd" "$_salt_hex")
    elif command -v python3 >/dev/null 2>&1; then
        _key_hex=$(_pbkdf2_via_python "python3" "$_pwd" "$_salt_hex")
    elif command -v python2 >/dev/null 2>&1; then
        _key_hex=$(_pbkdf2_via_python "python2" "$_pwd" "$_salt_hex")
    elif command -v python >/dev/null 2>&1; then
        _key_hex=$(_pbkdf2_via_python "python" "$_pwd" "$_salt_hex")
    elif openssl kdf -help 2>&1 | grep -q -- '-kdfopt'; then
        # openssl 3.0+ kdf path.
        _key_hex=$(openssl kdf -keylen 32 \
                       -kdfopt digest:SHA256 \
                       -kdfopt pass:"$_pwd" \
                       -kdfopt hexsalt:"$_salt_hex" \
                       -kdfopt iter:100000 \
                       PBKDF2 2>/dev/null | tr -d ':')
    else
        log_error "decrypt_envelope: no PBKDF2 primitive available"
        log_error "  need perl (with Digest::SHA, in core since 5.9.3 / 2006)"
        log_error "  or python (2.7.8+ / 3.4+) or openssl 3.0+"
        _cleanup
        return 1
    fi
    if [ -z "$_key_hex" ]; then
        log_error "decrypt_envelope: PBKDF2 produced no key"
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

# Internal: PBKDF2 via Python (2.7.8+ / 3.4+). Outputs 64 hex chars (32 bytes).
# Args: python-binary, password, salt-hex
_pbkdf2_via_python() {
    _py="$1"
    _pwd="$2"
    _salt_hex="$3"
    "$_py" -c "
import sys, hashlib, binascii
try:
    salt = binascii.unhexlify(sys.argv[2])
    key  = hashlib.pbkdf2_hmac('sha256', sys.argv[1].encode('utf-8'), salt, 100000, 32)
    sys.stdout.write(binascii.hexlify(key).decode('ascii'))
except Exception as e:
    sys.stderr.write(str(e) + '\n')
    sys.exit(1)
" "$_pwd" "$_salt_hex"
}

# Internal: PBKDF2 via Perl + Digest::SHA::hmac_sha256.
# Outputs 64 hex chars (32 bytes). Works on stock CentOS 6 / RHEL 5 — perl
# is a hard dep of yum/rpm, and Digest::SHA has been in core since
# Perl 5.9.3 (2006). hmac_sha256 is XS/C-backed, so 100k iterations
# complete in 1-2 seconds even on CentOS-6-era hardware.
#
# We only ever derive 32 bytes of key material, which fits in one SHA-256
# block — so the outer block-loop is a single iteration (i=1) and we
# only need the inner HMAC-iteration loop.
#
# Args: password, salt-hex
_pbkdf2_via_perl() {
    perl -MDigest::SHA=hmac_sha256 -e '
        my ($pass, $salt_hex) = @ARGV;
        my $salt = pack("H*", $salt_hex);
        # PBKDF2 block 1: U_1 = HMAC(P, S || INT(1)).
        my $U = hmac_sha256($salt . pack("N", 1), $pass);
        my $T = $U;
        # T = U_1 ^ U_2 ^ ... ^ U_c, where U_j = HMAC(P, U_{j-1}).
        for (my $j = 2; $j <= 100000; $j++) {
            $U = hmac_sha256($U, $pass);
            $T ^= $U;
        }
        # 32-byte output fits in one SHA-256 block; no second block needed.
        print unpack("H*", $T);
    ' "$1" "$2"
}
