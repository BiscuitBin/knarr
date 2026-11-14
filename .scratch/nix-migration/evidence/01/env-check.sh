#!/bin/sh
# Ticket 01 evidence: a prototype of the environment check ticket 07 writes.
# Read-only and offline. It proves three things about an installed tool group:
#   1. the out-link resolves into the store;
#   2. it is the environment this commit's flake and flake.lock describe;
#   3. the held versions are the versions the installed tools report.
# Usage: sh env-check.sh <flake> <out-link>
set -eu
flake=${1:?usage: env-check.sh <flake> <out-link>}
link=${2:?usage: env-check.sh <flake> <out-link>}
refuse() {
  printf 'env-check: %s\n' "$1" >&2
  exit 2
}
value() { nix eval --raw --offline --no-update-lock-file "$flake#$1"; }

have=$(readlink "$link") || refuse "$link is not a link; build the environment first"
[ -e "$have/bin" ] || refuse "$link points at $have, which is not in the store"
want=$(value "packages.$(nix config show system).default.outPath")
[ "$have" = "$want" ] || refuse "$link is $have, but this commit describes $want"

installed() { # tool, held attribute, version the tool reports
  held=$(value "held.$2")
  [ "$3" = "$held" ] || refuse "$1 reports $3, the hold is $held"
}
installed gleam gleam "$("$link/bin/gleam" --version | cut -d' ' -f2)"
# The full OTP version is in a file; erlang:system_info(otp_release) is the major only.
installed erlang erlang "$("$link/bin/erl" -noshell -eval \
  '{ok, V} = file:read_file(filename:join([code:root_dir(), "releases", erlang:system_info(otp_release), "OTP_VERSION"])), io:put_chars(string:trim(V)), halt().')"
installed openssl openssl "$("$link/bin/openssl" version | cut -d' ' -f2)"
installed rebar3 rebar3 "$("$link/bin/rebar3" --version | cut -d' ' -f2)"
installed allium allium "$("$link/bin/allium" --version | cut -d' ' -f2)"
printf 'env-check: %s is %s, and the held versions match\n' "$link" "$have"
