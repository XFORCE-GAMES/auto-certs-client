# Contributing to auto-certs-client

Thanks for your interest. This repo holds the public shell client that
xforce-games game-CPs install on their production hosts to keep their
TLS certs current. The audience reading the source is CP MIS teams
auditing what runs as root — so the bar is "auditable in 30 minutes by
a sysadmin reading it cold." That shapes everything below.

## How to report a bug

1. **If it's a security issue** — please use the private channel. See
   [SECURITY.md](SECURITY.md). Do not open a public issue.
2. **Otherwise** — open an issue and pick **Bug report**. The template
   asks for OS + openssl version + the smallest reproducing log.
3. **If you can't reproduce it** but you have a hypothesis — open it
   as a discussion-style issue with the **Feature request** template
   (which is also fine for ambiguous reports) and tag the maintainer.

## How to suggest a feature

Open an issue with the **Feature request** template. Two notes up
front:

- The client is deliberately small. We push complexity to the server
  side wherever possible (the design rationale lives in the project's
  internal docs but the short version is: CP hosts are unreachable
  black boxes, so we minimize what runs there). Features that grow
  the client get pushback by default.
- "Add a CLI flag for X" is more likely to land than "rewrite the
  payload loop." The contract surface (config file shape, reload-hook
  env vars, on-disk paths) is frozen at v1.0.0 — see
  [`docs/versioning.md`](docs/versioning.md).

## Pull requests

We accept PRs. A few things make them easier to land:

1. **Open an issue first** for anything non-trivial. Save yourself
   from writing a 500-line change we'd push back on the design of.
2. **Sign your commits** (`git commit -S`). Branch protection on
   `main` enforces signed commits. If you don't have a GPG/SSH signing
   setup, GitHub has a guide:
   <https://docs.github.com/authentication/managing-commit-signature-verification>
3. **Keep changes small and focused.** One commit per logical change.
   The payload has a **2300-line combined LOC budget** (across
   `payload/auto_certs.sh + payload/lib/*.sh`); install.sh has its
   own **800-line budget**. CI enforces both. If your change pushes
   past either, justify it in the PR description.
4. **POSIX `sh` only** in production code. No bashisms (`[[ ]]`,
   `${var,,}`, `<<<`, arrays, `function`, `local`). The portability
   floor is CentOS 6.8 / openssl 1.0.1e / GNU tar 1.23 / GNU grep
   2.20 — empirically verified on canary VMs for every release.
5. **Tests** — the smoke test suite lives in the upstream server repo
   (it shellchecks the payload + runs end-to-end crypto round-trips
   against a mock server). External contributors can't run it
   directly, but you can run `sh -n` (POSIX syntax check) and
   `shellcheck -s sh` against any file you touched. We'll run the
   full suite during review.

## Branch + tag conventions

- **`main`** — protected. Direct push requires review + signed commits
  + CI green.
- **Tag scheme** — `vMAJOR.MINOR.PATCH` (`v1.0.0`) or
  `vMAJOR.MINOR.PATCH-rcN` (`v1.1.0-rc1`) for pre-releases. See
  [`docs/versioning.md`](docs/versioning.md) for what each bump
  promises.
- **Release artifacts** — every tag's release page carries the
  tarball, RSA-4096 detached signature, cosign-keyless Sigstore
  bundle, SPDX SBOM, install.sh, and SHA256SUMS. The release pipeline
  in `.github/workflows/release.yml` produces all of these
  deterministically.

## What the repo expects of contributors

- Be civil. We have a [Code of Conduct](CODE_OF_CONDUCT.md). It's
  short and unsurprising.
- Don't include CP-identifying information in issues or PRs. If you
  need to share a real failure log, redact the host's `app_code`,
  any token-shaped strings (`acert_live_*` / `dl_*`), bundle
  passwords, and IP addresses. The included `redact()` helper in
  `payload/lib/common.sh` does this for the runtime; please apply
  similar discipline to anything you paste into a public discussion.
- Don't ship code that lowers the audit bar. "Clever" is the opposite
  of what we want. The goal is "a sysadmin who has never seen this
  code before can audit it in 30 minutes."

## Things we explicitly don't accept

- New runtime dependencies on the client side (anything beyond the
  POSIX small-toolset baseline + openssl + curl/wget).
- Changes that break the v1.x backwards-compat contract (see
  `docs/versioning.md`).
- Server-side code (this is the client repo; the server is a
  separate codebase that powers the API the client talks to).
- Documentation changes that move us away from "in plain language"
  toward implementation-detail jargon.

## How to verify a release locally

See the [Verifying this release](README.md#verification-posture)
section of the README. Every release ships with both cosign-keyless
(Sigstore) and RSA-4096 detached signatures — independent trust
chains, both verifiable without any auto-certs-specific tooling.

## Questions

Open an issue and tag the maintainer. We try to acknowledge within
a few business days; complex questions may take longer.
