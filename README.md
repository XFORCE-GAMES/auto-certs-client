# auto-certs shell client

`auto_certs.sh` is the POSIX-`sh` client that game CPs install on their
hosts to keep their TLS certs current. It polls the auto-certs server,
downloads new bundles, atomically installs them, runs the CP's reload
hook, and reports the outcome back to the server.

The code is deliberately small, plain shell, and auditable in under 30
minutes by a sysadmin reading it cold. That posture is load-bearing:
the CP MIS team that owns the production hosts has to be able to
convince themselves there's no backdoor before running it as root.

## Verification posture

Every published release ships with four artifacts that establish
provenance:

| Artifact | What it proves |
|---|---|
| `<tarball>.tar.gz.release.sig` | **RSA-4096 detached signature** over the tarball. The verifying public key is **pinned in `install.sh` itself** — so an attacker who wants to ship a malicious tarball has to either forge an RSA-4096 signature (intractable without the AWS Secrets Manager private key) or substitute `install.sh` entirely. The CP audits `install.sh` once; from that point the trust transfers to every subsequent release. |
| `<tarball>.tar.gz.sigstore.json` | **cosign-keyless Sigstore bundle** for transparency-log auditing. Anyone (CP MIS, internal red team, third-party researcher) can verify via `cosign verify-blob --bundle ...sigstore.json --certificate-identity-regexp ...` that the tarball came from this GitHub repo's CI pipeline, not a side channel. |
| `<tarball>.tar.gz.sbom.spdx.json` | **SPDX SBOM** listing every file in the tarball. Auditable diff between releases. |
| `SHA256SUMS` | SHA-256 of every artifact. Plain text, easy to diff against the GitHub release page. |

`install.sh` verifies the RSA-4096 signature against its pinned pubkey
**before** extracting the tarball. A release without a valid
`.release.sig` is refused — there is no "skip the verify" flag.

## Quick start (for CP MIS reading this before installing)

Two-step install. The default flow keeps secrets at-rest in a 0600 file
(`/etc/auto-certs/conf.d/<app>.conf`) instead of typing them on the
install command line — argv values can land in `~/.bash_history`,
`ps aux`, and tee'd session-recordings. This is the same shape every
credential-aware CLI ships (kubectl, gh, doctl, …). The operator who
emails you the install instructions may include alternative one-step
variants tailored to your environment; this README documents the
audit-friendly default.

**Step 1 — install** (no secrets in argv):

```sh
curl -sSL https://github.com/XFORCE-GAMES/auto-certs-client/releases/latest/download/install.sh \
  | sudo sh -s -- --app <app_code>
```

**Step 2 — paste secrets into the placeholder config** (your `$EDITOR`
keeps them out of shell history):

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
2. Drops the payload (the actual fetch/verify/install logic) to
   `/opt/auto-certs/payload-<version>/` and points
   `/opt/auto-certs/current` at it.
3. Drops a placeholder per-app config to
   `/etc/auto-certs/conf.d/<app_code>.conf` (mode 0600) with
   `API_TOKEN=` and `BUNDLE_PASSWORD=` empty — **YOU EDIT THIS** with
   the values from the install-instructions email.
4. Generates a per-machine UUID at `/etc/auto-certs/machine_id` if
   absent (exclude this file from any golden-image seal so snapshot-
   provisioned children each generate their own).
5. Drops a placeholder reload hook to `/opt/auto-certs/reload.sh` —
   **YOU EDIT THIS** to do whatever your stack needs.
6. Adds a daily cron entry that runs `/opt/auto-certs/launcher.sh`.

If you forget to fill in `API_TOKEN=` or `BUNDLE_PASSWORD=`, the
launcher refuses to call the API and prints a CP-actionable error
pointing you back to the conf file. Run
`sudo /opt/auto-certs/launcher.sh --validate-config` to check every
config at once.

**Multi-app on one host**: re-run the installer with a different
`--app` value. Existing configs and reload hook are preserved; only
the binary tree is upgraded.

## CentOS 6 bootstrap

If you're installing on a CentOS 6 host and the standard `curl | sh`
one-liner from Step 1 fails with:

```
curl: (60) SSL certificate problem: unable to get local issuer certificate
```

…it's because CentOS 6's `ca-certificates` package predates the
Let's Encrypt root that signs `objects.githubusercontent.com` (where
GitHub serves release asset downloads). It's a chicken-and-egg between
trust-store age and TLS validation.

**Recommended bootstrap workaround** — use `--insecure` for the
initial fetch only:

```sh
curl --insecure -sSL \
  https://github.com/XFORCE-GAMES/auto-certs-client/releases/latest/download/install.sh \
  | sudo sh -s -- --app <app_code>
```

This is acceptable for **this one fetch** because:

1. **The downloaded `install.sh` carries the pinned RSA-4096 public
   key** and uses it to verify the release tarball's
   `.release.sig` **before extracting**. The `--insecure` curl bypass
   doesn't bypass that verify — even a perfect MITM that substitutes
   the tarball would have to forge an RSA-4096 signature.
2. **After install, the client carries its own bundled Mozilla CA
   bundle** at `/opt/auto-certs/current/lib/cacert.pem`. Every
   subsequent fetch uses that explicitly via `curl --cacert ...`.
   Your system `ca-certificates` package is no longer in the trust
   path for any auto-certs operation.

**Alternative — install on a modern host first, then `scp` the
artifacts**:

If `--insecure` is against your security policy, run the curl on any
modern host (RHEL 7+, Ubuntu 16+, macOS, etc.), then `scp` the
resulting `install.sh` to the CentOS 6 host and run it locally:

```sh
# On a modern host:
curl -sSL \
  https://github.com/XFORCE-GAMES/auto-certs-client/releases/latest/download/install.sh \
  -o install.sh
scp install.sh user@centos6-host:/tmp/

# On the CentOS 6 host:
sudo sh /tmp/install.sh --app <app_code>
```

The `install.sh` script itself runs fine on CentOS 6; only the
bootstrap-fetch needs a modern TLS stack.

**Why we don't recommend `yum update ca-certificates`**: yum on
CentOS 6 also uses the (same-vintage) system trust store to validate
`mirrorlist.centos.org`. The update path itself is broken on the same
chain. It works in some configurations (vault.centos.org via HTTP, or
replaced repo URLs), but those workarounds are outside our scope. The
`--insecure`-once-then-bundle approach above is more reliable and
operationally narrower.

## Troubleshooting

The launcher supports several diagnostic modes that don't touch
production state:

| Command | What it does |
|---|---|
| `sudo /opt/auto-certs/launcher.sh --validate-config` | Parses every config file under `/etc/auto-certs/conf.d/`, reports which ones are missing `API_TOKEN` or `BUNDLE_PASSWORD`. Safe to run any time. |
| `sudo /opt/auto-certs/launcher.sh --once --app <app_code>` | One-shot run for a single app: poll the server, install if new, run hook, report. Bypasses the daily cron timing. |
| `sudo /opt/auto-certs/launcher.sh --once --app <app_code> --diagnose` | Same as `--once` but writes a verbose per-step trace to stdout. Useful for first-install verification. |
| `sudo /opt/auto-certs/launcher.sh --self-check` | Validates config parsing, required tools, cert-dir writability, reload-hook presence, on-disk bundle integrity. **Does not execute the reload hook** — safe to run on production. |

If a problem persists, the log under `/var/log/auto-certs/<app>.log`
has structured per-step events. Failed reports also queue under
`/var/lib/auto-certs/queue/<app>/` and re-try on the next cron tick;
that directory should normally be empty.

## Repo layout

```
.
├── install.sh                ← one-line installer + pinned release-signing pubkey
├── launcher.sh               ← ≤60-line POSIX sh; locates payload, integrity-checks, execs
├── updater.sh                ← sidecar that polls the server for newer payloads
├── payload/
│   ├── VERSION               ← single-line semver (matched by git tag with `v` prefix)
│   ├── auto_certs.sh         ← main entry point — polling, install, hook, report
│   └── lib/
│       ├── common.sh         ← logging, redaction, timeout wrapper
│       ├── http.sh           ← curl+wget abstraction
│       ├── crypto.sh         ← openssl wrappers (sig verify, decrypt, x509)
│       ├── atomic.sh         ← atomic mv helpers
│       ├── report.sh         ← report-back assembly + redaction
│       ├── server-pubkey.pem ← legacy in-payload trust anchor (pre-v0.4.0-rc15 fallback)
│       └── cacert.pem        ← Mozilla NSS CA bundle (refreshed via updater.sh)
├── reload.sh.placeholder     ← explanatory comments + `exit 1` body
├── conf.d/
│   └── example.conf.template ← annotated config template
├── CHANGELOG.md              ← curated release notes per tag
├── README.md                 ← this file
├── LICENSE
└── SECURITY.md               ← vulnerability disclosure
```

## Operating constraints

- **POSIX `sh` only** in production code — no bashisms (`[[ ]]`,
  `${var,,}`, `<<<`, arrays, `function`, `local`).
- **Standard small toolset**: `openssl`, `curl` *or* `wget`, `tar`,
  `mv`, `mktemp`, `sha256sum` (with `shasum -a 256` fallback), `awk`,
  `grep`, `sed`, `cut`, `tr`. No `jq`, no `systemctl`, no GNU-specific
  flags.
- **CentOS 6 `openssl` is 1.0.1e** — no `enc -pbkdf2` flag, no `kdf`
  subcommand. The envelope format uses single-pass HMAC-SHA256 KDF via
  `openssl dgst -sha256 -hmac` (available since openssl 1.0.0,
  March 2010); the client computes the same key from `(password, salt)`
  the server used and runs `openssl enc -aes-256-cbc -d -K <hex> -iv
  <hex>`. End-to-end empirically verified on real CentOS 6.8 / 7.9 /
  Ubuntu 16.04 floor hosts.
- **Standard `unzip` does NOT decrypt AES ZIPs** — we don't ship ZIP.
  The bundle is `tar` + `openssl enc -aes-256-cbc`.
- **Detached signature verification is a HARD pre-condition on
  decrypt**. The pinned RSA-4096 public key — written to
  `${INSTALL_ROOT}/server-pubkey.pem` (`/opt/auto-certs/server-pubkey.pem`)
  by `install.sh` at install time from its own embedded heredoc —
  verifies the server's signature on every encrypted envelope
  BEFORE we attempt decrypt. The same key file (byte-identical to
  the `install.sh` heredoc) is the durable trust root for `updater.sh`
  too; it lives OUTSIDE the auto-updating payload area so a future
  malicious payload can't rotate its own pubkey to forge a release
  signature. (Pre-v0.4.0-rc15 installs read from
  `payload/lib/server-pubkey.pem` which is still shipped as a
  backwards-compat fallback.)
- **No auto-rollback on reload-hook failure**. New bundle stays on
  disk; old in-memory cert keeps serving until something reloads.
  Failure is reported back; the operator alerts the CP through the
  per-app chat group.
- **Source must be auditable in <30 minutes by a non-expert sysadmin**.
  No clever tricks. No minification. Plain shell.

## Where to learn more

- **[CHANGELOG.md](CHANGELOG.md)** — what changed in every release.
- **[SECURITY.md](SECURITY.md)** — how to report a vulnerability.
- **[Releases page](https://github.com/XFORCE-GAMES/auto-certs-client/releases)**
  — every signed tarball, with SBOM + cosign bundle + RSA `.release.sig`
  + SHA256SUMS attached.
- **Operator runbooks for your provider** — your auto-certs service
  operator maintains internal runbooks (token rotation, bundle password
  rotation, JKS password change, reload-hook reference patterns) and
  shares them with CP MIS on request. Ask via the per-app chat group.
