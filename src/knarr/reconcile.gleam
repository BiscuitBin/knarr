//// The Fallback and Loop contracts (docs/specs/reconcile.allium): a poll's
//// reading becomes a pod state, the window during which an applied value
//// stands after readings stop being valid, the neutral removal that ends it,
//// the contract-absent state, and the decided loop: the desired state of the
//// owned annotations against the marker's applied record, and what is due.
//// Every function is pure: the clock and both windows are passed in, and
//// nothing here reads state, config or the pod, or sends. The reconcile
//// process that keeps each pod's state and sends is `reconciler`.

import gleam/bool
import gleam/list
import gleam/option.{type Option, None, Some}
import knarr/cost_mapping.{Mapped}
import knarr/ownership
import knarr/poller

/// config.unknown_polls: readings that are not valid before a pod is unknown.
pub const unknown_polls = 3

/// config.absent_after: the length, in seconds, of a run of not_found or
/// refused readings before a pod's contract is absent.
pub const absent_after = 300

/// Where a pod is in the reading state machine. "Known" in prose means
/// `Fresh` or `Stale`.
pub type Kind {
  Fresh
  Stale
  Unknown
  Absent
}

/// One pod's state, kept in memory for this run. `failed` is the number of
/// consecutive readings since the last valid one that were not valid;
/// `run_since` is the time of the first reading of the current unbroken run
/// of not_found or refused readings, `None` when there is no run. Times are
/// unix seconds.
pub type PodState {
  PodState(kind: Kind, failed: Int, run_since: Option(Int))
}

/// worker_contract's Reading kinds, verbatim.
pub type ReadingKind {
  Valid
  NotFound
  Invalid
  Refused
  TimedOut
  Unreachable
}

/// One poll's reading as the loop consumes it: the kind, and, for a valid
/// reading, the cost and whether the worker is draining.
pub type Reading {
  Reading(kind: ReadingKind, cost: Option(Int), draining: Bool)
}

/// The parse of the marker's applied record for pod-deletion-cost: usable
/// with value 0 for a null or missing record, usable with the value for a
/// canonical int32 string, and not usable, with value 0, for anything else,
/// which stands as a conflict (Conflict).
pub type Applied {
  Applied(value: Int, usable: Bool)
}

/// The desired state of the two owned annotations: the pod-deletion-cost
/// value as cost_mapping's Mapped, 0 for the removal, and the safe-to-evict
/// string, `None` for absent or the removal.
pub type Desired {
  Desired(cost: Int, safe_to_evict: Option(String))
}

/// Fresh with nothing counted: every pod after a restart (Readings, Restart).
pub fn initial() -> PodState {
  PodState(kind: Fresh, failed: 0, run_since: None)
}

/// The state after one reading produced at `at` (Readings, Window, Absent).
/// A valid reading wins; otherwise a run that has lasted `absent_after`
/// makes the pod absent, an absent pod stays absent, and otherwise `failed`
/// against `unknown_polls` decides between stale and unknown.
pub fn observe(
  state state: PodState,
  reading reading: ReadingKind,
  at at: Int,
  unknown_polls unknown_polls: Int,
  absent_after absent_after: Int,
) -> PodState {
  case reading {
    Valid -> initial()
    NotFound | Refused -> {
      let failed = state.failed + 1
      let since = option.unwrap(state.run_since, at)
      let kind = case state.kind, at - since >= absent_after {
        Absent, _ | _, True -> Absent
        _, False -> window(failed, unknown_polls)
      }
      PodState(kind:, failed:, run_since: Some(since))
    }
    Invalid | TimedOut | Unreachable -> {
      let failed = state.failed + 1
      case state.kind {
        Absent -> PodState(..state, failed:)
        _ ->
          PodState(
            kind: window(failed, unknown_polls),
            failed:,
            run_since: None,
          )
      }
    }
  }
}

fn window(failed: Int, unknown_polls: Int) -> Kind {
  use <- bool.guard(failed >= unknown_polls, Unknown)
  Stale
}

/// True for exactly the kinds unknown and absent (Neutral).
pub fn neutral(state: PodState) -> Bool {
  case state.kind {
    Unknown | Absent -> True
    Fresh | Stale -> False
  }
}

/// The poller's reading as the loop consumes it: `Failed` by its transport,
/// a valid one with its cost and drain state (worker_contract Payload).
pub fn reading(reading: poller.Reading) -> Reading {
  case reading {
    poller.Valid(poller.Status(cost:, accepting:)) ->
      Reading(kind: Valid, cost: Some(cost), draining: !accepting)
    poller.NotFound -> Reading(kind: NotFound, cost: None, draining: False)
    poller.Invalid -> Reading(kind: Invalid, cost: None, draining: False)
    poller.Failed(poller.Refused) ->
      Reading(kind: Refused, cost: None, draining: False)
    poller.Failed(poller.TimedOut) ->
      Reading(kind: TimedOut, cost: None, draining: False)
    poller.Failed(poller.Unreachable) ->
      Reading(kind: Unreachable, cost: None, draining: False)
  }
}

/// The applied record's value for pod-deletion-cost as cost_mapping's value
/// (Desired, Conflict; ownership Applied).
pub fn parse_applied(record: Option(String)) -> Applied {
  case record {
    None -> Applied(value: 0, usable: True)
    Some(text) ->
      case cost_mapping.parse(text) {
        Some(Mapped(value)) -> Applied(value:, usable: True)
        None -> Applied(value: 0, usable: False)
      }
  }
}

/// Whether a safe-to-evict applied record parses as the annotation's value:
/// null, "true" or "false" (Conflict).
pub fn safe_to_evict_usable(record: Option(String)) -> Bool {
  case record {
    None | Some("true") | Some("false") -> True
    Some(_) -> False
  }
}

/// The desired state after `observe` has taken `reading` (Desired): the
/// removal while neutral, the mapped cost for a valid reading, and the
/// applied values otherwise.
pub fn desired(
  state state: PodState,
  reading reading: Reading,
  applied applied: Applied,
  safe_to_evict safe_to_evict: Option(String),
  thresholds thresholds: List(Int),
  margin margin: Int,
) -> Desired {
  case neutral(state), reading {
    True, _ -> Desired(cost: 0, safe_to_evict: None)
    False, Reading(kind: Valid, cost: Some(cost), draining:) -> {
      let Mapped(value) =
        cost_mapping.map(
          cost:,
          draining:,
          applied: Mapped(applied.value),
          thresholds:,
          margin:,
        )
      Desired(cost: value, safe_to_evict:)
    }
    False, _ -> Desired(cost: applied.value, safe_to_evict:)
  }
}

/// The names of the owned annotations whose desired value differs from the
/// applied one, pod-deletion-cost first (Due).
pub fn due(
  desired desired: Desired,
  applied applied: Applied,
  safe_to_evict safe_to_evict: Option(String),
) -> List(String) {
  let cost = case desired.cost != applied.value {
    True -> [ownership.pod_deletion_cost.name]
    False -> []
  }
  let safe = case desired.safe_to_evict != safe_to_evict {
    True -> [ownership.safe_to_evict.name]
    False -> []
  }
  list.append(cost, safe)
}
