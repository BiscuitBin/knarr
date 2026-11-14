# 09: Images from the flake

**Context:** Both images, knarr's and the fake worker's, build from a pixi base image, fetch rebar3 by checksum, and ship pixi's conda `runtime` environment copied to its original absolute prefix ([Decision 0003](../../../docs/decisions/0003-tool-manager.md), [Decision 0012](../../../docs/decisions/0012-release-and-packaging.md)). A script removes conda's perl from that environment. `image-check` reruns the TLS proof against the shipped OpenSSL and compares the image's OTP with the pin. [01](01-nix-container-spike.md) prototyped the Nix replacement, [06](06-nix-decision-record.md) chose its shape, and [07](07-flake-beside-pixi.md) landed the flake and the held-versions file.

**What to build:** `just image-build` and `just fake-worker-image-build` produce images whose build tools and whose runtime Erlang and OpenSSL come from the flake, in the shape [Decision 0017](../../../docs/decisions/0017-nix-owns-the-toolchain.md) chose from 01's [prototype](../evidence/01/image/Dockerfile): the Nix image as a build stage pinned by tag and the digest of its multi-arch index, `FROM nixos/nix:2.35.6@sha256:b49cb33f3a7e5cf3933ad8774529de0e3807ec5cf54987aa7ccdfb49f2fc55ed` (with the digest alone Renovate never proposes a move, as [05](05-nix-ci-renovate-spike.md) found), which copies the flake files alone, builds the `default` and `runtime` groups, lays the runtime closure out under `/out/nix/store` with `/out/opt/knarr/runtime` linked to it, and then builds the shipment with gleam as today; and the Ubuntu base by today's digest as the final stage, which takes that tree with one `COPY --from=build /out/ /`. The closure is laid out before the sources are copied, so a source edit reruns only the export. `docker build` locally and `docker buildx build` in the release workflow keep working unchanged.

- Both Dockerfiles and both build-context allowlists move together. The allowlists admit `flake.nix`, `flake.lock` and `pins.toml`. A build context has no `.git`, so the flake is read as a `path:` flake and every file beside it is copied to the store: the build stage copies those three files alone into a directory of their own before it runs Nix. The test that holds the two Dockerfiles to the same stages keeps holding.
- rebar3 comes from the flake, so the checksum `ADD` and the test that ties it to `tools.txt` retire.
- The runtime prefix constant from [03](03-pin-and-prefix-readers.md) becomes `/opt/knarr/runtime`, a link into `/nix/store`.
- `image-check` keeps the TLS rerun, the non-root read-only run, and the OTP comparison, now against `pins.toml`. Its conda checks and its perl checks have nothing left to do and go: 01 found no perl in Erlang's closure.
- The perl prune script, `scripts/prune_runtime.py`, and its test are deleted, for the same reason.
- The `runtime` group carries the `openssl` command, which the TLS rerun makes its certificates with.
- This ticket's slice of the pin tests and the Renovate configuration moves with it: the build-stage image and the Dockerfile rules.
- Decisions 0012 and 0014 gain amendment notes for what changed. Decision 0003 is superseded and gains none. Bootstrap ticket [38](../../bootstrap/issues/38-attestations-sbom-arm64.md)'s text about the arm64 re-lock route, the fake worker reference page, the local cluster how-to and the deferred-work page are updated. `CHANGELOG.md` records the change.

**Non-goals:** The release workflow's steps. `runtime-scan`, which is [11](11-runtime-scan-nix-closure.md); the round README's "No release between 09 and 11" covers the gap. Deleting `pixi.toml`, which the default gate still uses. An arm64 release image.

**Blocked by:** 03, 06, 07

**MVP critical path:** no.

**Status:** done on its branch, awaiting a pull request. See [the hand-back notes](#hand-back-notes).

- [x] **Authorization required:** the network, for image pulls and Nix fetches during builds.
- [x] `just image-build` and `just image-check` pass locally on linux/arm64, and so do the fake worker's pair.
- [x] `image-check`'s TLS rerun prints all six cases against the OpenSSL the image ships.
- [x] The image's OTP release and the build stage's both equal the held-versions file.
- [x] Each Dockerfile still has exactly two digest-pinned `FROM` lines, and `just packaging-check` passes.
- [x] The image runs as the same non-root user with a read-only root filesystem, and the ticket records its size and its cold and warm build times against the pixi image's.
- [ ] **Authorization required:** a push. On the pull request, `cluster-smoke` and `fake-worker-smoke` pass, and the labelled `keda-e2e` and `cluster-s1` runs pass.
- [x] The decision amendments, the doc updates and the changelog entry are in, and `just docs-check` passes.
- [x] `just test-checkers-selected packaging audit policy` passes.
- [x] `just check` ends with "All checks passed and the worktree is unchanged."

## Hand-back notes

### What changed

- **`Dockerfile` and `fixtures/fake_worker/Dockerfile`** are 01's prototype shape with Decision 0017's changes. The build stage is `FROM nixos/nix:2.35.6@sha256:b49cb33f…`, tag and digest. It copies `flake.nix`, `flake.lock` and `pins.toml` alone into `nix/`, builds `./nix#default` and `./nix#runtime` with `--no-update-lock-file`, lays the runtime closure out under `/out/nix/store` with `/out/opt/knarr/runtime` linked to the environment, and only then copies the sources and runs `gleam deps download` and `gleam export erlang-shipment` with the default group's tools. The final stage is the Ubuntu base by today's digest and takes the tree with `COPY --from=build /out/ /`; `PATH` starts with `/opt/knarr/runtime/bin`. The fake worker's build stage is byte-identical to knarr's from `FROM` to the tools' `ENV PATH` line. `NIX_CONFIG` turns on flakes, as in the prototype. rebar3's checksum `ADD` and the prune step are gone.
- **The allowlists**, `.dockerignore` and `fixtures/fake_worker/Dockerfile.dockerignore`, admit `flake.nix`, `flake.lock` and `pins.toml` in place of `pixi.toml` and `pixi.lock`; the root one no longer admits the prune script.
- **`scripts/checks/_runtime.py`:** `PREFIX` is `/opt/knarr/runtime`. **`scripts/checks/image.py`:** `verify_runtime_environment` keeps only the TLS rerun, with the shipped runtime's own erlang and openssl; the conda and perl checks are gone. The OTP comparison already read `pins.toml` (07).
- **Deleted:** `scripts/prune_runtime.py` and `test_prune_runtime.py`, with their entries in `checker_suite.py` (the `packaging` group's module list and three path lists) and `ruff.toml`. `fixtures/fake_worker/Dockerfile.dockerignore` joins the `packaging` group's inputs, since a test now reads it.
- **Tests.** `test_runtime.py`: the prefix test asserts the new shape (`COPY --from=build /out/ /`, the link at `/out` plus `PREFIX`, the closure copy, `PREFIX/bin` first on `PATH`). `test_image.py`: the rebar3 `ADD` test retires; the same-stages test compares the whole toolchain stage of both Dockerfiles; new cases hold the closure's layout before the source copy, and both allowlists to the three flake files with no pixi, prune or tools entry; the knarr profile runs exactly one command, the TLS rerun. `test_dependency_pins.py`: the two-digest-pinned-`FROM` test runs on both Dockerfiles; a new test holds both build stages to `nixos/nix` by tag and digest, identical in both; the pixi version has four sites, not five, and the pixi group loses its dockerfile entry; the `nixos/nix` stage in each Dockerfile is a routine update with no group and no approval rule. Red first: the prefix and TLS-profile cases failed before `_runtime.py` and `image.py` changed.
- **`.github/renovate.json`:** only two descriptions changed, for the pixi version's four places. The `nixos/nix` build stage needs no rule: the dockerfile manager reads its tag and digest, and `docker:pinDigests` keeps the digest.
- **Text:** `runtime_scan.py`'s docstring names `_runtime.PREFIX` and says it cannot decide on a closure until 11; `pixi.toml`'s OTP comment no longer says the Dockerfiles read `pixi.lock`.
- **Docs:** amendment notes on Decision 0012 (CI build time, the arm64 probe, the cost of arm64) and Decision 0014 (the base-image bullet, the pixi version's places, the runtime scan, the perl prune, the re-lock route, ticket 38's lane); none on 0003. The fake worker reference page, the local cluster how-to's "Image and checks" section (not its cluster-tools line, which is 08's), `DEFERRED.md`'s arm64 entry, bootstrap ticket 38's text and box, and a `CHANGELOG.md` entry. The two links to the deleted prune script, in 0014's body and bootstrap 45's hand-back, now point to it at `d7cf7b4` on GitHub, so the offline link check passes and the text is unchanged. That URL was not checked: `just links-audit` needs the network, which this ticket had only for builds.
- **Evidence** in [`../evidence/09/`](../evidence/09/README.md): four scripts, their transcripts and a README. The images were built from `2b6dd72`, the commit that changed the Dockerfiles; no later commit changes a file either allowlist admits.
- **One departure from the prototype:** the closure's path list, `runtime-closure.txt`, stays in the build stage at `/opt/knarr/runtime-closure.txt`; the prototype wrote it under `/out` and so shipped it in the image.

### What was verified, and where

All on the Mac, linux/arm64, Docker 29.6.1, with Nix only inside `docker build`; ticket 08 was using the same Docker at the time.

- Box 2: `just image-build`, `just fake-worker-image-build`, `just image-check` and `just fake-worker-image-check` all exit 0 from the worktree ([recipes.txt](../evidence/09/recipes.txt)).
- Box 3: `tls_check: all 6 cases matched` with `/opt/knarr/runtime/bin/openssl`, OpenSSL 3.5.9, and OTP 29.1.2 ([check.txt](../evidence/09/check.txt)).
- Box 4: `pins.toml` holds 29.1.2; the build stage and the image of both images report `OTP_VERSION` 29.1.2 from the same store path, and `/opt/build-otp` is 29. `image-check` itself still compares the major only, as before; the whole version is in the evidence ([check.txt](../evidence/09/check.txt)).
- Box 5: both Dockerfiles have exactly two `FROM` lines pinned by digest (`test_dependency_pins.py`); `just packaging-check` passes, hadolint (pixi's) included.
- Box 6: `USER 10001:10001`, read-only root, every capability dropped, under `image-check`. Sizes and times ([build.txt](../evidence/09/build.txt), [README](../evidence/09/README.md#findings)): knarr 114.3 MB against 103.6 MB, cold 50 s against 17, after a `src/` edit 11 s against 4; the fake worker 113.7 MB against 121.8 MB, cold 45 s against 18, after an edit 11 s against 3. A source edit reruns only the export ([layers.txt](../evidence/09/layers.txt)).
- The closure is 19 store paths, the same in both images, with no perl ([check.txt](../evidence/09/check.txt)).
- Box 8 and 9: `just docs-check` passes; `just test-checkers-selected packaging audit policy` had 296 passed. `just test-checkers-all` had 922 passed, no failure.
- Box 10: `just check` ends with "All checks passed and the worktree is unchanged.", with every change staged, after these notes; `git status --short` is empty after the commit.

Not verified:

- **Box 7, the push.** Not authorized; left open. Nothing ran on linux/amd64: CI's `cluster-smoke`, `fake-worker-smoke`, `keda-e2e` and `cluster-s1` build the amd64 image from this Dockerfile, which only ticket 05's prototype run covers.
- The release workflow's `docker buildx build`. No step in the Dockerfile depends on the builder.
- The gate under `KNARR_TOOLS=nix`, so hadolint 2.14.0 from the flake has not linted these Dockerfiles; pixi's has.
- `just runtime-scan`: it cannot decide on a closure, as the round README says.

The network was used only inside `docker build`, read-only: the Nix builds fetched from cache.nixos.org, the three nixpkgs sources and allium's release asset from github.com, and the hex packages; the pixi baseline builds fetched conda-forge packages, the rebar3 release asset and the hex packages. Both base images were already pulled, so nothing new came from a registry, and nothing was pushed.

Left on the Mac's Docker: the images `knarr-09:pixi`, `knarr-09:nix`, `knarr-09:nix-build`, `fake-worker-09:pixi`, `fake-worker-09:nix`, `fake-worker-09:nix-build` and `knarr:09-nix`, and their build cache. No volume was created and nothing was pruned. Under the gitignored `ai_tmp/09/` are the staged contexts and the logs.

### What later tickets need

- **10.** The images do not depend on the backend: nothing in either build reads `KNARR_TOOLS`, `.pixi/` or `.nix/`. Run the Nix gate once on these Dockerfiles, since the flake's hadolint (2.14.0) is older than pixi's. `reconcile-proof.yml`'s push paths list `Dockerfile` and `.dockerignore` but never listed `pixi.lock`, and do not list `flake.nix`, `flake.lock` or `pins.toml` now; a `main` push that moves only the flake does not rerun the proof. Whether it should is a choice this ticket left alone.
- **11.** `/opt/knarr/runtime` is a symbolic link to `/nix/store/…-knarr-runtime`, not a directory: `docker cp` of `_runtime.PREFIX`, which `runtime_scan.py` does today, copies the link alone. The closure is the 19 paths in [check.txt](../evidence/09/check.txt), and the build stage leaves their list at `/opt/knarr/runtime-closure.txt`, which the final image does not carry. `runtime_scan.py`'s docstring already says it cannot decide on a closure.
- **12.** The build stage is `nixos/nix:2.35.6@sha256:b49cb33f…` in both Dockerfiles, identical, and the pin tests hold that. The dockerfile manager handles it with no rule, so it is a routine update that waits only for the landing hold, where the pixi build stage it replaced waited for approval in the pixi group. Whether it should wait for approval, or move with the CI installer's Nix version, is 12's or 10's to decide. The pixi regex manager and its four sites are untouched for 12 or 13 to remove.
- **13.** `tools.txt` keeps its rebar3 lines for the pixi gate. `pixi.toml`'s OTP comment names the images as reading the flake. Nothing in the images or their checks names pixi or conda any more, except `runtime_scan.py`, which is 11's.
