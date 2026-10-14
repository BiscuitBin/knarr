//// The Cleanup contract (docs/specs/lifecycle.allium): what one pod's View
//// makes due for removal when the pod or an annotation leaves knarr's
//// management, and when a Deployment's cleanup is done. `held` and
//// `deployment_of` build a View's held entries and its deployment name for
//// the discovery cycle that builds the Views (ticket 47). Every function is
//// pure: the views arrive built, and nothing here reads the cluster, a
//// clock, config or state, or sends.

import gleam/bool
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import knarr/k8s_client.{type Owner, type ReplicaSet}
import knarr/ownership.{
  type Marker, type Owned, AppliedRecord, Conflict, Foreign, OwnedByKnarr,
  Unowned, Yielded,
}
import knarr/reconcile

/// Where a held annotation stands under ownership's Adoption: the three
/// standings an annotation with a record can have. Unowned and foreign are
/// the standings of an annotation with no record, which is never held.
pub type HeldStanding {
  HeldOwned
  HeldConflict
  HeldYielded
}

/// One owned annotation the pod's marker holds a record for, by the short
/// name ownership's Owned carries, with where it stands.
pub type Held {
  Held(name: String, standing: HeldStanding)
}

/// One pod as the last discovery cycle in which every LIST succeeded shows
/// it. `deployment` is the name the pod's ReplicaSet's controller owner
/// reference carries, empty when the chain names no Deployment; `target` is
/// whether the pod is in config's target set; `enabled` holds the short
/// names of the owned annotations the pod's Deployment enables, empty for a
/// pod that is not a target; `terminating` is whether deletionTimestamp is
/// set; `held` is one entry per owned annotation the marker holds a record
/// for, none when the marker is absent, unusable or edited.
pub type View {
  View(
    pod_name: String,
    deployment: String,
    target: Bool,
    enabled: List(String),
    terminating: Bool,
    held: List(Held),
  )
}

/// One removal a cleanup makes: the owned annotation, by short name, to
/// remove from the pod together with its record, and the deployment of the
/// View that made it, kept while the Removal is pending or in flight so
/// `done` and the deployment label still find it once the pod has left the
/// pod LIST.
pub type Removal {
  Removal(pod_name: String, name: String, deployment: String)
}

/// The Removals a view makes due (Scope): none for a terminating view, else
/// one per held annotation standing owned whose name is not in `enabled`,
/// in held order. Derived from the view alone, with no memory of earlier
/// cycles, so a cleanup not accepted is due again from every later view
/// that names it (Retry).
pub fn due(view: View) -> List(Removal) {
  use <- bool.guard(view.terminating, [])
  list.filter_map(view.held, fn(held) {
    case held.standing == HeldOwned && !list.contains(view.enabled, held.name) {
      True ->
        Ok(Removal(
          pod_name: view.pod_name,
          name: held.name,
          deployment: view.deployment,
        ))
      False -> Error(Nil)
    }
  })
}

/// True when no live, non-terminating view whose deployment is `deployment`
/// has a non-empty `due`, and `outstanding`, the cleanups pending or in
/// flight, holds no Removal whose deployment is that name (Done). Only each
/// Removal's deployment is read.
pub fn done(
  views views: List(View),
  outstanding outstanding: List(Removal),
  deployment deployment: String,
) -> Bool {
  let nothing_due =
    list.all(views, fn(view) {
      view.deployment != deployment || view.terminating || due(view) == []
    })
  let nothing_outstanding =
    !list.any(outstanding, fn(removal) { removal.deployment == deployment })
  nothing_due && nothing_outstanding
}

/// The held entries of a View (Scope): one per owned annotation the marker
/// holds a record for, pod-deletion-cost then safe-to-evict, each standing
/// as ownership's Adoption has it on the view given, except that an applied
/// record that does not parse as its annotation's value stands conflict
/// (reconcile Conflict), as the reconciler's view has it. For ticket 47's
/// View builder.
pub fn held(
  marker marker: Marker,
  annotations annotations: Option(Dict(String, String)),
) -> List(Held) {
  list.filter_map(ownership.owned_annotations, fn(owned) {
    use record <- result.try(option.to_result(
      ownership.record(marker:, owned:),
      Nil,
    ))
    use standing <- result.map(case record, usable(marker:, owned:) {
      AppliedRecord(..), False -> Ok(HeldConflict)
      _, _ -> held_standing(marker:, annotations:, owned:)
    })
    Held(name: owned.name, standing:)
  })
}

/// Whether the applied record of `owned` parses as its annotation's value:
/// reconcile's parse for pod-deletion-cost and its usable check for
/// safe-to-evict.
fn usable(marker marker: Marker, owned owned: Owned) -> Bool {
  let value = ownership.applied_value(marker:, owned:)
  case owned == ownership.pod_deletion_cost {
    True -> reconcile.parse_applied(value).usable
    False -> reconcile.safe_to_evict_usable(value)
  }
}

/// Ownership's standing as a held standing. Unowned and foreign are the
/// standings of an annotation with no record, and such an annotation is
/// never held, so they make no entry.
fn held_standing(
  marker marker: Marker,
  annotations annotations: Option(Dict(String, String)),
  owned owned: Owned,
) -> Result(HeldStanding, Nil) {
  case ownership.standing(marker:, annotations:, owned:) {
    OwnedByKnarr -> Ok(HeldOwned)
    Conflict -> Ok(HeldConflict)
    Yielded -> Ok(HeldYielded)
    Unowned | Foreign -> Error(Nil)
  }
}

/// A View's deployment (Label): the name the pod's ReplicaSet's controller
/// owner reference carries when the pod's controller owner is a listed
/// ReplicaSet, matched by uid, whose controller owner is a Deployment; the
/// empty string when the chain names no Deployment. The owner-chain lookup
/// mirrors config's targets, which reads the opted-in Deployment list this
/// pod's Deployment is not in.
pub fn deployment_of(
  owner owner: Option(Owner),
  replica_sets replica_sets: List(ReplicaSet),
) -> String {
  let deployment = {
    use owner <- option.then(owner)
    use replica_set <- option.then(controlled_by(owner:, replica_sets:))
    use parent <- option.then(replica_set.owner)
    case parent.kind == "Deployment" {
      True -> Some(parent.name)
      False -> None
    }
  }
  option.unwrap(deployment, "")
}

/// The listed ReplicaSet the controller owner reference names by uid, if
/// any.
fn controlled_by(
  owner owner: Owner,
  replica_sets replica_sets: List(ReplicaSet),
) -> Option(ReplicaSet) {
  use <- bool.guard(owner.kind != "ReplicaSet", None)
  list.find(replica_sets, fn(replica_set) { replica_set.uid == owner.uid })
  |> option.from_result
}
