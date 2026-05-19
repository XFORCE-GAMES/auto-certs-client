# Changelog

All notable changes to the `auto-certs-client` (the POSIX-`sh` client
shipped to CP hosts) are documented in this file.

The format is loosely [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
versioned per [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Pre-1.0 releases used `-rcN` suffixes for staged rollouts; post-1.0
pre-releases use SemVer pre-release identifiers only for actual
release candidates (see [`docs/versioning.md`](docs/versioning.md)
for the full policy).

## [v0.4.0-rc15] — 2026-05-19

### Security

- **Trust root moved OUT of the auto-updating area.** Pre-rc15,
  `updater.sh` read the RSA-4096 release-signing pubkey from
  `payload/lib/server-pubkey.pem` — inside the very payload it was
  about to swap. If a malicious payload ever got through staged-
  rollout self-check, it could rotate its own pubkey, and the next
  `updater.sh` tick would happily verify the next attacker tarball
  against the attacker key. Post-rc15, `install.sh` writes the
  pinned pubkey from its own embedded heredoc to
  `${INSTALL_ROOT}/server-pubkey.pem` (`/opt/auto-certs/server-pubkey.pem`)
  at install time, and `updater.sh` reads from there first — outside
  the auto-updating area, never touched by the rolling payload.
  Backwards-compat fallback to the in-payload copy preserves
  existing pre-rc15 installs unchanged. Closes the
  install-once-can't-fix-later trust-rotation hole.
- **Emergency disable flag for `updater.sh`**: `touch /etc/auto-certs/disabled`
  stops all update activity without editing the cron entry. Silent
  exit so a disabled host doesn't fill `/var/log`. Path overridable
  via `AUTO_CERTS_DISABLED` env var. Operator-touchable kill switch
  for when something misbehaves in the field.
- **`assigned_ref` shape validation**: `updater.sh` now rejects any
  server-supplied `assigned_ref` that doesn't match
  `vMAJOR.MINOR.PATCH[-(rc|beta|alpha)N]` before interpolating it
  into filesystem paths. Defense against a compromised server (or
  buggy JSON parse) shipping path-traversal characters that would
  escape `${INSTALL_ROOT}/staging/${ASSIGNED}` or
  `${INSTALL_ROOT}/payload-${ASSIGNED}`. The RSA signature protects
  tarball bytes; this `case` statement protects the filename the
  client constructs from server input.
- **Concurrent-updater mutex**: `mkdir`-based test-and-set at
  `/var/lock/auto-certs-updater.lock.d` (POSIX-portable; works on
  CentOS 6 which lacks `flock(1)`). Stale-lock recovery via
  `find -mmin +60` covers SIGKILL'd prior runs. Prevents two
  `updater.sh` processes from racing the symlink swap if a CP
  added a second cron entry or a saturated host's tick runs long.
- **`redact()` honest named-secret patterns**: `payload/lib/common.sh`
  `redact()` function now redacts `BUNDLE_PASSWORD=value`,
  `API_TOKEN: value`, `JKS_PASSWORD = value` shapes — covering the
  realistic leak path (env dumped to log by a crashed CP reload
  hook). Pre-rc15 the function's comment promised a "43-char base62
  chunks" pattern that was never implemented; the safer
  named-secret approach catches the actual leak shapes without
  false-positive risk on cert serials, UUIDs-stripped-of-dashes,
  or unrelated base64 fragments.

Together these close NEW-4 / NEW-6 / NEW-7 / NEW-13 / NEW-43 —
five of the v1.0.0-gate hardening items filed against pre-rc15
client. Combined with rc14's NEW-40/41/42 (`install.sh` hardening),
the install-once surface — `install.sh` + `launcher.sh` +
`updater.sh` — is fully hardened before v1.0.0 freezes it.

### Operational

- **First release auto-published as Latest without manual
  intervention.** Pre-rc15, every `v0.4.0-rcN` tag was incorrectly
  marked `prerelease: true` by the release workflow, which broke the
  `curl .../releases/latest/download/install.sh` install one-liner.
  Operator workaround was `gh release edit --prerelease=false
  --latest=true` after every cut (≈20 manual promotes over a month).
  Rc15 ships the permanent fix in `.github/workflows/release.yml`:
  any `v0.*` tag now publishes as `prerelease=false + make_latest=true`
  by default; post-1.0.0 the workflow reverts to SemVer-strict
  semantics. v0.4.0-rc15 itself was the first cut to validate this
  end-to-end.

### Where to look

- `${INSTALL_ROOT}/server-pubkey.pem` — the new trust-root location
  (rc15+). Auditable by `cat`; matches the heredoc near the top of
  `install.sh` byte-for-byte.
- `/etc/auto-certs/disabled` — touch this file to halt updates
  without editing cron (rc15+).
- `payload/lib/server-pubkey.pem` — legacy fallback for pre-rc15
  installs; still present in the tarball for backwards-compat.

## [v0.4.0-rc14] — 2026-05-19

### Security

- **`install.sh` now verifies the release tarball's RSA-4096 detached
  signature BEFORE extracting** (closes the v1.0.0 install-flow
  hardening gate). The verifying public key is pinned in `install.sh`
  itself as a 814-byte heredoc. A release without a valid
  `.release.sig` is refused — there is no "skip the verify" flag.
- **Pre-extract path-traversal guard**: `install.sh` runs `tar -tzf`
  before `tar -xzf` and refuses any tarball whose entries start with
  `/` or contain `..` path components.
- **Hardened tar extract flags**: `tar --no-overwrite-dir
  --no-same-owner`. The first refuses to silently follow existing
  directories (defends against a tarball that pre-creates a symlink
  and writes through it). The second prevents `tar` from chown'ing
  extracted files to UID/GID baked into the tarball headers (defends
  against root-shell escalation if the installer runs as root).
- **Post-extract symlink sanity check**: refuses to install if
  `$SOURCE_DIR/payload`, `$SOURCE_DIR/launcher.sh`, or the extracted
  root itself turn out to be symlinks.

Together these close NEW-40 / NEW-41 / NEW-42, the three HIGH-severity
install-flow trust-boundary items filed against pre-rc14 install.sh.

### Operational

No payload or behavior changes — rc14 is install-path-only hardening.
The PATH augmentation that lets reload hooks find `/usr/sbin` commands
under cron shipped in rc13 below.

## [v0.4.0-rc13] — 2026-05-18

### Fixed

- **Reload hooks calling `/usr/sbin` commands now work under cron.**
  Cron's default PATH on Debian/Ubuntu is `/usr/bin:/bin` only;
  reload hooks that called `service`, `systemctl`, or `iptables`
  worked when tested via interactive SSH but silently failed at the
  daily cron tick with `command not found`. Fix: `auto_certs.sh`
  prepends `/usr/sbin` + appends `/sbin` to its own PATH (idempotent)
  and exports the result, so the augmented PATH propagates to the
  reload hook as a grandchild process.

## [v0.4.0-rc12] — 2026-05-18

### Fixed

- **Host-state-only self-check failures no longer trigger updater
  revert.** On hosts running an older installer-era `updater.sh`,
  the previous self-check semantics caused the launcher to revert
  any time the on-disk reload hook was still the placeholder, the
  cert directory was missing, or the hook file wasn't executable —
  even when the new payload itself was healthy. The reverted host
  would then download the same new payload on the next tick and
  revert again, thrashing nightly. Rc12 returns `rc=0` (the universal
  "stay" signal honored by every updater.sh since rc1) for these
  three CP-action-gap categories. The fail is still reported back to
  the server so operators can see and act on it — only the launcher
  revert decision changed.

## [v0.4.0-rc11] — 2026-05-17

### Fixed

- **Launcher self-check correctness under `set -eu`** — three
  related fixes that together restore the documented "controlled
  self-check fail → stay on new version" behavior that had been
  silently broken since rc4:
  - The main-loop per-app subshell is now wrapped in `if`/`else` so
    the outer `set -eu` doesn't kill the script before the per-app
    return code is captured.
  - The server-authoritative `BASE_DOMAIN` returned by `/api/v1/check`
    is now cached at `/var/lib/auto-certs/state/<app>/server_base_domain`
    so the next launcher flip's self-check can read it.
  - The `cert_dir_missing` check is now gated on `BASE_DOMAIN` being
    known, so minimal configs that delegate to the server-side
    authoritative value don't get false-positive failures.

## [v0.4.0-rc10] — 2026-05-15

### Fixed

- **Reload-hook env-var propagation on JKS-enabled apps.** Two
  related shell bugs at the hook-call sites:
  - A variable-expansion-in-env-var-prefix-position pattern that the
    shell tried to interpret as a literal command name on JKS-on
    apps, causing exit 127.
  - `VAR=val func` inline env-var prefix syntax doesn't reliably
    propagate vars to grandchild processes in POSIX `dash`. Replaced
    at both call sites with explicit `export VAR=val ; func ; unset
    VAR` so the env reliably reaches the hook.

## [v0.4.0-rc9] — 2026-05-15

### Changed

- **Mozilla CA bundle refresh now uses conditional GET** (`curl
  --time-cond`). Empirically ~99.9% bandwidth reduction on the
  daily refresh tick (most days the upstream bundle hasn't changed).
- Added empty-file guard + stale `.new` cleanup so a half-written
  refresh can't corrupt the on-disk bundle.

## [v0.4.0-rc8] — 2026-05-15

### Added

- **Install-intent header + server-side auto-heal.** New installs
  send an `X-Auto-Certs-Install-Intent` header on the first
  `/api/v1/check` so the server can detect a manually-installed
  version that's newer than any active rollout and auto-heal the
  per-machine assignment instead of trying to revert it.

## [v0.4.0-rc1 through rc7] — 2026-05-08 .. 2026-05-15

A series of incremental hardening + ergonomic releases between the
multi-step JKS delivery cutover (rc1) and the §108 install-intent
landing (rc8). Highlights:

- **rc1** — Multi-step JKS delivery branch: PEM and JKS are now
  delivered as separate dimensions; PEM-only hosts see no behavior
  change, JKS-enabled apps gain a dedicated `/api/v1/download/jks/...`
  fetch path.
- **rc2** — Reload hook auto-`chmod +x` on first install.
- **rc3, rc4** — Initial and improved "stay vs revert" semantics
  for the launcher's post-flip self-check.
- **rc5** — Auto-detecting CA bundle bootstrap + daily refresh of
  the bundled Mozilla NSS bundle from the operator's server.
- **rc6** — CentOS 6 `grep` compatibility fix in the bootstrap CA
  bundle validation.
- **rc7** — Reload-hook `set -e` silent-abort fix.

## [v0.3.0 series] — 2026-04-30 .. 2026-05-07

Pre-1.0 stabilization. Public-repo cutover (PUBLIC since 2026-05-03),
release-pipeline maturation, signed-artifact bundle finalized
(cosign-keyless + RSA-4096 detached signature + SPDX SBOM + SHA256SUMS
+ install.sh as release asset).

Notable fleet-impact items from this series:

- **v0.3.0-rc1** — Envelope-v2 cutover: bundle KDF moved from
  multi-tool PBKDF2 fallback chain to single-pass HMAC-SHA256 via
  `openssl dgst -hmac` (supported on openssl 1.0.0+ since
  March 2010). Eliminated the Perl/Python dependency; runs on
  CentOS 6 minimum-install zero-install.
- **v0.3.0-rc7** — Bundled Mozilla NSS CA bundle for old-trust-store
  hosts. Subsequent fetches use `curl --cacert` against the bundled
  file rather than the system trust store.
- **v0.3.0-rc9** — `install.sh` shipped as a release asset so the
  `curl -sSL .../releases/download/<tag>/install.sh | sudo sh`
  one-liner works.
- **v0.3.0-rc10** — Cosign 2.x → 3.x bundle format migration.

## [v0.2.0-rc1] — 2026-05-01

First public-flow release. Install-flow redesign per
operator-internal design doc: secrets stay out of `argv` (the
two-step "install + edit conf" flow this README still documents).

## Conventions

- Tags are signed by `auto-certs/release-signing-key` (RSA-4096,
  AWS Secrets Manager); the public half is pinned in `install.sh`
  starting with rc14.
- Tags use bare semver under `payload/VERSION` and a `v`-prefixed
  form in git (`v1.0.0` for VERSION `1.0.0`).
- Pre-1.0 `-rcN` tags ship through the same staged-rollout state
  machine as GA tags (canary fleet first, exponential expansion
  with per-stage soak + self-check gates).
