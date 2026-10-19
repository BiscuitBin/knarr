---
title: "Decision records"
kind: "project"
audience: ["contributor", "maintainer", "agent"]
canonical_for: ["decision_navigation"]
requires: []
---

# Decision records

These records explain accepted choices and the evidence or source material behind them. Their numbering preserves the bootstrap contract, including the reserved positions for decisions carried from libpawdoku. Adapted records name a source revision and the date Knarr adopted the decision; they do not imply that every dependent implementation ticket is complete.

1. [0001: Specifications decide behaviour](0001-specs-decide-behaviour.md).
2. [0002: Effects live behind sans-IO boundaries](0002-sans-io-boundaries.md).
3. [0003: Tool manager](0003-tool-manager.md), settled by ticket 01.
4. [0004: Gate checkers](0004-gate-checkers.md), settled by ticket 02.
5. [0005: A project-managed Allium binary](0005-project-managed-allium-cli.md), implemented by ticket 07.
6. [0006: Apache-2.0](0006-apache-2-0.md).
7. [0007: Local cluster and test tiers](0007-local-cluster.md), settled by ticket 10.
8. [0008: safe-to-evict on upstream Cluster Autoscaler](0008-safe-to-evict-on-upstream-ca.md), settled by ticket 15.
9. [0009: The Allium objective map](0009-allium-objective-map.md), settled by ticket 17.
10. [0010: Prometheus metrics](0010-metrics.md), settled by ticket 13.
11. [0011: Report-only source coverage](0011-coverage.md), settled by ticket 26.
12. [0012: Release and packaging](0012-release-and-packaging.md), settled by ticket 28.
13. [0013: In-cluster Kubernetes client](0013-in-cluster-client.md), settled by ticket 14.
14. [0014: Dependency updates and audit](0014-dependency-updates-and-audit.md), settled by ticket 27.
15. [0015: knarr ships a Helm chart](0015-helm-chart.md), settled by helm chart ticket 01.

Read the [project direction](../project/README.md) for proposals and open questions. A later change to an accepted choice should amend or supersede its record explicitly, preserving enough context for a reader to understand why the choice changed.
