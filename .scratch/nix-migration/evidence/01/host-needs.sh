#!/bin/sh
# Ticket 01 evidence: what the gate takes from the machine, beyond the tool
# environment. Run once in the bare Nix image and once on the stand-in host
# without a CA store, in the clone gate-setup.sh prepared, with the network off.
# Usage (host): sh nix.sh --offline sh /evidence/host-needs.sh > host-needs.txt
#               KNARR_HOST_NO_CA=1 sh host.sh --offline sh /evidence/host-needs.sh >> host-needs.txt
set -eu
cd /work/gate/clone
git checkout --quiet .
tools=/work/gate/clone/.pixi/envs/default
logs=/work/gate/logs
mkdir -p "$logs"
if [ -e /etc/os-release ]; then where='the stand-in host, without the CA link'; else where='the Nix image'; fi
printf '\n== On %s\n' "$where"
printf 'on PATH without the prefix:'
for tool in sh git sed awk find diff perl curl dirname; do
  printf ' %s=%s' "$tool" "$(command -v "$tool" > /dev/null 2>&1 && echo yes || echo NO)"
done
printf '\n/usr/bin holds %s entries; a CA store at /etc/ssl/certs/ca-certificates.crt: %s\n' \
  "$(find /usr/bin -mindepth 1 2> /dev/null | wc -l)" "$([ -e /etc/ssl/certs/ca-certificates.crt ] && echo yes || echo NO)"
printf 'in the prototype environment: perl=%s sed=%s\n' \
  "$([ -e "$tools/bin/perl" ] && echo yes || echo NO)" "$([ -e "$tools/bin/sed" ] && echo yes || echo NO)"
for name in manifest-check lint fake-worker-test; do
  status=0
  "$tools/bin/just" "$name" > "$logs/needs-$name.log" 2>&1 || status=$?
  printf 'just %-17s exit %-3s %s\n' "$name" "$status" \
    "$(grep -E -o 'sed: command not found|No CA certificates were loaded from the system|FailedLoadCacerts\(NoCacertsFound\)' "$logs/needs-$name.log" | sort | uniq -c | tr -s ' ' | tr '\n' ';')"
done
printf 'scripts that call perl: %s\n' "$(grep -l -E '(^| )perl ' scripts/release/*.sh | tr '\n' ' ')"
printf 'tests that run with PATH=/usr/bin:/bin: %s\n' "$(grep -l '/usr/bin:/bin' scripts/checks/tests/*.py | tr '\n' ' ')"
