#!/bin/sh
# Host workaround only: the amd64 release image runs under Rosetta on an arm64
# host only with the BEAM JIT's single memory mapping. Adds ERL_AFLAGS before
# the chart's ERL_FLAGS; ERL_AFLAGS is prepended to the emulator's arguments.
set -eu
perl -pe 's/^(\s*)- name: ERL_FLAGS$/$1- name: ERL_AFLAGS\n$1  value: "+JMsingle true"\n$1- name: ERL_FLAGS/'
