# knarr's image. The flake decides every byte it holds (nix/image.nix, Decision
# 0017): this file only builds that root filesystem with the pinned Nix and
# copies it into an empty image. Docker stays the builder so the same command
# works on an Apple-silicon host, where Nix alone cannot build a Linux image.
FROM nixos/nix:2.35.6@sha256:b49cb33f3a7e5cf3933ad8774529de0e3807ec5cf54987aa7ccdfb49f2fc55ed AS build
WORKDIR /src
COPY flake.nix flake.lock ./
COPY nix nix
RUN nix --extra-experimental-features "nix-command flakes" build --no-update-lock-file --no-link .#image-toolchain
COPY gleam.toml manifest.toml ./
COPY src src
COPY scripts/container-entrypoint.sh scripts/
# /tmp needs a mode the Nix store cannot hold, so it is added here; the chart
# and `just image-check` mount their own over it.
RUN nix --extra-experimental-features "nix-command flakes" build --no-update-lock-file --out-link /result .#knarr-rootfs \
    && mkdir /rootfs \
    && cp -a /result/. /rootfs/ \
    && mkdir -m 1777 /rootfs/tmp

FROM scratch AS runtime
COPY --from=build /rootfs/ /
ENV PATH=/bin \
    ERL_CRASH_DUMP=/tmp/erl_crash.dump
WORKDIR /opt/knarr
USER 10001:10001
EXPOSE 8080
ENTRYPOINT ["/opt/knarr/container-entrypoint.sh", "/opt/knarr/shipment/entrypoint.sh"]
CMD ["run"]
