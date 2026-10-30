---
title: "Tutorials: first repository check"
kind: "tutorial"
audience: ["contributor", "maintainer", "agent"]
canonical_for: ["first_repository_check"]
requires: []
---

# Tutorials: first repository check

This introductory exercise confirms that your checkout can run the local gate. It does not deploy Knarr or create a cluster; the [local cluster guide](../how-to/local-cluster.md) runs the controller on kind, and the [install guide](../how-to/install.md) installs a published release.

1. Follow the repository's [getting started instructions](../../README.md#getting-started) to initialize the pinned tools and dependencies.
2. Run `just build` from the repository root. A successful build checks the Gleam code with warnings treated as errors.
3. Run `just docs-check` to validate the handbook's metadata and navigation.
4. Run `just check` to exercise the complete local gate. It reports failures without repairing files.

Read the [documentation contract](../reference/documentation-contract.md) to understand a docs failure. The [how-to guide](../how-to/README.md) explains how to register a new page.
