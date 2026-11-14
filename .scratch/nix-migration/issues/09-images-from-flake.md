# 09: Images from the flake

**Context:** Both images, knarr's and the fake worker's, build from a pixi base image, fetch rebar3 by checksum, and ship pixi's conda `runtime` environment copied to its original absolute prefix ([Decision 0003](../../../docs/decisions/0003-tool-manager.md), [Decision 0012](../../../docs/decisions/0012-release-and-packaging.md)). A script removes conda's perl from that environment. `image-check` reruns the TLS proof against the shipped OpenSSL and compares the image's OTP with the pin. [01](01-nix-container-spike.md) prototyped the Nix replacement, [06](06-nix-decision-record.md) chose its shape, and [07](07-flake-beside-pixi.md) landed the flake and the held-versions file.

**What to build:** `just image-build` and `just fake-worker-image-build` produce images whose build tools and whose runtime Erlang and OpenSSL come from the flake, in the shape [Decision 0017](../../../docs/decisions/0017-nix-owns-the-toolchain.md) chose from 01's [prototype](../evidence/01/image/Dockerfile): the Nix image as a build stage pinned by the digest of its multi-arch index, which copies the flake files alone, builds the `default` and `runtime` groups, lays the runtime closure out under `/out/nix/store` with `/out/opt/knarr/runtime` linked to it, and then builds the shipment with gleam as today; and the Ubuntu base by today's digest as the final stage, which takes that tree with one `COPY --from=build /out/ /`. The closure is laid out before the sources are copied, so a source edit reruns only the export. `docker build` locally and `docker buildx build` in the release workflow keep working unchanged.

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
