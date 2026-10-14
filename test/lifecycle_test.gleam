//// Tests for the Cleanup contract (docs/specs/lifecycle.allium): what a
//// View makes due, when a Deployment's cleanup is done, how a View's held
//// entries and its deployment name are built, and the Restart clauses a
//// pure function can witness. Every function is pure, so each test passes
//// values in and reads values out. Each test names the clause or plan
//// obligation it traces to.

import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import knarr/k8s_client.{Owner, ReplicaSet}
import knarr/lifecycle.{
  Held, HeldConflict, HeldOwned, HeldYielded, Removal, View,
}
import knarr/ownership.{AppliedRecord, Entry, Marker, YieldedRecord}

const at = "2026-10-13T10:00:00Z"

const earlier = "2026-10-13T09:00:00Z"

const later = "2026-10-13T11:00:00Z"

const pdc = ownership.pod_deletion_cost

const ste = ownership.safe_to_evict

const pdc_key = "controller.kubernetes.io/pod-deletion-cost"

const ste_key = "cluster-autoscaler.kubernetes.io/safe-to-evict"

const pdc_owned = Held(name: "pod-deletion-cost", standing: HeldOwned)

const ste_owned = Held(name: "safe-to-evict", standing: HeldOwned)

const pdc_conflict = Held(name: "pod-deletion-cost", standing: HeldConflict)

const ste_yielded = Held(name: "safe-to-evict", standing: HeldYielded)

/// The owned annotations a target's Deployment enables by default.
const cost_only = ["pod-deletion-cost"]

/// What a Deployment with the safe-to-evict opt-in enables.
const both_enabled = ["pod-deletion-cost", "safe-to-evict"]

const absent_marker = Marker(None, None, [])

/// A usable marker holding the given entries; `held` reads entries only, so
/// the raw string is immaterial.
fn usable_marker(entries: List(ownership.Entry)) -> ownership.Marker {
  Marker(raw: Some("marker"), at: Some(at), entries:)
}

fn annotations(pairs: List(#(String, String))) -> Option(Dict(String, String)) {
  Some(dict.from_list(pairs))
}

/// A pod of the opted-out Deployment "worker" as a non-target view: nothing
/// enabled, not terminating.
fn non_target(held: List(lifecycle.Held)) -> lifecycle.View {
  View(
    pod_name: "worker-abc",
    deployment: "worker",
    target: False,
    enabled: [],
    terminating: False,
    held:,
  )
}

/// A pod of the opted-in Deployment "worker" as a target view with the
/// annotations `enabled` names.
fn target(
  enabled enabled: List(String),
  held held: List(lifecycle.Held),
) -> lifecycle.View {
  View(
    pod_name: "worker-abc",
    deployment: "worker",
    target: True,
    enabled:,
    terminating: False,
    held:,
  )
}

fn removal(name: String) -> lifecycle.Removal {
  Removal(pod_name: "worker-abc", name:, deployment: "worker")
}

// ----------------------------------------------------------------- Scope ---

// Cleanup.Scope: a non-target pod with an owned record makes one Removal,
// carrying the view's pod name and deployment.
pub fn due_for_a_non_target_with_an_owned_record_is_one_removal_test() -> Nil {
  assert lifecycle.due(non_target([pdc_owned]))
    == [removal("pod-deletion-cost")]
}

// Cleanup.Scope: a yielded record is left as found; nothing is due.
pub fn due_for_a_non_target_with_a_yielded_record_is_none_test() -> Nil {
  assert lifecycle.due(non_target([ste_yielded])) == []
}

// Cleanup.Scope: a conflict record is left as found; nothing is due.
pub fn due_for_a_non_target_with_a_conflict_record_is_none_test() -> Nil {
  assert lifecycle.due(non_target([pdc_conflict])) == []
}

// Cleanup.Scope: a pod whose marker is absent, unusable or edited holds
// nothing, so nothing is due whatever it carries.
pub fn due_for_a_pod_with_no_marker_is_none_test() -> Nil {
  assert lifecycle.held(marker: absent_marker, annotations: None) == []
  assert lifecycle.held(
      marker: absent_marker,
      annotations: annotations([#(pdc_key, "300")]),
    )
    == []
  assert lifecycle.due(non_target([])) == []
}

// Cleanup.Scope: a terminating view makes nothing due, since no patch is
// sent to a terminating pod and no new one is awaited; a Removal already
// outstanding is Done's.
pub fn due_for_a_terminating_pod_with_an_owned_record_is_none_test() -> Nil {
  let view = View(..non_target([pdc_owned, ste_owned]), terminating: True)

  assert lifecycle.due(view) == []
}

// Cleanup.Scope: a target whose Deployment removed the safe-to-evict opt-in
// has only safe-to-evict due; the enabled pod-deletion-cost stays.
pub fn due_for_a_target_without_safe_to_evict_is_that_one_alone_test() -> Nil {
  let view = target(enabled: cost_only, held: [pdc_owned, ste_owned])

  assert lifecycle.due(view) == [removal("safe-to-evict")]
}

// Cleanup.Scope: a target with pod-deletion-cost owned and enabled has
// nothing due.
pub fn due_for_a_target_with_pod_deletion_cost_enabled_is_none_test() -> Nil {
  assert lifecycle.due(target(enabled: cost_only, held: [pdc_owned])) == []
  assert lifecycle.due(
      target(enabled: both_enabled, held: [pdc_owned, ste_owned]),
    )
    == []
}

// Cleanup.Scope: a null applied record with an absent annotation stands
// owned (ownership Adoption), so on a non-target it is due: the marker-only
// patch ownership's Released describes. Built through `held`, which proves
// the standing.
pub fn due_for_a_null_record_with_an_absent_annotation_is_one_removal_test() -> Nil {
  let marker = usable_marker([Entry(pdc, AppliedRecord(None, at))])
  let held = lifecycle.held(marker:, annotations: None)

  assert held == [pdc_owned]
  assert lifecycle.due(non_target(held)) == [removal("pod-deletion-cost")]
}

// Cleanup.Scope: both annotations owned on a non-target make two Removals,
// in held order.
pub fn due_for_a_non_target_with_both_owned_is_two_in_held_order_test() -> Nil {
  assert lifecycle.due(non_target([pdc_owned, ste_owned]))
    == [removal("pod-deletion-cost"), removal("safe-to-evict")]
  assert lifecycle.due(non_target([ste_owned, pdc_owned]))
    == [removal("safe-to-evict"), removal("pod-deletion-cost")]
}

// ----------------------------------------------------------------- Retry ---

// Cleanup.Retry: nothing is remembered about a rejection, so the same view
// at the next cycle makes the same Removals, and a view built at a later
// cycle with the same fields is the same view.
pub fn due_at_two_consecutive_cycles_gives_the_same_removals_test() -> Nil {
  let first = non_target([pdc_owned, ste_owned])
  let next_cycle = non_target([pdc_owned, ste_owned])

  assert next_cycle == first
  assert lifecycle.due(first) == lifecycle.due(next_cycle)
  assert lifecycle.due(next_cycle)
    == [removal("pod-deletion-cost"), removal("safe-to-evict")]
}

// ------------------------------------------------------------------ Done ---

// Cleanup.Done: true with no due views and nothing outstanding; a target
// whose held annotations are all enabled is not due.
pub fn done_is_true_with_no_due_views_and_nothing_outstanding_test() -> Nil {
  let views = [target(enabled: both_enabled, held: [pdc_owned, ste_owned])]

  assert lifecycle.done(views:, outstanding: [], deployment: "worker") == True
  assert lifecycle.done(views: [], outstanding: [], deployment: "worker")
    == True
}

// Cleanup.Done: false while a live, non-terminating view of the Deployment
// has a non-empty due.
pub fn done_is_false_with_one_due_view_test() -> Nil {
  let views = [non_target([pdc_owned])]

  assert lifecycle.done(views:, outstanding: [], deployment: "worker") == False
}

// Cleanup.Done: false while a Removal of the Deployment is pending or in
// flight, though no view shows its pod any more.
pub fn done_is_false_with_an_outstanding_removal_whose_pod_left_the_list_test() -> Nil {
  let outstanding = [
    Removal(
      pod_name: "worker-gone",
      name: "pod-deletion-cost",
      deployment: "worker",
    ),
  ]

  assert lifecycle.done(views: [], outstanding:, deployment: "worker") == False
}

// Cleanup.Done: a terminating pod holds nothing up, so a Deployment whose
// only out-of-scope owned view is terminating is done.
pub fn done_is_true_when_the_only_out_of_scope_view_is_terminating_test() -> Nil {
  let views = [View(..non_target([pdc_owned, ste_owned]), terminating: True)]

  assert lifecycle.done(views:, outstanding: [], deployment: "worker") == True
}

// Cleanup.Done: a terminating view holds nothing up by itself, but a Removal
// of its pod still outstanding, pending or in flight, is awaited like any
// other; once outstanding is empty the Deployment is done.
pub fn done_awaits_an_outstanding_removal_of_a_terminating_pod_test() -> Nil {
  let views = [View(..non_target([pdc_owned]), terminating: True)]
  let outstanding = [removal("pod-deletion-cost")]

  assert lifecycle.done(views:, outstanding:, deployment: "worker") == False
  assert lifecycle.done(views:, outstanding: [], deployment: "worker") == True
}

// Cleanup.Done: done reads only the named Deployment; another Deployment's
// due view and outstanding Removal do not hold it.
pub fn done_reads_only_the_named_deployment_test() -> Nil {
  let views = [View(..non_target([pdc_owned]), deployment: "other")]
  let outstanding = [
    Removal(
      pod_name: "other-abc",
      name: "pod-deletion-cost",
      deployment: "other",
    ),
  ]

  assert lifecycle.done(views:, outstanding:, deployment: "worker") == True
  assert lifecycle.done(views:, outstanding:, deployment: "other") == False
}

// ----------------------------------------------------------------- Label ---

const replica_set_owner =
  Some(Owner(kind: "ReplicaSet", name: "worker-7d9", uid: "rs1"))

const deployment_replica_set =
  ReplicaSet(
    name: "worker-7d9",
    uid: "rs1",
    owner: Some(Owner(kind: "Deployment", name: "worker", uid: "d1")),
  )

// Cleanup.Label: a non-target pod's deployment is the name its ReplicaSet's
// controller owner reference carries.
pub fn deployment_of_a_replica_set_owned_by_a_deployment_is_its_name_test() -> Nil {
  let unrelated = ReplicaSet(name: "other-1a2", uid: "rs2", owner: None)

  assert lifecycle.deployment_of(owner: replica_set_owner, replica_sets: [
      unrelated,
      deployment_replica_set,
    ])
    == "worker"
}

// Cleanup.Label: a chain naming no Deployment gives the empty name: an
// orphan pod, a ReplicaSet the LIST does not show, a ReplicaSet with no
// controller owner, and one whose owner is not a Deployment.
pub fn deployment_of_a_chain_naming_no_deployment_is_empty_test() -> Nil {
  let orphan_replica_set = ReplicaSet(..deployment_replica_set, owner: None)
  let job_replica_set =
    ReplicaSet(
      ..deployment_replica_set,
      owner: Some(Owner(kind: "Job", name: "worker", uid: "j1")),
    )

  assert lifecycle.deployment_of(owner: None, replica_sets: [
      deployment_replica_set,
    ])
    == ""
  assert lifecycle.deployment_of(owner: replica_set_owner, replica_sets: [])
    == ""
  assert lifecycle.deployment_of(owner: replica_set_owner, replica_sets: [
      orphan_replica_set,
    ])
    == ""
  assert lifecycle.deployment_of(owner: replica_set_owner, replica_sets: [
      job_replica_set,
    ])
    == ""
}

// ------------------------------------------------------------------ held ---

// Cleanup.Scope and reconcile Conflict: an applied record that does not
// parse as its annotation's value stands conflict, whatever the annotation
// holds, as the reconciler's view has it.
pub fn held_with_an_applied_record_that_does_not_parse_is_conflict_test() -> Nil {
  let marker =
    usable_marker([
      Entry(pdc, AppliedRecord(Some("abc"), at)),
      Entry(ste, AppliedRecord(Some("maybe"), at)),
    ])

  assert lifecycle.held(
      marker:,
      annotations: annotations([#(pdc_key, "abc"), #(ste_key, "maybe")]),
    )
    == [pdc_conflict, Held(name: "safe-to-evict", standing: HeldConflict)]
}

// Cleanup.Scope and ownership Adoption: a usable record stands as
// ownership's standing says: owned when the annotation equals the applied
// value, conflict when it differs, yielded for a yielded record.
pub fn held_with_usable_records_follows_standing_test() -> Nil {
  let owned_marker =
    usable_marker([
      Entry(pdc, AppliedRecord(Some("300"), at)),
      Entry(ste, AppliedRecord(Some("false"), at)),
    ])
  let found = annotations([#(pdc_key, "300"), #(ste_key, "false")])

  assert lifecycle.held(marker: owned_marker, annotations: found)
    == [pdc_owned, ste_owned]
  assert lifecycle.held(
      marker: owned_marker,
      annotations: annotations([#(pdc_key, "301"), #(ste_key, "false")]),
    )
    == [pdc_conflict, ste_owned]
  assert lifecycle.held(marker: owned_marker, annotations: None)
    == [pdc_conflict, Held(name: "safe-to-evict", standing: HeldConflict)]
  assert lifecycle.held(
      marker: usable_marker([Entry(ste, YieldedRecord(Some("false"), at))]),
      annotations: annotations([#(ste_key, "false")]),
    )
    == [ste_yielded]
}

// Cleanup.Scope: held holds one entry per owned annotation the marker has
// a record for, pod-deletion-cost then safe-to-evict, whatever order the
// marker's entries come in.
pub fn held_is_one_entry_per_record_in_owned_order_test() -> Nil {
  let marker =
    usable_marker([
      Entry(ste, AppliedRecord(Some("false"), at)),
      Entry(pdc, AppliedRecord(Some("300"), at)),
    ])

  assert lifecycle.held(
      marker:,
      annotations: annotations([#(pdc_key, "300"), #(ste_key, "false")]),
    )
    == [pdc_owned, ste_owned]
  assert lifecycle.held(
      marker: usable_marker([Entry(ste, AppliedRecord(Some("false"), at))]),
      annotations: annotations([#(ste_key, "false")]),
    )
    == [ste_owned]
}

// --------------------------------------------------------------- Restart ---

// lifecycle Restart Informational: the marker's at and each record's at
// decide nothing. Two markers differing only in every at are held alike.
pub fn held_ignores_every_at_test() -> Nil {
  let entries = fn(time) {
    [
      Entry(pdc, AppliedRecord(Some("300"), time)),
      Entry(ste, YieldedRecord(Some("false"), time)),
    ]
  }
  let found = annotations([#(pdc_key, "300"), #(ste_key, "false")])
  let old =
    Marker(raw: Some("old"), at: Some(earlier), entries: entries(earlier))
  let new = Marker(raw: Some("new"), at: Some(later), entries: entries(later))

  assert lifecycle.held(marker: old, annotations: found)
    == lifecycle.held(marker: new, annotations: found)
  assert lifecycle.held(marker: old, annotations: found)
    == [pdc_owned, ste_yielded]
}

// lifecycle Restart NoStartupStep: the first discovery cycle after a restart
// derives the cleanups due from its View alone, with no prior state. The
// wiring of that cycle is ticket 47's.
pub fn due_of_a_first_cycle_view_derives_cleanups_with_no_prior_state_test() -> Nil {
  let marker =
    usable_marker([
      Entry(pdc, AppliedRecord(Some("300"), at)),
      Entry(ste, AppliedRecord(Some("false"), at)),
    ])
  let found = annotations([#(pdc_key, "300"), #(ste_key, "false")])
  let first_cycle = non_target(lifecycle.held(marker:, annotations: found))

  assert lifecycle.due(first_cycle)
    == [removal("pod-deletion-cost"), removal("safe-to-evict")]
}

// ------------------------------------------------------------------ Pure ---

// Cleanup.Pure: due, done, held and deployment_of are functions of their
// arguments alone, so applying each twice gives the same value.
pub fn due_done_held_and_deployment_of_are_pure_test() -> Nil {
  let view = target(enabled: cost_only, held: [pdc_owned, ste_owned])
  let outstanding = [removal("safe-to-evict")]
  let marker = usable_marker([Entry(pdc, AppliedRecord(Some("300"), at))])
  let found = annotations([#(pdc_key, "300")])

  assert lifecycle.due(view) == lifecycle.due(view)
  assert lifecycle.done(views: [view], outstanding:, deployment: "worker")
    == lifecycle.done(views: [view], outstanding:, deployment: "worker")
  assert lifecycle.held(marker:, annotations: found)
    == lifecycle.held(marker:, annotations: found)
  assert lifecycle.deployment_of(owner: replica_set_owner, replica_sets: [
      deployment_replica_set,
    ])
    == lifecycle.deployment_of(owner: replica_set_owner, replica_sets: [
      deployment_replica_set,
    ])
}

// ----------------------------------------------------------- Obligations ---

// value-equality.Held and entity-fields.Held: name and standing, by value;
// the standing is one of three.
pub fn held_is_a_name_and_a_standing_test() -> Nil {
  let held = Held(name: "pod-deletion-cost", standing: HeldOwned)
  let standings = [HeldOwned, HeldConflict, HeldYielded]

  assert held.name == "pod-deletion-cost"
  assert held.standing == HeldOwned
  assert held == pdc_owned
  assert held != pdc_conflict
  assert list.length(standings) == 3
  assert list.unique(standings) == standings
}

// value-equality.View and entity-fields.View: pod_name, deployment, target,
// enabled, terminating and held, by value.
pub fn view_has_six_fields_test() -> Nil {
  let view =
    View(
      pod_name: "worker-abc",
      deployment: "worker",
      target: True,
      enabled: ["pod-deletion-cost"],
      terminating: False,
      held: [pdc_owned],
    )

  assert view.pod_name == "worker-abc"
  assert view.deployment == "worker"
  assert view.target == True
  assert view.enabled == ["pod-deletion-cost"]
  assert view.terminating == False
  assert view.held == [pdc_owned]
  assert view == target(enabled: cost_only, held: [pdc_owned])
  assert view != View(..view, terminating: True)
}

// value-equality.Removal and entity-fields.Removal: pod_name, name and
// deployment, by value.
pub fn removal_is_a_pod_name_a_name_and_a_deployment_test() -> Nil {
  let removal =
    Removal(
      pod_name: "worker-abc",
      name: "pod-deletion-cost",
      deployment: "worker",
    )

  assert removal.pod_name == "worker-abc"
  assert removal.name == "pod-deletion-cost"
  assert removal.deployment == "worker"
  assert removal == Removal("worker-abc", "pod-deletion-cost", "worker")
  assert removal != Removal("worker-abc", "safe-to-evict", "worker")
}
// contract-signature.Cleanup.due: (view) -> List<Removal>. Covered by
// due_for_a_non_target_with_an_owned_record_is_one_removal_test and
// due_for_a_non_target_with_both_owned_is_two_in_held_order_test.
// contract-signature.Cleanup.done: (views, outstanding, deployment) ->
// Boolean. Covered by done_is_true_with_no_due_views_and_nothing_outstanding_test
// and done_is_false_with_an_outstanding_removal_whose_pod_left_the_list_test.
// held and deployment_of are the module's builders for ticket 47's View, not
// contract signatures.
