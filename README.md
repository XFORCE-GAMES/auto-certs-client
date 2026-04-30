# auto-certs-client

`auto_certs.sh` is the **TLS-certificate maintenance client** for game-CP host fleets that subscribe to the [auto-certs](https://github.com/XFORCE-GAMES) cert-distribution service. It runs as a daily cron, polls the server, downloads new cert bundles when available, atomically installs them, runs the reload hook the CP configured, and reports the outcome back. POSIX `sh` only; works on CentOS 6+ / RHEL 5+ / Ubuntu / any modern Linux without extra runtime install.

This repository is the **public, MIS-auditable release** of the client. The server side (cert issuance, distribution API, admin UI) is internal.

> **Status**: pre-release. Phase 4 of the development plan is code-complete; Phase 6 (staged self-update) is not yet shipped, so v0.x releases install but do not auto-upgrade. Production roll-out to a real CP requires separate operator coordination.

## Quick start

```sh
curl -sSL https://github.com/XFORCE-GAMES/auto-certs-client/releases/latest/download/install.sh \
  | sh -s -- \
      --app             <app_code> \
      --token           acert_live_<…> \
      --bundle-password <password> \
      --base-domain     <subdomain>.example.com \
      --cert-dir        /etc/auto-certs/<subdomain>.example.com
```

The four credentials (`--app`, `--token`, `--bundle-password`, `--base-domain`) are issued by the server-side operator during onboarding. The installer:

1. Drops the launcher to `/opt/auto-certs/launcher.sh`.
2. Drops the payload (the actual fetch/verify/install logic) to `/opt/auto-certs/payload-<version>/` and points `/opt/auto-certs/current` at it.
3. Drops a per-app config to `/etc/auto-certs/conf.d/<app_code>.conf`.
4. Generates a per-machine UUID at `/etc/auto-certs/machine_id` if absent. **Important**: exclude this file from any image-prep / snapshot-seal script, or every snapshot child will share the same UUID.
5. Drops a placeholder `/opt/auto-certs/reload.sh` with `exit 1` body — **YOU EDIT THIS** to do whatever your stack needs (`service nginx reload`, `systemctl reload nginx`, `kill -HUP $(cat /var/run/foo.pid)`, copy files into multiple service paths, etc.). The placeholder exits non-zero so the first run fails loudly until you've configured it.
6. Adds a daily cron entry that runs `/opt/auto-certs/launcher.sh`.

## How to verify the release signature

Every tagged release is signed with [cosign](https://docs.sigstore.dev/cosign/overview/) keyless via GitHub OIDC. To verify before installing:

```sh
VERSION=v0.1.0-rc1
BASE=https://github.com/XFORCE-GAMES/auto-certs-client/releases/download/${VERSION}

# Download the artifacts.
curl -fsSLO ${BASE}/auto-certs-client-${VERSION}.tar.gz
curl -fsSLO ${BASE}/auto-certs-client-${VERSION}.tar.gz.sig
curl -fsSLO ${BASE}/auto-certs-client-${VERSION}.tar.gz.crt

# Verify the signature chain.
cosign verify-blob \
  --certificate auto-certs-client-${VERSION}.tar.gz.crt \
  --signature   auto-certs-client-${VERSION}.tar.gz.sig \
  --certificate-identity-regexp "https://github.com/XFORCE-GAMES/auto-certs-client/.*" \
  --certificate-oidc-issuer     "https://token.actions.githubusercontent.com" \
  auto-certs-client-${VERSION}.tar.gz
```

A successful verification proves the tarball was built by the official release workflow on this repository (recorded in the public Sigstore Rekor transparency log).

Each release also includes:

- `auto-certs-client-${VERSION}.spdx.json` — SBOM in SPDX 2.3 JSON format.
- `SHA256SUMS` — checksums for every artifact.
- A SLSA v1 build-provenance attestation (visible on the GitHub Release page).

## What gets sent home

The client reports the outcome of every cert-update attempt to the server. The full payload schema is visible in [`payload/lib/report.sh`](payload/lib/report.sh) — there is no opaque blob. In summary:

- **`applied`** — `true` if the cert was installed and reload hook returned 0; `false` otherwise.
- **`error`** + **`failure_category`** — when `applied=false`.
- **`hook_output`** — captured stdout/stderr from your reload hook (truncated, redacted of any token-shaped strings).
- **`tls_self_test_result`** — fingerprint of what each `(host, port)` you configured is now serving, after the reload.
- **`phase_events`** — timestamps of `download_started`, `extract_ok`, `syntax_check_ok`, `reload_hook_exit_N`, etc.
- **`environment`** — OS / openssl / curl / tar / bash versions; init system; arch.
- **`config_snapshot`** — `app_code`, `cp_code`, `base_domain`, `cert_dir`, `hook_path` — the on-disk config at the time of the attempt.
- **`recent_log_tail`** — last ~50 lines of `/var/log/auto-certs/<app_code>.log`, redacted.
- **`previous_run_summary`** — was the last attempt on this machine successful, and when.
- **`client_version`** / **`launcher_version`** / **`payload_sha`** — versioning of the running script.

**Tokens and bundle passwords are redacted client-side BEFORE the payload is constructed.** The redaction logic is in [`payload/lib/common.sh`](payload/lib/common.sh) — auditable.

The endpoint the client POSTs to is configurable via `SERVER_URL` in `/etc/auto-certs/conf.d/<app_code>.conf`. Default: the operator-issued URL, set by `install.sh --server-url`.

## Operating modes

```sh
/opt/auto-certs/launcher.sh                # default — process every configured app once
/opt/auto-certs/launcher.sh --once         # explicit synonym
/opt/auto-certs/launcher.sh --app <code>   # process only the named app
/opt/auto-certs/launcher.sh --diagnose     # emit a redacted env report (OS / openssl / paths / time-skew / API connectivity)
/opt/auto-certs/launcher.sh --self-check   # validate config + tools + on-disk state without contacting the server
```

`--diagnose` is the right flag if you're troubleshooting and want to share output with the operator. It is auditable: see [`payload/auto_certs.sh`](payload/auto_certs.sh) for the exact set of fields.

## Repository layout

```
README.md                  ← this file
LICENSE                    ← Apache-2.0
SECURITY.md                ← how to report a vulnerability
install.sh                 ← one-line installer
launcher.sh                ← <60-line POSIX sh; locates payload, integrity-checks, execs
payload/
  VERSION                  ← single-line semver
  auto_certs.sh            ← main entry point
  lib/
    common.sh              ← logging, redaction, timeout wrapper
    http.sh                ← curl+wget abstraction
    crypto.sh              ← openssl wrappers (signature verify, decrypt, x509 introspect)
    atomic.sh              ← atomic mv-T helpers
    report.sh              ← report-back assembly + redaction
reload.sh.placeholder      ← explanatory comments + `exit 1` body
conf.d/
  example.conf             ← annotated config example
.github/
  workflows/               ← CI + release pipeline (cosign + SBOM + SLSA)
  SECURITY.md              ← (forwarded to /SECURITY.md)
  dependabot.yml           ← keeps Action SHAs current via PR
```

## Operating constraints

- **POSIX `sh` only** in production code. No `bash`-only constructs (`[[ ]]`, `${var,,}`, `<<<`, arrays, `function`, `local`, `BASH_REMATCH`, …).
- **Standard small toolset**: `openssl`, `curl` *or* `wget`, `tar`, `mv`, `mktemp`, `sha256sum` (with `shasum -a 256` fallback), `awk`, `grep`, `sed`, `cut`, `tr`. **No `jq`, no `systemctl`, no GNU-specific flags, no `bash`-builtins.** If your distro has `perl` (every CentOS / RHEL does, since it's a hard dep of `yum`/`rpm`), the client uses it for PBKDF2 fallback on hosts whose `openssl` predates `enc -pbkdf2` (CentOS 6, RHEL 5).
- **CentOS 6 supported.** OpenSSL 1.0.1e (CentOS 6) lacks `enc -pbkdf2` and `-iter`. The server pre-derives the AES key via PBKDF2; the client receives `salt + iv + ciphertext` and runs `openssl enc -aes-256-cbc -d -K <hex> -iv <hex>` — works on every openssl from 1.0.1e onward.
- **Detached signature verification is a HARD pre-condition on decrypt.** The pinned RSA-4096 server public key (in `payload/lib/server-pubkey.pem`, distributed at install time) verifies the server's signature on the encrypted envelope BEFORE we attempt decrypt. An attacker who can swap ciphertext bits cannot escape signature verification.
- **No auto-rollback on reload-hook failure.** The new bundle stays on disk; the running service keeps using its in-memory old cert (still valid) until something explicitly reloads it. The failure is reported back to the server, which alerts the operator's MIS team. This avoids papering over real CP-side issues (broken nginx config, wrong cert path, JKS password mismatch).
- **Source must be auditable in <30 minutes by a non-expert sysadmin.** No clever tricks, no minification, no obfuscation. Plain shell. Every committed revision must hold this bar.

## Reporting a vulnerability

Please use GitHub's private security advisory system (`Security` tab → `Report a vulnerability`). Do not open a public issue or PR for security problems. See [SECURITY.md](SECURITY.md) for details.

## Contributing

The client is small and the surface area is intentionally narrow. PRs that simplify, harden, or improve readability are welcome. PRs that add features should be discussed in an issue first — every config flag we add is a footprint we ship to every CP forever.

PRs run shellcheck via the `ci.yml` workflow; failing shellcheck blocks merge.

## License

Apache License 2.0 — see [LICENSE](LICENSE).
