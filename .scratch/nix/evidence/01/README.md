# Evidence for Decision 0017: Nix owns the tools and the images

Gathered on 2026-11-14 (UTC) on Linux x86_64, in a cloud container running as root, with Nix 2.34.6 and Docker 29.9.2. [Decision 0017](../../../../docs/decisions/0017-nix-tool-manager.md) cites it. Nothing here ran on macOS or on Linux arm64; the decision's verification section says which claims that leaves open.

The nixpkgs pin throughout is `d4f25a3e562008648d45bcf2d70bcc7422cad84e`, the `nixos-unstable` channel release `nixos-26.11pre1117658.d4f25a3e5620`.

## Files

| File | What it is |
| --- | --- |
| [pins.json](pins.json) | The version record the tool environment carries, as `just tool-versions` printed it |
| [rootfs-smoke.sh](rootfs-smoke.sh) | The image checks, run on the root filesystem the flake builds, in a chroot and without Docker |
| [rootfs-smoke.txt](rootfs-smoke.txt) | Its transcript against `knarr-rootfs` |

## What nixpkgs carries

`nix eval` of each attribute's version at the pin, then `nix build --dry-run` of the tool set for each of the three systems:

- Every tool the gate, the cluster recipes and the audit use is in the pin, and Allium is not. [pins.json](pins.json) lists the versions.
- `beamMinimal29Packages.erlang` is 29.1.2 and `beamMinimal29Packages.rebar3` is 3.28.0, the versions pixi pinned.
- `kubectl` is 1.37.2, two minors ahead of the 1.35 clusters, which is why `nix/kubectl.nix` pins the upstream 1.36.0 binary instead.
- The dry run fetched every path and built none: 74 paths on x86_64-linux, 64 on aarch64-linux and 87 on aarch64-darwin. So no host builds Erlang or any other tool from source.
- The built environment's closure holds one Erlang and one rebar3 (`nix path-info -r .nix/tools`), and no perl.

## The gate's two Nix checks

Run against a copy of the flake whose `flake.nix` named a different channel than its `flake.lock`:

| Command | Result on the stale lock |
| --- | --- |
| `nix flake metadata --no-update-lock-file --offline .` | Refused: "requires lock file changes but they're not allowed due to '--no-update-lock-file'" |
| `nix eval --raw --read-only --offline --no-update-lock-file .#default` | Refused, the same message |
| `nix flake check --no-build --all-systems --no-update-lock-file --offline` | Refused, the same message |

`flake.lock` was byte-identical after all three. On the repository itself, with the lock current, the evaluation behind `env-check` took 2.0 s and the two commands behind `lock-check` took 0.04 s and 4.2 s.

## The shipment builds with no network

A probe derivation built in the same store listed its root as `bin build dev etc nix proc tmp` and found no network interface, so builds here run in Nix's sandbox. In that sandbox:

- `nix build .#knarr-shipment` compiled all 38 hex packages from their fixed-output tarballs, the three rebar3 packages (`ddskerl`, `hpack_erl`, `prometheus`) among them, and exported the shipment in 10 s.
- `nix build .#knarr-rootfs .#fake-worker-rootfs` produced `/nix/store/ckjwj7za…-knarr-rootfs` and `/nix/store/kkgx8jdi…-fake_worker-rootfs`.
- The same two builds from a copy of each Dockerfile's build context, a directory with only the allow-listed files and no `.git`, produced the same two store paths.

## The root filesystem behaves as the image must

[rootfs-smoke.txt](rootfs-smoke.txt): as uid 10001, with `PATH=/bin` and nothing else in the environment, the build's and the runtime's OTP release are both 29, the TLS check matched all 6 cases with OpenSSL 3.5.9, knarr answered `/readyz` and counted one startup, the process that received SIGTERM was `beam.smp`, and it exited 0.

## The images, built by Docker

Both Dockerfiles were built unchanged except for two lines after `WORKDIR /src` that gave the build stage this container's proxy certificate, with `--network=host` and the proxy's address as build arguments. Nothing else can reach the network from a build here.

- `Dockerfile`: 73 s from an empty builder. The image is 215 MB on disk as `du` reads it inside the container, with `User` `10001:10001`, the entrypoint `scripts/checks/image.py` expects, `PATH=/bin`, and architecture amd64.
- `fixtures/fake_worker/Dockerfile`: 30 s, reusing the first build's toolchain layer.
- `scripts/checks/image.py` passed for both, the fake worker's SIGTERM drain included. knarr used 49.95 MiB of its 256 MiB limit. One flag was dropped for the run: this container's hard descriptor limit is 20000, so Docker could not start a container with `--ulimit=nofile=131072:131072`, and the wrapper's cap at 65536 was not exercised above it. `scripts/checks/tests/test_container_entrypoint.py` covers the wrapper itself.
- `scripts/checks/runtime_scan.py` copied `/nix` out of the knarr image and grype 0.120.0 logged `discovered 18 packages cataloger=nix-cataloger`, beside 34 OTP applications and 3 binaries. grype ran without its vulnerability database, so this shows what it catalogues and nothing about what it matches.

## What could not run here

- `just test`: 671 of 676 Gleam tests pass. The other five open IPv6 sockets, and this container's kernel has no IPv6 (`socket(AF_INET6)` fails with "Address family not supported"). They fail the same way under any toolchain.
- kind and kwok clusters, the audit workflow's scans with a vulnerability database, GitHub Actions and its cache, and Renovate.
