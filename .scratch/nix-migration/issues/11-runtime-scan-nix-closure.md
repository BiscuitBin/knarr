# 11: Runtime scan reads the Nix closure

**Context:** `just runtime-scan` exists because the image's Erlang and OpenSSL are not operating-system packages, so the image scan cannot see them ([Decision 0014](../../../docs/decisions/0014-dependency-updates-and-audit.md), bootstrap ticket 45). It copies the conda runtime environment out of the image, runs grype on the directory, and fails unless grype's conda cataloger found packages. After [09](09-images-from-flake.md) the runtime is a Nix closure and that check cannot pass.

[01](01-nix-container-spike.md) changed this ticket's premise ([grype.txt](../evidence/01/grype.txt), with the flake's grype 0.120.0 and a database built 2026-10-30):

- `conda-meta-cataloger` finds nothing in a Nix closure, so today's script answers "cannot decide" for any Nix image.
- grype **does** catalogue the closure, through `nix-cataloger` (from the store path names) and `binary-classifier-cataloger`, and logs them in the same line shape: `discovered 18 packages cataloger=nix-cataloger`. Both find erlang 29.1.2 and openssl 3.5.9.
- It does so from the image as well as from a directory. Store paths are visible in an image where conda's records were not, so `grype <image>`, which is `just image-scan`, already catalogues the Nix Erlang and OpenSSL beside Ubuntu's packages.
- Erlang's advisories match only through `binary-classifier-cataloger`'s `erlang` package. In a control of the same packages at OTP 29.1.1 and OpenSSL 3.5.8, the three Erlang matches were all on that package, and `nix-cataloger`'s `erlang` and the 34 OTP application packages matched nothing. OpenSSL matched through both.
- The control ran on the directory source only. That an image scan matches as the directory scan does is an inference from its cataloguing the same two packages the same way.

**What to build:** `just runtime-scan` scans the Nix runtime the image ships and answers the same question as before: does the shipped Erlang or OpenSSL have a known vulnerability with a fix.

- **A control on the image source first.** Build an image whose runtime is a known-vulnerable closure (01's control used OTP 29.1.1 and OpenSSL 3.5.8 from the `nixpkgs-gleam` revision) and scan it as an image. If it matches as the directory control did, `runtime-scan` scans the image directly and no longer copies the runtime out. If it does not, `runtime-scan` keeps copying the closure out of the image, now the store paths behind `/opt/knarr/runtime`, and scans the directory. The ticket records which, with the control's transcript.
- **Fail closed on the cataloger that matches.** The scan exits non-zero unless `binary-classifier-cataloger` catalogued `erlang`, and unless `openssl` was catalogued, so an empty or partial scan never reads as a clean one. "Some cataloger found something" is not enough: `nix-cataloger`'s `erlang` alone would let every Erlang advisory through.

The comments on the recipe and the audit workflow, the contributing guide's audit section and a Decision 0014 amendment note describe the new scan.

**Non-goals:** Changing `image-scan` or `hex-audit`. Changing the severity threshold. An SBOM, which is bootstrap ticket [38](../../bootstrap/issues/38-attestations-sbom-arm64.md).

**Blocked by:** 09, 10

**MVP critical path:** no.

**Status:** ready-for-agent

- [ ] A test shows the scan exits non-zero when `binary-classifier-cataloger` did not catalogue erlang (even when `nix-cataloger` did), and again when openssl is not catalogued.
- [ ] A test shows a catalogued, clean closure exits 0 and a finding at the threshold exits non-zero.
- [ ] **Authorization required:** the network, for grype's database and the control image's Nix fetches. The image-source control is recorded, with what matched, and the ticket states whether the scan reads the image or a copied directory.
- [ ] **Authorization required:** the network, for grype's database. `just image-build` then `just runtime-scan` runs locally and the ticket records what was catalogued.
- [ ] **Authorization required:** a dispatched `audit.yml` run. Its `image-scan` job runs the new scan and the hand-back links the run.
- [ ] The audit workflow still runs `runtime-scan` when the image scan fails but the build succeeded.
- [ ] `just test-checkers-selected audit` passes.
- [ ] `just check` ends with "All checks passed and the worktree is unchanged."

## Hand-back notes
