# Security

## Reporting a vulnerability

Please report security issues **privately** via GitHub's security-advisory system:

> Repository home → **Security** tab → **Report a vulnerability**

This creates a private discussion thread between you and the project maintainers; the advisory becomes public only after we've coordinated a fix.

**Do not** open a public issue or pull request for security problems. Public disclosure before a fix is in the field exposes every CP host running this code.

## What's in scope

- The shell client itself (`launcher.sh`, `install.sh`, `payload/**`).
- The release pipeline (`.github/workflows/release.yml`) — supply-chain integrity of the artifacts you download from the Releases page.
- The signature-verification chain (cosign keyless via Sigstore + GitHub OIDC).

## What's out of scope

- The auto-certs server itself (different codebase, internal).
- Bugs in upstream tooling (`openssl`, `curl`, `tar`, `cosign`, `syft`, GitHub Actions runners) — please report those upstream.

## What we'll commit to

- Acknowledge your report within 5 business days.
- Coordinate a timeline for the fix and the public disclosure.
- Credit you in the release notes / advisory if you wish.
