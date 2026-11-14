# The fake worker's image (ticket 29), built as the root Dockerfile builds
# knarr's: the same build stage with its tools and runtime closure from the
# flake, an erlang-shipment, and a non-root runtime on the same base. Build it
# from the repository root, so pins.toml and flake.lock are the one owner of
# the OTP version:
#   docker build -f fixtures/fake_worker/Dockerfile .
# Dockerfile.dockerignore beside this file is its context allowlist.
FROM nixos/nix:2.35.6@sha256:b49cb33f3a7e5cf3933ad8774529de0e3807ec5cf54987aa7ccdfb49f2fc55ed AS build
ENV NIX_CONFIG="experimental-features = nix-command flakes"
WORKDIR /opt/knarr
# The flake and the held versions it reads, alone in a directory of their own
# (Decision 0017). A build context has no .git, so Nix reads the directory as a
# path: flake and copies every file in it to the store.
COPY flake.nix flake.lock pins.toml nix/
# gleam, erlang and rebar3 come from the default group; the runtime group is
# the same Erlang and the openssl command, nothing else.
RUN nix build ./nix#default --no-update-lock-file --out-link /opt/knarr/tools \
    && nix build ./nix#runtime --no-update-lock-file --out-link /opt/knarr/runtime-link
# The runtime closure, laid out as the final stage receives it: every store
# path it needs under /out/nix/store, and /out/opt/knarr/runtime a link to the
# environment. Store paths are not relocatable, so they keep their own path.
# It depends on the flake alone, so it sits before the sources: an edit under
# src/ reuses this layer and the final stage's copy of it.
RUN mkdir -p /out/nix/store /out/opt/knarr \
    && nix path-info --recursive /opt/knarr/runtime-link > /opt/knarr/runtime-closure.txt \
    && xargs cp --archive --target-directory=/out/nix/store < /opt/knarr/runtime-closure.txt \
    && ln -s "$(readlink /opt/knarr/runtime-link)" /out/opt/knarr/runtime
ENV PATH="/opt/knarr/tools/bin:${PATH}"
WORKDIR /opt/knarr/fixtures/fake_worker
COPY fixtures/fake_worker/gleam.toml fixtures/fake_worker/manifest.toml ./
RUN gleam deps download
COPY fixtures/fake_worker/src src
RUN gleam export erlang-shipment \
    && erl -noshell -eval 'io:put_chars(erlang:system_info(otp_release)), halt().' > /opt/build-otp

FROM ubuntu:24.04@sha256:24737cef17f4e22b1977df7d9a05e77c4e28b7da5b8911f8d8ccda136bf3573c AS runtime
WORKDIR /opt/fake_worker
COPY --from=build /out/ /
COPY --from=build /opt/knarr/fixtures/fake_worker/build/erlang-shipment /opt/fake_worker/shipment
COPY --from=build /opt/build-otp /opt/build-otp
COPY --chmod=0755 scripts/container-entrypoint.sh /opt/fake_worker/container-entrypoint.sh
ENV PATH="/opt/knarr/runtime/bin:${PATH}" \
    ERL_CRASH_DUMP=/tmp/erl_crash.dump
USER 10001:10001
EXPOSE 8080 8081
ENTRYPOINT ["/opt/fake_worker/container-entrypoint.sh", "/opt/fake_worker/shipment/entrypoint.sh"]
CMD ["run"]
