# Security policy

## Supported versions

Knarr is early and pre-1.0. The latest stable release and current `main` receive security fixes. A fix lands on `main` and ships as a new patch release cut from it; no fix is backported to an older release. Prereleases, such as `0.3.1-rc.1`, are not supported. [Decision 0012](docs/decisions/0012-release-and-packaging.md) decides how releases are versioned and published.

| Version | Security support |
| --- | --- |
| 0.3.1, the latest stable release | Supported |
| Current `main` | Supported |
| Older releases | Not supported |
| Prereleases | Not supported |

## Report a vulnerability privately

Use [GitHub's private vulnerability reporting form](https://github.com/biscuitbin/knarr/security/advisories/new) for this repository. You can also reach it from the repository's Security tab by selecting **Report a vulnerability**. Private reporting is enabled; do not publish vulnerability details in a public issue or pull request.

Include the affected commit or version, the impact, the conditions needed to trigger the problem, and a minimal reproduction when possible. Describe the relevant environment and dependencies, but remove credentials, tokens and other private data from examples and logs.

Maintainers will use the private report to discuss reproduction, fixes and disclosure with you. Keep exploit details private while that discussion is underway.
