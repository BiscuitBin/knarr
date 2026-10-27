FROM ghcr.io/prefix-dev/pixi:0.81.0@sha256:788ae451641666e2d1f79d3dbe35392dfc7e9b394b16a3acb75c347f3badb2ab AS build
WORKDIR /opt/knarr
COPY pixi.toml pixi.lock ./
RUN pixi install --locked -e default -e runtime
ADD --checksum=sha256:708407032479514dd68b581a0b09a68b5a781fb6f53dcf4ad81ce4ef6b92940f https://github.com/erlang/rebar3/releases/download/3.27.1/rebar3 /opt/knarr/.tools/bin/rebar3
RUN chmod 0755 .tools/bin/rebar3
ENV PATH="/opt/knarr/.pixi/envs/default/bin:/opt/knarr/.tools/bin:${PATH}"
COPY gleam.toml manifest.toml ./
RUN gleam deps download
COPY src src
RUN gleam export erlang-shipment \
    && erl -noshell -eval 'io:put_chars(erlang:system_info(otp_release)), halt().' > /opt/build-otp
# conda-forge's perl 5.32.1 is in the runtime environment only as erlang's
# dependency, and nothing the image runs uses it. Its fixable CVEs go with it
# (ticket 45); just image-check reruns Decision 0003's TLS check in the pruned
# image. Ubuntu's own perl-base stays.
COPY scripts/prune_runtime.py scripts/
RUN .pixi/envs/default/bin/python -I scripts/prune_runtime.py .pixi/envs/runtime perl

FROM ubuntu:24.04@sha256:24737cef17f4e22b1977df7d9a05e77c4e28b7da5b8911f8d8ccda136bf3573c AS runtime
WORKDIR /opt/knarr
COPY --from=build /opt/knarr/.pixi/envs/runtime /opt/knarr/.pixi/envs/runtime
COPY --from=build /opt/knarr/build/erlang-shipment /opt/knarr/shipment
COPY --from=build /opt/build-otp /opt/build-otp
COPY --chmod=0755 scripts/container-entrypoint.sh /opt/knarr/container-entrypoint.sh
ENV PATH="/opt/knarr/.pixi/envs/runtime/bin:${PATH}" \
    ERL_CRASH_DUMP=/tmp/erl_crash.dump
USER 10001:10001
EXPOSE 8080
ENTRYPOINT ["/opt/knarr/container-entrypoint.sh", "/opt/knarr/shipment/entrypoint.sh"]
CMD ["run"]
