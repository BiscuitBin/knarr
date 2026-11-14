# Prototype for nix-migration ticket 01: evidence, not the repository's
# Dockerfile (ticket 09 writes that one). image.sh stages the build context:
# the prototype flake, gleam.toml, manifest.toml, src/ and the entrypoint.
FROM nixos/nix@sha256:b49cb33f3a7e5cf3933ad8774529de0e3807ec5cf54987aa7ccdfb49f2fc55ed AS build
ENV NIX_CONFIG="experimental-features = nix-command flakes"
WORKDIR /opt/knarr
# The flake goes in a directory of its own. A build context has no .git, so Nix
# reads the directory as a path: flake and copies all of it to the store.
COPY flake.nix flake.lock nix/
# gleam, erlang and rebar3 come from the default group; the runtime group is
# the same Erlang store path and nothing else the build needs.
RUN nix build ./nix#default --no-update-lock-file --out-link /opt/knarr/tools \
    && nix build ./nix#runtime --no-update-lock-file --out-link /opt/knarr/runtime-link
# The runtime closure, laid out as the final stage receives it: every store
# path it needs under /nix/store, and one fixed prefix that links to the
# environment. Store paths are not relocatable, so they keep their own path.
# It depends on the flake alone, so it sits before the sources: an edit under
# src/ then reuses this layer and the final stage's copy of it.
RUN mkdir -p /out/nix/store /out/opt/knarr \
    && nix path-info --recursive /opt/knarr/runtime-link > /out/opt/knarr/runtime-closure.txt \
    && xargs cp --archive --target-directory=/out/nix/store < /out/opt/knarr/runtime-closure.txt \
    && ln -s "$(readlink /opt/knarr/runtime-link)" /out/opt/knarr/runtime
ENV PATH="/opt/knarr/tools/bin:${PATH}"
COPY gleam.toml manifest.toml ./
RUN gleam deps download
COPY src src
RUN gleam export erlang-shipment \
    && erl -noshell -eval 'io:put_chars(erlang:system_info(otp_release)), halt().' > /opt/build-otp

FROM ubuntu:24.04@sha256:24737cef17f4e22b1977df7d9a05e77c4e28b7da5b8911f8d8ccda136bf3573c AS runtime
WORKDIR /opt/knarr
COPY --from=build /out/ /
COPY --from=build /opt/knarr/build/erlang-shipment /opt/knarr/shipment
COPY --from=build /opt/build-otp /opt/build-otp
COPY --chmod=0755 scripts/container-entrypoint.sh /opt/knarr/container-entrypoint.sh
ENV PATH="/opt/knarr/runtime/bin:${PATH}" \
    ERL_CRASH_DUMP=/tmp/erl_crash.dump
USER 10001:10001
EXPOSE 8080
ENTRYPOINT ["/opt/knarr/container-entrypoint.sh", "/opt/knarr/shipment/entrypoint.sh"]
CMD ["run"]
