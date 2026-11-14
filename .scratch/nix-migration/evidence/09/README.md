# Nix migration ticket 09 evidence

Evidence for [ticket 09](../../issues/09-images-from-flake.md): both images built from the flake, checked, and measured against the pixi images of the commit the ticket started from.

Gathered on 2026-11-14 on the maintainer's Apple-silicon Mac (18 cores) with Docker 29.6.1. **Everything here is linux/arm64.** Nix ran only inside the images' build stage, `nixos/nix:2.35.6@sha256:b49cb33f…`; nothing was installed on the host, and no Nix container or volume outside `docker build` was used. Ticket 08 was running on the same Docker at the same time, so the times are an order of magnitude, as ticket 01's were.

## How it ran

Each build context is `git archive` of a commit, staged under the gitignored `ai_tmp/09/`, so nothing uncommitted and nothing outside the allowlists reaches it. The Nix images are the branch at `2b6dd72`, the commit that changed the Dockerfiles; every later commit on the branch changes no file either allowlist admits. The pixi images are `da7fd81`, the commit the branch started from.

| Script | Network | What it shows |
| --- | --- | --- |
| [build.sh](build.sh) | on | Each image on each backend: a `--no-cache` build, a warm one, one after an edit under `src/`, and its size |
| [layers.sh](layers.sh) | off | Which steps of knarr's Nix image an edit under `src/` reruns |
| [check.sh](check.sh) | off | `just image-check` and `just fake-worker-image-check`, the whole OTP version in each stage, and the runtime closure |
| [recipes.sh](recipes.sh) | on | The four recipes as a contributor runs them from the worktree: both builds, then both checks |

```sh
E=.scratch/nix-migration/evidence/09
sh $E/build.sh 2b6dd72 > $E/build.txt
sh $E/layers.sh > $E/layers.txt
sh $E/check.sh > $E/check.txt
sh $E/recipes.sh > $E/recipes.txt
```

## Findings

1. **Both images build from the flake and pass their checks.** `just image-build` and `just fake-worker-image-build`, run from the worktree, exit 0, and so do the two checks on what they built ([recipes.txt](recipes.txt)). `just image-check knarr-09:nix` and `just fake-worker-image-check fake-worker-09:nix`, the unchanged recipes, exit 0 with `image: OTP 29, numeric user and read-only runtime verified`: the image declares `USER 10001:10001`, bounds its descriptors, runs with a read-only root filesystem, every capability dropped and `no-new-privileges`, and starts: knarr answers `/readyz` and reports its startup metric, and the fake worker delivers its kill record and drains on SIGTERM ([check.txt](check.txt)).
2. **The TLS rerun passes on the OpenSSL the image ships.** In knarr's image, with `/opt/knarr/runtime/bin/openssl` and `escript` first on `PATH`, `tls_check: all 6 cases matched` on OTP 29.1.2 (erts 17.1.1) with `OpenSSL 3.5.9 29 Sep 2026`, which `crypto:info_lib()` also reports ([check.txt](check.txt)).
3. **One OTP version from `pins.toml` to both stages.** `pins.toml` holds 29.1.2. In both images the build stage and the final image report `OTP_VERSION` 29.1.2, and both run `erl` from the same store path, `/nix/store/3awv3q0c…-erlang-29.1.2` ([check.txt](check.txt)). `image-check` itself compares the major, 29, as before.
4. **The closure is 19 store paths and has no perl.** `/opt/knarr/runtime` links to `/nix/store/fz2pjscc…-knarr-runtime`, whose `bin` holds Erlang's commands and `openssl`. The store paths are Erlang, OpenSSL (library and command), glibc, gcc's runtime libraries, ncurses, zlib, gmp, and bash, coreutils, gawk and gnused with their libraries, which Erlang's own scripts call. No store path and no file under `/nix/store` is named `perl*`. Both images carry the same store paths ([check.txt](check.txt)).
5. **A source edit reruns only the export.** After a comment is appended to `src/knarr.gleam`, every step before `COPY src src` is `CACHED`, the two `nix build` steps and the closure's layout among them, and so is the final stage's `COPY --from=build /out/ /` ([layers.txt](layers.txt)).
6. **Sizes and build times** (`docker image inspect`'s `.Size`; seconds from [build.txt](build.txt)):

   | Image | Size | Cold | Warm | After a `src/` edit |
   | --- | --- | --- | --- | --- |
   | knarr, pixi | 103.6 MB | 17 | 0 | 4 |
   | knarr, Nix | 114.3 MB | 50 | 1 | 11 |
   | fake worker, pixi | 121.8 MB | 18 | 0 | 3 |
   | fake worker, Nix | 113.7 MB | 45 | 0 | 11 |

   knarr's Nix image is 10.7 MB larger, the size ticket 01's prototype was; the fake worker's is 8.1 MB smaller. A cold build fetches the default group and the runtime closure from cache.nixos.org on every build. The edit rebuild's extra seconds are the export of the larger build stage: the gleam export itself took 2.4 seconds ([layers.txt](layers.txt)).

## What this does not show

- linux/amd64. CI builds that image on the pull request, which this ticket was not authorized to push. Ticket 05 built and checked the prototype for linux/amd64 on the runner.
- The release workflow's `docker buildx build`. The Dockerfile has no build argument or platform-specific step, so nothing in it differs under buildx, but no release ran.
- `just runtime-scan`, which cannot decide on a Nix closure until ticket 11.
- The kind and kwok smoke jobs, `keda-e2e` and `cluster-s1`, which need the push.
