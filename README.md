# auto-certs shell client

This directory holds `auto_certs.sh`, the POSIX-`sh` client that game CPs install on their hosts to keep their TLS certs current. It polls the auto-certs server, downloads new bundles, atomically installs them, runs the CP's reload hook, and reports the outcome back to the server.

> **Status (2026-04-30)**: in-tree development per CLAUDE.md. Public GitHub migration is the [release gate to first CP onboarding](../CLAUDE.md). Develop here, prove it works, sign artifacts, then move.

## Quick start (for CP MIS reading this before installing)

Two-step install. The default flow keeps secrets at-rest in a 0600 file (`/etc/auto-certs/conf.d/<app>.conf`) instead of typing them on the install command line — argv values can land in `~/.bash_history`, `ps aux`, and tee'd session-recordings. This is the same shape every credential-aware CLI ships (kubectl, gh, doctl, …). The operator who emails you the install instructions may include alternative one-step variants tailored to your environment; this README documents the audit-friendly default.

**Step 1 — install** (no secrets in argv):

```sh
curl -sSL https://github.com/XFORCE-GAMES/auto-certs-client/releases/latest/download/install.sh \
  | sudo sh -s -- --app <app_code>
```

**Step 2 — paste secrets into the placeholder config** (your `$EDITOR` keeps them out of shell history):

```sh
sudo $EDITOR /etc/auto-certs/conf.d/<app_code>.conf
# Fill in the empty API_TOKEN= and BUNDLE_PASSWORD= lines with the
# values delivered to you in the install-instructions email.
```

**Step 3 — edit the reload hook**:

```sh
sudo $EDITOR /opt/auto-certs/reload.sh
# Replace the `exit 1` default with your reload command, e.g.
#   service nginx reload
# or whatever your stack needs.
```

**Step 4 — verify**:

```sh
sudo /opt/auto-certs/launcher.sh --once --app <app_code>
```

The installer:

1. Drops the launcher to `/opt/auto-certs/launcher.sh`.
2. Drops the payload (the actual fetch/verify/install logic) to `/opt/auto-certs/payload-<version>/` and points `/opt/auto-certs/current` at it.
3. Drops a placeholder per-app config to `/etc/auto-certs/conf.d/<app_code>.conf` (mode 0600) with `API_TOKEN=` and `BUNDLE_PASSWORD=` empty — **YOU EDIT THIS** with the values from the install-instructions email.
4. Generates a per-machine UUID at `/etc/auto-certs/machine_id` if absent (excluded from snapshot seal).
5. Drops a placeholder reload hook to `/opt/auto-certs/reload.sh` — **YOU EDIT THIS** to do whatever your stack needs.
6. Adds a daily cron entry that runs `/opt/auto-certs/launcher.sh`.

If you forget to fill in `API_TOKEN=` or `BUNDLE_PASSWORD=`, the launcher refuses to call the API and prints a CP-actionable error pointing you back to the conf file. Run `sudo /opt/auto-certs/launcher.sh --validate-config` to check every config at once.

**Multi-app on one host**: re-run the installer with a different `--app` value. Existing configs and reload hook are preserved; only the binary tree is upgraded.

## CentOS 6 bootstrap

If you're installing on a CentOS 6 host and the standard `curl | sh` one-liner from Step 1 fails with:

```
curl: (60) SSL certificate problem: unable to get local issuer certificate
```

…it's because CentOS 6's `ca-certificates` package predates the Let's Encrypt root that signs `objects.githubusercontent.com` (where GitHub serves release asset downloads). It's a chicken-and-egg between trust-store age and TLS validation.

**One-time bootstrap workaround** — use `--insecure` for the initial fetch only:

```sh
curl --insecure -sSL \
  https://github.com/XFORCE-GAMES/auto-certs-client/releases/latest/download/install.sh \
  | sudo sh -s -- --app <app_code>
```

This is acceptable for **this one fetch** because:

1. **The downloaded `install.sh` is verified separately.** Each release publishes `SHA256SUMS` + a cosign-keyless detached signature; the install script's content is reproducible from the public artifacts. Optional belt-and-braces: download `install.sh` + `SHA256SUMS` + `SHA256SUMS.sig` + `SHA256SUMS.crt` separately, run `cosign verify-blob` (see the release page for the exact command), then re-execute locally without `--insecure`.
2. **After install, the client carries its own bundled Mozilla CA bundle** at `/opt/auto-certs/current/lib/cacert.pem`. Every subsequent fetch uses that explicitly via `curl --cacert ...`. Your system `ca-certificates` package is no longer in the trust path for any auto-certs operation.

**Alternative — install on a modern host first, then `scp` the artifacts**:

If `--insecure` is against your security policy, run the curl on any modern host (RHEL 7+, Ubuntu 16+, macOS, etc.), then `scp` the resulting `install.sh` to the CentOS 6 host and run it locally:

```sh
# On a modern host:
curl -sSL \
  https://github.com/XFORCE-GAMES/auto-certs-client/releases/latest/download/install.sh \
  -o install.sh
scp install.sh user@centos6-host:/tmp/

# On the CentOS 6 host:
sudo sh /tmp/install.sh --app <app_code>
```

The `install.sh` script itself runs fine on CentOS 6; only the bootstrap-fetch needs a modern TLS stack.

**Why we don't recommend `yum update ca-certificates`**: yum on CentOS 6 also uses the (same-vintage) system trust store to validate `mirrorlist.centos.org`. The update path itself is broken on the same chain. It works in some configurations (vault.centos.org via HTTP, or replaced repo URLs), but those workarounds are outside our scope. The `--insecure`-once-then-bundle approach above is more reliable and operationally narrower.

## Repo layout

```
client/
  README.md           ← this file
  install.sh          ← one-line installer (Step 1)
  launcher.sh         ← ≤50-line POSIX sh; locates payload, integrity-checks, execs (Step 2)
  payload/
    VERSION           ← single-line semver
    auto_certs.sh     ← main entry point (Step 3+)
    lib/
      common.sh       ← logging, redaction, timeout wrapper
      http.sh         ← curl+wget abstraction
      crypto.sh       ← openssl wrappers (sig verify, decrypt, x509)
      atomic.sh       ← atomic mv-T helpers
      report.sh       ← report-back assembly + redaction
      report_send.sh  ← POST /api/v1/report with retry/queue
      server-pubkey.pem ← pinned at install (never auto-rotates)
  reload.sh.placeholder ← explanatory comments + `exit 1` body
  conf.d/
    example.conf.template ← annotated config template; install.sh substitutes
                            __APP_CODE__ / __BASE_DOMAIN__ / __SERVER_URL__ to
                            produce the per-app placeholder conf
  test/
    run_all.sh        ← top-level test runner
    mock_server.sh    ← Python/nc-based mock for /api/v1/*
    live_e2e.sh       ← manual e2e against dev API
    fixtures/         ← sample bundles + payloads
```

## Operating constraints (CLAUDE.md gives the full picture)

- **POSIX `sh` only** in production code — no bashisms (`[[ ]]`, `${var,,}`, `<<<`, arrays, `function`, `local`).
- **Standard small toolset**: `openssl`, `curl` *or* `wget`, `tar`, `mv`, `mktemp`, `sha256sum` (with `shasum -a 256` fallback), `awk`, `grep`, `sed`, `cut`, `tr`. No `jq`, no `systemctl`, no GNU-specific flags.
- **CentOS 6 `openssl` is 1.0.1e** — no `enc -pbkdf2` flag, no `kdf` subcommand. Envelope v2 (`v0.3.0-rc1`, 2026-05-02) uses single-pass HMAC-SHA256 KDF via `openssl dgst -sha256 -hmac` (in 1.0.0+ since March 2010); the client computes the same key from `(password, salt)` the server used and runs `openssl enc -aes-256-cbc -d -K <hex> -iv <hex>`. End-to-end empirically verified on `canary-centos6` (CentOS 6.8 / OpenSSL 1.0.1e-fips). Full rationale: [`docs/research/centos6-compatibility.md`](../docs/research/centos6-compatibility.md).
- **Standard `unzip` does NOT decrypt AES ZIPs** — we don't ship ZIP. The bundle is `tar` + `openssl enc`.
- **Detached signature verification is HARD pre-condition on decrypt**. The pinned RSA-4096 public key in `payload/lib/server-pubkey.pem` verifies the server's signature on the encrypted envelope BEFORE we attempt decrypt.
- **No auto-rollback on reload-hook failure**. New bundle stays on disk; old in-memory cert keeps serving until something reloads. Failure is reported back; MIS handles manually.
- **Source must be auditable in <30 minutes by a non-expert sysadmin**. No clever tricks. No minification. Plain shell.

See [docs/plans/phase-4-shell-client.md](../docs/plans/phase-4-shell-client.md) for the full implementation plan.
