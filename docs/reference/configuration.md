---
title: "Deployment configuration"
kind: "reference"
audience: ["user", "operator"]
canonical_for: ["deployment_configuration"]
requires: []
---

# Deployment configuration

This reference describes the implemented controller, rather than the published `v0.1.0` skeleton. Follow the [install guide](../how-to/install.md) for release selection. Configuration lives on the Deployment object: the opt-in is a label, and overrides are annotations. Changing these fields does not change the pod template or trigger a rollout ([config.allium](../specs/config.allium), `Configuration` `OptIn`, `Keys`).

## Opt in

Only the exact label value `knarr.io/enabled: "true"` opts a Deployment in. `"True"`, `"yes"`, and an absent label do not; the selected Deployment LIST never sees those objects and emits nothing for them. Apply the following metadata to the Deployment itself, alongside its existing name and spec ([config.allium](../specs/config.allium), `Configuration` `OptIn`):

```yaml
metadata:
  labels:
    knarr.io/enabled: "true"
  annotations:
    knarr.io/status-port: "8080"
    knarr.io/status-path: "/knarr/v1/status"
    knarr.io/thresholds: "300,900,1800,3600"
    knarr.io/threshold-margin: "60"
    knarr.io/poll-interval: "30"
    knarr.io/patch-interval: "60"
```

Knarr matches pods through controller-owner UIDs, Pod → ReplicaSet → Deployment, in its own namespace. All the Deployment's ReplicaSets participate during rollouts. StatefulSets, Jobs, DaemonSets, bare pods, and orphan ReplicaSets are unsupported; they are never matched, rather than detected and refused ([config.allium](../specs/config.allium), `Configuration` `Discovery`, `UnsupportedKinds`).

## Override keys

Defaults below are the shipped install-wide defaults; an install may change them through OTP application configuration. Override names and validation are defined by [config.allium](../specs/config.allium), `Configuration` `Keys`, `Syntax`, `Effective`, `Installed`; default values come from the named owning modules' config blocks.

| Annotation | Valid value | Shipped default | Owning clause |
| --- | --- | --- | --- |
| `knarr.io/status-port` | Integer, 1–65535 | `8080` | [worker_contract](../specs/worker_contract.allium), `StatusEndpoint` `Discovery` |
| `knarr.io/status-path` | Absolute path starting with `/`, no query or fragment | `/knarr/v1/status` | [worker_contract](../specs/worker_contract.allium), `StatusEndpoint` `Discovery`, `Versioning` |
| `knarr.io/thresholds` | Nonempty, strictly increasing positive integers, each at most 2147483647 | `300,900,1800,3600` | [cost_mapping](../specs/cost_mapping.allium), `CostMapping` `Tiers`, `Clamp` |
| `knarr.io/threshold-margin` | Integer ≥ 0, below the first effective threshold | `60` | [cost_mapping](../specs/cost_mapping.allium), `CostMapping` `Tiers`, `Crossing` |
| `knarr.io/poll-interval` | Whole seconds, 5–300, strictly greater than the install-wide poll timeout | `30` | [budget](../specs/budget.allium), `PollSchedule` `Interval`, `Timeout` |
| `knarr.io/patch-interval` | Whole seconds, 0–3600; 0 is valid | `60` | [budget](../specs/budget.allium), `WriteBudget` `PerPod` |

Annotation strings have leading and trailing ASCII space, tab, carriage return, and line feed trimmed. Integers use decimal digits without signs, units, fractions, exponents, or leading zeros except `"0"`. Thus `"30"` is thirty seconds, while `"30s"`, `"+30"`, `"030"`, and `"1m"` are invalid. Threshold-list members are individually trimmed; duplicates, empty members, trailing commas, and zero are invalid ([config.allium](../specs/config.allium), `Configuration` `Syntax`).

Thresholds limit writes rather than quantize the annotation into bands: when a crossing makes a write due, the value is the current clamped cost. The margin damps downward crossings. The first threshold is also the idle boundary, so lowering it changes which costs qualify as busy ([config.allium](../specs/config.allium), `Configuration` `Keys`; [cost_mapping.allium](../specs/cost_mapping.allium), `CostMapping` `Continuous`, `Crossing`, `Absent`).

## Invalid values and unknown keys

An invalid override falls back independently to its install-wide default, leaving other keys and the Deployment's opt-in intact. Cross-value checks use effective values: if a valid threshold override makes the effective margin greater than or equal to the first threshold, the margin falls back to 0 instead. For example, `thresholds: "30,90"` with the default margin of 60 makes the margin invalid even when its annotation is absent ([config.allium](../specs/config.allium), `Configuration` `Effective`, `InvalidValue`).

One `InvalidOverride` Event is attempted on the Deployment per invalid key when first encountered and when its invalid text changes. Repeating the same invalid text emits no further Event until it is fixed, removed, or the Deployment leaves the target set; a restart forgets that history and emits again. Messages name the key, invalid value, reason, and fallback ([config.allium](../specs/config.allium), `Configuration` `InvalidValue`; [observability.allium](../specs/observability.allium), `Events` `InvalidOverride`).

A label under `knarr.io/` other than the opt-in, or an annotation under that prefix other than a defined key, is logged once per discovery cycle and changes no setting. It raises no Event. For example, putting `knarr.io/status-port` in labels does not configure a port. The prefix is fixed; keys under other prefixes are ignored by this check ([config.allium](../specs/config.allium), `Configuration` `Prefix`, `Unknown`).

## Timing and install-wide settings

Opt-in, opt-out, and overrides take effect at the next discovery cycle, every 60 seconds by default. A changed poll interval leaves the already-computed due time in place and affects subsequent rungs; a changed patch interval affects the next attempt; thresholds and margin affect the next reading. Opt-out cleanup is described in [operations](../operations/controller.md#uninstall-and-recover) ([config.allium](../specs/config.allium), `Configuration` `Effective`, `Discovery`).

There are no Deployment overrides for poll timeout, jitter, concurrency, discovery cadence, write-bucket settings, back-off, body limit, log level, or the unknown/absent windows. Install-wide values are read from OTP application configuration at startup; an unset key takes its default, but a wrong type or out-of-range value fails startup and names the key. They do not use the per-Deployment invalid-value fallback ([config.allium](../specs/config.allium), `Configuration` `Keys`, `Installed`).

## Deferred safe-to-evict feature

The parser reserves the annotation `knarr.io/safe-to-evict` and accepts trimmed `"true"`, with absence meaning off and other values invalid. This parse is settled, but the policy is deferred: it is not an available protection to enable or rely on. Thresholds, local-storage handling, and node-pinning policy await [ticket 25](../../.scratch/bootstrap/issues/25-elicit-safe-to-evict-policy.md); [ticket 49](../../.scratch/bootstrap/issues/49-safe-to-evict-user-guidance.md) owns the future user guidance ([config.allium](../specs/config.allium), `Configuration` `SafeToEvict`, open question for 25).
