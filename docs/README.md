---
title: "Knarr documentation"
kind: "project"
audience: ["contributor", "maintainer", "agent"]
canonical_for: ["documentation_navigation"]
requires: []
---

# Knarr documentation

Knarr is a Kubernetes controller that biases scale-down toward idle or cheap worker pods. The documentation separates learning, practical tasks, explanation, and reference so contributors and agents can find the right kind of answer. Project pages describe direction; decision records explain choices already made.

## Start here

- [Tutorials](tutorials/README.md): a first local check of the repository.
- [How-to guides](how-to/README.md): add or change documentation.
- [Explanation](explanation/README.md): understand the controller's purpose and boundaries.
- [Reference](reference/documentation-contract.md): the documentation contract enforced by the gate, and the [agent contract](reference/agent-contract.md) for the agent guidance, skills and bridges it also enforces.
- [Testing](reference/testing.md): the unit-test toolkit, the snapshot workflow, and the sans-IO pattern.
- [The fake worker fixture](reference/fake-worker.md): the worker image tests on kind run against, and the collector that counts busy kills.
- [Project](project/README.md): current direction and deferred work.
- [Decisions](decisions/README.md): accepted architectural and tooling choices.
- [Run the walking skeleton locally](how-to/local-cluster.md): build, deploy and check the local skeleton.
- [Decision 0010: Prometheus metrics](decisions/0010-metrics.md): the skeleton's metrics choice.
- [Decision 0012: Release and packaging](decisions/0012-release-and-packaging.md): how a release is versioned, published and installed.
- [Decision 0013: In-cluster Kubernetes client](decisions/0013-in-cluster-client.md): verified TLS, token reload and the Role's verbs.

## Maintainer documents

- [Repository README](../README.md): current pre-MVP status and local setup.
- [Contributing](../CONTRIBUTING.md): the ticket frontier, worktrees, authorization, verification and merging.
- [Security policy](../SECURITY.md): supported versions and private vulnerability reporting.
- [Changelog](../CHANGELOG.md): notable unreleased changes.

## Project context

The [overview](OVERVIEW.md) remains a draft direction, not a behavioural specification. Its open questions remain open until the owning ticket settles them. The [visual explainer](overview-explainer.html) illustrates that direction and is best opened locally in a browser.
