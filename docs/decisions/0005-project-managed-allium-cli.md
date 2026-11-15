---
title: "Decision 0005: A project-managed Allium binary"
kind: "decision"
audience: ["contributor", "maintainer", "agent"]
canonical_for: ["decision_allium_cli"]
requires: []
---

# Decision 0005: A project-managed Allium binary

Amended by [Decision 0017](0017-nix-tool-manager.md): the pin moved from `tools.txt` to `nix/allium.nix`, which takes the same release binary by version and SHA-256 for each host, Linux arm64 now among them, and the binary is `.nix/tools/bin/allium`. What this record decides is unchanged: a project-managed release binary, one owner for its pin, a runner that checks the installed version and reads JSON, and a gate that runs offline.

Adapted on 2026-10-07 from libpawdoku’s [0005-project-managed-allium-cli.md](https://github.com/steven-cutting/libpawdoku/blob/51d8b55ac4f769a6a4d66abacb9642a7d4062127/docs/decisions/0005-project-managed-allium-cli.md) at commit `51d8b55ac4f769a6a4d66abacb9642a7d4062127`. The source record remains in its original repository.

## Decision

Use the Allium specification tool from `juxt/allium-tools` as a project-managed release binary, pinned by version and SHA-256 for each supported platform. Install it into the ignored `.tools/bin/` directory through the existing `tools.txt` installer. `tools.txt` owns the pin; there is no second installer or global Allium dependency.

This carries the source record's checksum-pinned binary choice while adopting Knarr's [tool-manager decision](0003-tool-manager.md) and [gate-checker decision](0004-gate-checkers.md). The initial agreed version is 3.6.1. Ticket 07 owns adding its platform entries, copying the runner, and wiring the specification checks. That ticket may amend this record if its findings differ; those checks are not delivered by the documentation lane.

## Consequences

The runner must check the installed version against `tools.txt` and inspect JSON diagnostics rather than trusting the process exit status. Initialization owns downloads; the quality gate runs offline and refuses a missing or mismatched tool. A version change includes new verified checksums for both supported platforms.

This is the specification-language tool, not an unrelated package sharing the Allium name. The choice keeps its executable and verification behaviour reproducible without making contributors install a separate development toolchain. See [Decision 0004](0004-gate-checkers.md#allium-the-installer-is-dropped-the-runner-reads-toolstxt) for the runner's detailed obligations.
