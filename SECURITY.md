# Security policy

## Supported versions

Knarr is pre-MVP and has no supported published releases yet. Security fixes target current `main`; older revisions are not maintained. [Decision 0012](docs/decisions/0012-release-and-packaging.md) decides how releases are versioned and published; it does not yet say which releases receive security fixes.

| Version | Security support |
| --- | --- |
| Current `main` | Supported during development |
| Older revisions | Not supported |

## Report a vulnerability privately

Use [GitHub's private vulnerability reporting form](https://github.com/biscuitbin/knarr/security/advisories/new) for this repository. You can also reach it from the repository's Security tab by selecting **Report a vulnerability**. Private reporting is enabled; do not publish vulnerability details in a public issue or pull request.

Include the affected commit or version, the impact, the conditions needed to trigger the problem, and a minimal reproduction when possible. Describe the relevant environment and dependencies, but remove credentials, tokens and other private data from examples and logs.

Maintainers will use the private report to discuss reproduction, fixes and disclosure with you. Keep exploit details private while that discussion is underway.
