# auto-certs shell client

This is `auto_certs.sh`, the POSIX-`sh` client that game CPs install on their hosts to keep their TLS certs current. It polls the auto-certs server (run by xforce-games), downloads new bundles, atomically installs them, runs the CP's reload hook, and reports the outcome back to the server.

This repository is the **public mirror** of the client tree. The CP's MIS team should be able to read this entire repo in under 30 minutes and convince themselves there is no backdoor or smuggled diagnostic.

See [SECURITY.md](SECURITY.md) for cryptographic verification of releases (Sigstore/cosign-keyless + SLSA build provenance + SPDX SBOM).

## Quick start (for CP MIS reading this before installing)

Two-step install. **Secrets are NEVER passed on the command line** — they would leak into `~/.bash_history`, `ps aux`, and any session-recording. Same shape every credential-aware CLI ships (kubectl, gh, doctl, …).

**Step 1 — install** (no secrets in argv):

```sh
curl -sSL https://github.com/XFORCE-GAMES/auto-certs-client/releases/latest/download/install.sh \
  | sudo sh -s -- --app <app_code>
```

**Step 2 — paste secrets into the placeholder config** (your `$EDITOR` keeps them out of shell history):

```sh
sudo $EDITOR /etc/auto-certs/conf.d/<app_code>.conf
# Fill in the empty API_TOKEN= and BUNDLE_PASSWORD= lines with the
# values delivered to you in the per-app chat group.
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
3. Drops a placeholder per-app config to `/etc/auto-certs/conf.d/<app_code>.conf` (mode 0600) with `API_TOKEN=` and `BUNDLE_PASSWORD=` empty — **YOU EDIT THIS** with the values from the per-app chat group.
4. Generates a per-machine UUID at `/etc/auto-certs/machine_id` if absent (excluded from snapshot seal).
5. Drops a placeholder reload hook to `/opt/auto-certs/reload.sh` — **YOU EDIT THIS** to do whatever your stack needs.
6. Adds a daily cron entry that runs `/opt/auto-certs/launcher.sh`.

If you forget to fill in `API_TOKEN=` or `BUNDLE_PASSWORD=`, the launcher refuses to call the API and prints a CP-actionable error pointing you back to the conf file. Run `sudo /opt/auto-certs/launcher.sh --validate-config` to check every config at once.

**Multi-app on one host**: re-run the installer with a different `--app` value. Existing configs and reload hook are preserved; only the binary tree is upgraded.

## Repo layout

```
README.md           ← this file
install.sh          ← installer (Step 1) — only --app on the command line
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
    server-pubkey.pem ← pinned at install (never auto-rotates)
reload.sh.placeholder ← explanatory comments + `exit 1` body
conf.d/
  example.conf.template ← annotated config template; install.sh substitutes
                          __APP_CODE__ / __BASE_DOMAIN__ / __SERVER_URL__ to
                          produce the per-app placeholder conf
LICENSE             ← Apache-2.0
SECURITY.md         ← signing + verification recipes for release artifacts
```

## Operating constraints

These shape every line of code in this repo:

- **POSIX `sh` only** — no bashisms (`[[ ]]`, `${var,,}`, `<<<`, arrays, `function`, `local`). Tested on CentOS 6/7, Ubuntu, and other Linuxes that ship a non-bash `/bin/sh`.
- **Standard small toolset**: `openssl`, `curl` *or* `wget`, `tar`, `mv`, `mktemp`, `sha256sum` (with `shasum -a 256` fallback), `awk`, `grep`, `sed`, `cut`, `tr`. No `jq`, no `systemctl`, no GNU-specific flags.
- **CentOS 6 `openssl` is 1.0.1e** — no `enc -pbkdf2` flag. The server pre-derives the AES key via PBKDF2 and ships salt + IV + ciphertext; the client just runs `openssl enc -aes-256-cbc -d -K <hex> -iv <hex>`.
- **Standard `unzip` does NOT decrypt AES ZIPs** — we don't ship ZIP. The bundle is `tar` + `openssl enc`.
- **Detached signature verification is HARD pre-condition on decrypt**. The pinned RSA-4096 public key in `payload/lib/server-pubkey.pem` verifies the server's signature on the encrypted envelope BEFORE we attempt decrypt.
- **No auto-rollback on reload-hook failure**. New bundle stays on disk; old in-memory cert keeps serving until something reloads. Failure is reported back; xforce-games operators handle manually.
- **Source must be auditable in <30 minutes by a non-expert sysadmin**. No clever tricks. No minification. Plain shell.
- **Whatever code runs is plainly visible in this repo.** Nothing is fetched at runtime that isn't part of a signed release.
