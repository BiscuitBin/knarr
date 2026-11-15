# The fake worker's image (ticket 29), built as the root Dockerfile builds
# knarr's: the flake decides its contents, and this file builds that root
# filesystem with the pinned Nix and copies it into an empty image. Build it
# from the repository root, so flake.lock is the one owner of the OTP version:
#   docker build -f fixtures/fake_worker/Dockerfile .
# Dockerfile.dockerignore beside this file is its context allowlist.
FROM nixos/nix:2.35.6@sha256:b49cb33f3a7e5cf3933ad8774529de0e3807ec5cf54987aa7ccdfb49f2fc55ed AS build
WORKDIR /src
COPY flake.nix flake.lock ./
COPY nix nix
RUN nix --extra-experimental-features "nix-command flakes" build --no-update-lock-file --no-link .#image-toolchain
COPY fixtures/fake_worker/gleam.toml fixtures/fake_worker/manifest.toml fixtures/fake_worker/
COPY fixtures/fake_worker/src fixtures/fake_worker/src
COPY scripts/container-entrypoint.sh scripts/
RUN nix --extra-experimental-features "nix-command flakes" build --no-update-lock-file --out-link /result .#fake-worker-rootfs \
    && mkdir /rootfs \
    && cp -a /result/. /rootfs/ \
    && mkdir -m 1777 /rootfs/tmp

FROM scratch AS runtime
COPY --from=build /rootfs/ /
ENV PATH=/bin \
    ERL_CRASH_DUMP=/tmp/erl_crash.dump
WORKDIR /opt/fake_worker
USER 10001:10001
EXPOSE 8080 8081
ENTRYPOINT ["/opt/fake_worker/container-entrypoint.sh", "/opt/fake_worker/shipment/entrypoint.sh"]
CMD ["run"]
