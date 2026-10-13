# Ticket 41 evidence

Evidence for the kind check in [ticket 41](../../issues/41-k8s-client-spec-then-build.md) and the json-patch row of [Decision 0013](../../../../docs/decisions/0013-in-cluster-client.md)'s reopen list. `ownership.allium`'s `Precondition` and `WriteMode` rely on how the apiserver's JSON Patch `test` treats null. That behaviour belongs to `gopkg.in/evanphx/json-patch.v4`, which the apiserver's patch handler imports, and no clause states it, so it is recorded here as evidence.

The transcript was gathered on 2026-10-13 (UTC) on an Apple M5 Pro (Darwin arm64), against this worktree's kind cluster: kind v0.33.0, kindest/node with kubelet and apiserver v1.35.8, kubectl v1.34.3, and OrbStack's Docker engine 29.4.0. The transcript's `commit` line names the base commit; the worktree carried ticket 41's uncommitted change, none of which the script reads.

## Rerun

```sh
just cluster-up
sh .scratch/bootstrap/evidence/41/json-patch-null.sh "$(pwd)"
just cluster-down
```

It needs the cluster environment (`just cluster-install`) and Docker, and makes no image pull: its pods run the pause image already on the kind node, with `imagePullPolicy: Never`. It works in a namespace of its own, `knarr-evidence-41`, and deletes it at the end. It prints `ok` or `FAIL` per case and exits non-zero on any `FAIL`.

## Script

| Script | Transcript | What it shows |
| --- | --- | --- |
| [json-patch-null.sh](json-patch-null.sh) `<worktree>` | [json-patch-null.txt](json-patch-null.txt) | Five `kubectl patch --type=json` calls, each with the response status read from kubectl's `-v=6` log. (1) On a pod with no annotations map, testing `/metadata/deletionTimestamp` and `/metadata/annotations` for null and adding the map is accepted with 200. (2) With the map present, testing a missing key for null passes and the add is accepted with 200, and the other annotation is kept. (3) On a pod with no annotations map, testing `/metadata/annotations/knarr.io~1x` for null is refused with 422: a test under a missing parent fails. (4) A test against a value the annotation does not hold is refused with 422, and the annotations are unchanged. (5) On a pod held by a finalizer and then deleted, so `deletionTimestamp` is set, a patch that tests it for null is refused with 422; the finalizer is then cleared and the pod goes |

## Notes

- **Pods are created, not applied.** `kubectl apply` adds the `kubectl.kubernetes.io/last-applied-configuration` annotation, so an applied pod always has an annotations map. A first run used `apply`, so cases 1 and 3 had nothing to test; the script creates its pods with `kubectl create`, and the transcript shows each pod with no map before the cases run.
- **The kubelet writes the pod meanwhile.** Case 4 compares the annotations before and after, not the `resourceVersion`, which the kubelet's status updates move.
- **What the probe proves on top.** The S1 probe now sends case 1's patch through `k8s_client.patch_pod` on a pod with no annotations map, and case 2's without the key's own test on a pod that has one, and its kind run in `.github/workflows/s1-proof.yml` exercises them through knarr's own client. That workflow runs on a push to main that changes its inputs, on `workflow_dispatch`, and on a pull request carrying the `cluster-s1` label.
