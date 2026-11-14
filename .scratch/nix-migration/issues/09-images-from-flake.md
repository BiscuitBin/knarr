# 09: Images from the flake

**Context:** Both images, knarr's and the fake worker's, build from a pixi base image, fetch rebar3 by checksum, and ship pixi's conda `runtime` environment copied to its original absolute prefix ([Decision 0003](../../../docs/decisions/0003-tool-manager.md), [Decision 0012](../../../docs/decisions/0012-release-and-packaging.md)). A script removes conda's perl from that environment. `image-check` reruns the TLS proof against the shipped OpenSSL and compares the image's OTP with the pin. [01](01-nix-container-spike.md) prototyped the Nix replacement, [06](06-nix-decision-record.md) chose its shape, and [07](07-flake-beside-pixi.md) landed the flake and the held-versions file.

**What to build:** `just image-build` and `just fake-worker-image-build` produce images whose build tools and whose runtime Erlang and OpenSSL come from the flake. Unless Decision 0017 says otherwise, the shape is: a digest-pinned build stage that runs Nix, builds the shipment with gleam as today, and a final Ubuntu stage that receives the runtime closure at one fixed prefix. `docker build` locally and `docker buildx build` in the release workflow keep working unchanged.

- Both Dockerfiles and both build-context allowlists move together. The test that holds them to the same stages keeps holding.
- rebar3 comes from the flake, so the checksum `ADD` and the test that ties it to `tools.txt` retire.
- The runtime prefix constant from [03](03-pin-and-prefix-readers.md) takes its new value.
- `image-check` drops its conda-specific checks and keeps the rest: the TLS rerun, the non-root read-only run, and the OTP comparison, now against the held-versions file.
- The perl prune script and its test are deleted if 01 showed perl is not in the runtime closure, or adapted if it is.
- This ticket's slice of the pin tests and the Renovate configuration moves with it: the build-stage image and the Dockerfile rules.
- Decisions 0003, 0012 and 0014 gain amendment notes for what changed. Bootstrap ticket [38](../../bootstrap/issues/38-attestations-sbom-arm64.md)'s text about the arm64 re-lock route, the fake worker reference page, the local cluster how-to and the deferred-work page are updated. `CHANGELOG.md` records the change.

**Non-goals:** The release workflow's steps. `runtime-scan`, which is [11](11-runtime-scan-nix-closure.md); the round README's "No release between 09 and 11" covers the gap. Deleting `pixi.toml`, which the default gate still uses. An arm64 release image.

**Blocked by:** 03, 06, 07

**MVP critical path:** no.

**Status:** ready-for-agent

- [ ] **Authorization required:** the network, for image pulls and Nix fetches during builds.
- [ ] `just image-build` and `just image-check` pass locally on linux/arm64, and so do the fake worker's pair.
- [ ] `image-check`'s TLS rerun prints all six cases against the OpenSSL the image ships.
- [ ] The image's OTP release and the build stage's both equal the held-versions file.
- [ ] Each Dockerfile still has exactly two digest-pinned `FROM` lines, and `just packaging-check` passes.
- [ ] The image runs as the same non-root user with a read-only root filesystem, and the ticket records its size and its cold and warm build times against the pixi image's.
- [ ] **Authorization required:** a push. On the pull request, `cluster-smoke` and `fake-worker-smoke` pass, and the labelled `keda-e2e` and `cluster-s1` runs pass.
- [ ] The decision amendments, the doc updates and the changelog entry are in, and `just docs-check` passes.
- [ ] `just test-checkers-selected packaging audit policy` passes.
- [ ] `just check` ends with "All checks passed and the worktree is unchanged."

## Hand-back notes
