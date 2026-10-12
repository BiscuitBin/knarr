---
title: "Explanation: controller boundaries"
kind: "explanation"
audience: ["contributor", "maintainer", "agent"]
canonical_for: ["controller_explanation_navigation"]
requires: []
---

# Explanation: controller boundaries

Knarr influences which worker pods Kubernetes removes by publishing deletion costs. It does not own replica counts, choose a replacement for the autoscaler, or promise a particular victim. Kubernetes makes the final decision; Knarr provides a best-effort preference based on worker status.

The [project overview](../OVERVIEW.md) develops the proposed polling, ranking, and annotation model. The [visual explainer](../overview-explainer.html) illustrates the cost value and kill paths. Both describe direction while product questions remain unsettled.

Two accepted decisions constrain implementation: [specifications decide behaviour](../decisions/0001-specs-decide-behaviour.md), and [effects live behind sans-IO boundaries](../decisions/0002-sans-io-boundaries.md). These separate what the controller owes from how it talks to HTTP and Kubernetes. Detailed architecture explanations will follow the specification and implementation tickets rather than inventing their answers here.
