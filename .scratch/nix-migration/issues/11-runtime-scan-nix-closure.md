# 11: Runtime scan reads the Nix closure

**Context:** `just runtime-scan` exists because the image's Erlang and OpenSSL are not operating-system packages, so the image scan cannot see them ([Decision 0014](../../../docs/decisions/0014-dependency-updates-and-audit.md), bootstrap ticket 45). It copies the conda runtime environment out of the image, runs grype on the directory, and fails unless grype's conda cataloger found packages. After [09](09-images-from-flake.md) the runtime is a Nix closure and that check cannot pass. [01](01-nix-container-spike.md) and [08](08-cluster-audit-tools-from-flake.md) recorded what grype reports for a Nix closure.

**What to build:** `just runtime-scan` scans the Nix runtime the image ships and answers the same question as before: does the shipped Erlang or OpenSSL have a known vulnerability with a fix. It fails closed, exiting non-zero when erlang or openssl was not catalogued at all, so an empty scan never reads as a clean one. If 01 showed grype cannot catalogue the closure, this ticket uses the fallback Decision 0017 names and records the limit.

The comments on the recipe and the audit workflow, the contributing guide's audit section and a Decision 0014 amendment note describe the new scan.

**Non-goals:** Changing `image-scan` or `hex-audit`. Changing the severity threshold. An SBOM, which is bootstrap ticket [38](../../bootstrap/issues/38-attestations-sbom-arm64.md).

**Blocked by:** 09, 10

**MVP critical path:** no.

**Status:** ready-for-agent

- [ ] A test shows the scan exits non-zero when erlang is not catalogued, and again when openssl is not.
- [ ] A test shows a catalogued, clean closure exits 0 and a finding at the threshold exits non-zero.
- [ ] **Authorization required:** the network, for grype's database. `just image-build` then `just runtime-scan` runs locally and the ticket records what was catalogued.
- [ ] **Authorization required:** a dispatched `audit.yml` run. Its `image-scan` job runs the new scan and the hand-back links the run.
- [ ] The audit workflow still runs `runtime-scan` when the image scan fails but the build succeeded.
- [ ] `just test-checkers-selected audit` passes.
- [ ] `just check` ends with "All checks passed and the worktree is unchanged."

## Hand-back notes
