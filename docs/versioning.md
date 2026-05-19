# Versioning policy

This is the contract between this project and CP MIS teams running
`auto_certs.sh` in production. It defines what every tag of
`auto-certs-client` means and what we promise to keep stable.

## TL;DR

- We use **Semantic Versioning 2.0.0** (<https://semver.org/>).
- The number under `payload/VERSION` is **bare semver** (`1.0.0`);
  the git tag is the same with a `v` prefix (`v1.0.0`).
- Pre-1.0.0 releases used `-rcN` suffixes (`v0.4.0-rc14`); post-1.0.0
  we use SemVer pre-release identifiers only for actual pre-releases
  (`v1.1.0-rc1`), not as the default cadence.
- An in-flight rollout that fails the staged self-check is **never**
  promoted; the failure pauses the rollout, MIS gets notified, and
  existing hosts stay on their current version.

## What 1.0.0 commits to

When `v1.0.0` ships, we commit to:

1. **SemVer discipline.** Backwards-incompatible changes increment
   the MAJOR version. Any tag of the form `v1.x.y` is API-compatible
   with any other `v1.x.y` — a CP can pin to a `v1` series (via the
   `?AUTO_CERTS_INSTALL_RELEASE=v1.x.y` env var on install for a
   specific tag, or `/releases/latest/` for tracking-latest) and
   trust that the `auto_certs.sh` ↔ server API contract will not
   break under them.

2. **Self-update path stability.** The `launcher.sh` + `updater.sh`
   shape is frozen as of 1.0.0 — these scripts are installed once at
   `install.sh` time and are **not** auto-updated by the rolling
   payload. Any future change to the launcher contract requires a
   coordinated install.sh re-run (which CPs only do via the
   documented one-liner on the README).

3. **Reload-hook contract.** The CP's `/opt/auto-certs/reload.sh`
   receives `AUTO_CERTS_APP_CODE` and `AUTO_CERTS_CERT_DIR` in env.
   These two variable names are stable across the 1.x series. Adding
   more env vars to the hook in 1.x is allowed (additive); renaming
   or removing either of these is a 2.0 break.

4. **On-disk layout stability.** The paths that a CP's reload hook /
   monitoring / nagios / etc. inspect are stable across 1.x:
   - `/opt/auto-certs/launcher.sh` — the cron entry
   - `/opt/auto-certs/current` — symlink to the active payload dir
   - `/opt/auto-certs/payload-vX.Y.Z/` — versioned payload dirs (one
     per installed/rolled version)
   - `/opt/auto-certs/reload.sh` — CP-owned reload script (we never
     overwrite past install)
   - `/etc/auto-certs/conf.d/<app>.conf` — per-app config (CP-owned
     after first edit)
   - `/etc/auto-certs/machine_id` — first-contact lazy UUID (must be
     excluded from any golden-image seal)
   - `/var/log/auto-certs/` — per-app log dirs
   - `/var/lib/auto-certs/state/` — per-app state (BASE_DOMAIN cache,
     etc.)
   - `/var/lib/auto-certs/queue/` — failed-report retry queue

5. **install.sh integrity floor.** Every published release tarball
   carries:
   - `<tarball>.release.sig` — RSA-4096 detached signature,
     verifiable against the pinned public key in `install.sh` itself.
   - `<tarball>.sigstore.json` — cosign-keyless Sigstore bundle, for
     transparency-log auditing by anyone who wants to verify the
     pipeline ran cleanly.
   - `<tarball>.sbom.spdx.json` — SPDX SBOM.
   - `SHA256SUMS` — every artifact's SHA-256.

   The signature is verified **before** extract; a release without a
   valid `.release.sig` is refused. (See the v0.4.0-rc14 CHANGELOG
   entry for the hardening details.)

## When we bump MAJOR (1.x.y → 2.0.0)

Any of:

- **Reload-hook env contract change** — renaming or removing
  `AUTO_CERTS_APP_CODE` or `AUTO_CERTS_CERT_DIR`.
- **On-disk path migration** — moving any of the paths listed in
  section 4 above. (Adding new paths is MINOR.)
- **`/api/v1/check` request/response wire-format break** that
  requires a coordinated client/server upgrade (not just additive
  fields).
- **Pinned `release-signing` public key rotation** — the pinned key
  in `install.sh` changes. Because the new install.sh can't verify
  releases signed by the old key (and vice-versa), this is a hard
  break in the "fetch a fresh install.sh and re-run" sense. We treat
  a key rotation as a MAJOR bump even though no other contract
  moves.

## When we bump MINOR (1.0.x → 1.1.0)

Additive functionality that doesn't break existing hosts:

- New optional config keys in `/etc/auto-certs/conf.d/<app>.conf`.
- New env vars passed to the reload hook (existing ones unchanged).
- New `/api/v1/...` endpoints, or new optional fields in existing
  responses.
- New `--<flag>` modes on `auto_certs.sh` (e.g. `--self-check`,
  `--diagnose`).

A MINOR bump never requires a CP to do anything. The next cron tick
picks up the new version through the normal rollout machinery.

## When we bump PATCH (1.0.0 → 1.0.1)

Bug fixes and security hardening that don't change behavior CPs
depend on. PATCH bumps are routine — they ship through the same
staged-rollout state machine as MINOR bumps, and CPs are not
consulted unless a specific app's reload fails (per the "alert MIS,
never the CP directly" policy).

## Pre-release tags (`-rcN`)

We use them for hardening passes and staged validation, NOT as a
release cadence. The shape:

- `v1.1.0-rc1`, `v1.1.0-rc2`, ... — pre-releases for the `v1.1.0`
  cut. Each rc is a candidate; only the final `v1.1.0` is "the
  release."
- Pre-release tags are marked `prerelease=true` on the GitHub
  release page and do **not** match `/releases/latest/`. CPs on
  `latest` will not pick them up until the final tag is cut.

Internal canaries exercise pre-releases through the staged rollout;
real CPs only see GA tags.

## Rollout safety guarantees

Independent of the version policy, every release goes through a
staged rollout state machine:

- **Stage 1**: internal canary pool. At least one self-check PASS is
  required before promotion.
- **Stage 2..N**: exponential expansion across the fleet, gated on
  (a) per-stage self-check PASS, (b) per-stage soak time (default
  24h, overridable per rollout), (c) absence of fleet-wide
  failure-pattern clusters for the new version.
- **Auto-revert**: if a host's self-check fails after the launcher
  flip, the updater sidecar reverts the symlink to the previous
  payload and reports the failure. Host-state-only failures
  (`hook_placeholder`, `hook_missing_or_not_exec`,
  `cert_dir_missing`) return rc=0 instead of triggering revert,
  because those are CP-action gaps, not regressions.

A CP can never "wake up to a broken version" because the staged
rollout would have caught it on a canary first.

## What we explicitly do NOT promise

- **Calendar cadence.** We don't promise a release every N weeks.
  Releases ship when there's something worth shipping.
- **LTS branches.** There's one supported line — the latest 1.x.y.
  Hosts on older 1.x patches will be told to upgrade if a security
  issue is found on the older line; we do not backport fixes.
- **Major versions co-existing.** A future v2.0.0 will require all
  CPs to migrate within a published deprecation window. We do not
  run two majors in parallel.
- **Self-update for the launcher/updater.** Those scripts are
  installed once at `install.sh` time. A future architectural shift
  that wants to change the launcher contract requires the CP to
  re-run the install one-liner (which they only do via the README's
  documented command).
- **Paid support.** This is a volunteer-staffed open-source project.
  Issues and security reports get best-effort responses on the SLAs
  documented in `SECURITY.md`.

## Where to look

- [`payload/VERSION`](../payload/VERSION) — single source of truth
  for the current release. Bare semver (`1.0.0`).
- [`CHANGELOG.md`](../CHANGELOG.md) — what changed in every release.
- [`SECURITY.md`](../SECURITY.md) — how to report a vulnerability.
- [`CONTRIBUTING.md`](../CONTRIBUTING.md) — how to contribute fixes.
- [`README.md`](../README.md) — install instructions + verification
  posture.
