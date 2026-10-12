# The fake worker's image (ticket 29), built as the root Dockerfile builds
# knarr's: the locked pixi environments, the checksum-pinned rebar3, an
# erlang-shipment, and a non-root runtime on the same base. Build it from the
# repository root, so pixi.lock is the one owner of the OTP version:
#   docker build -f fixtures/fake_worker/Dockerfile .
# Dockerfile.dockerignore beside this file is its context allowlist.
FROM ghcr.io/prefix-dev/pixi:0.81.0@sha256:788ae451641666e2d1f79d3dbe35392dfc7e9b394b16a3acb75c347f3badb2ab AS build
WORKDIR /opt/knarr
COPY pixi.toml pixi.lock ./
RUN pixi install --locked -e default -e runtime
ADD --checksum=sha256:708407032479514dd68b581a0b09a68b5a781fb6f53dcf4ad81ce4ef6b92940f https://github.com/erlang/rebar3/releases/download/3.27.1/rebar3 /opt/knarr/.tools/bin/rebar3
RUN chmod 0755 .tools/bin/rebar3
ENV PATH="/opt/knarr/.pixi/envs/default/bin:/opt/knarr/.tools/bin:${PATH}"
WORKDIR /opt/knarr/fixtures/fake_worker
COPY fixtures/fake_worker/gleam.toml fixtures/fake_worker/manifest.toml ./
RUN gleam deps download
COPY fixtures/fake_worker/src src
RUN gleam export erlang-shipment \
    && erl -noshell -eval 'io:put_chars(erlang:system_info(otp_release)), halt().' > /opt/build-otp

FROM ubuntu:24.04@sha256:534baea6a22c03a63003dbc8dbe78fe34bc0d7e595d9a9dc9834884ff530eb55 AS runtime
WORKDIR /opt/fake_worker
COPY --from=build /opt/knarr/.pixi/envs/runtime /opt/knarr/.pixi/envs/runtime
COPY --from=build /opt/knarr/fixtures/fake_worker/build/erlang-shipment /opt/fake_worker/shipment
COPY --from=build /opt/build-otp /opt/build-otp
COPY --chmod=0755 scripts/container-entrypoint.sh /opt/fake_worker/container-entrypoint.sh
ENV PATH="/opt/knarr/.pixi/envs/runtime/bin:${PATH}" \
    ERL_CRASH_DUMP=/tmp/erl_crash.dump
USER 10001:10001
EXPOSE 8080 8081
ENTRYPOINT ["/opt/fake_worker/container-entrypoint.sh", "/opt/fake_worker/shipment/entrypoint.sh"]
CMD ["run"]
