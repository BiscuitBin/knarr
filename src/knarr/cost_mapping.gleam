//// The CostMapping contract (docs/specs/cost_mapping.allium): the pure
//// mapping from a worker's cost, its drain state and the value last applied
//// to the value the pod-deletion-cost annotation should carry, and the
//// canonical string knarr writes for it. Nothing here reads state, time or
//// the pod.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}

/// config.thresholds: the tiers at which a write is due, in seconds of the
/// longest active task.
pub const thresholds: List(Int) = [300, 900, 1800, 3600]

/// config.threshold_margin: how far below a threshold a cost must fall on the
/// way down before the applied value drops.
pub const threshold_margin = 60

/// The largest value the annotation can carry (Clamp).
pub const int32_max = 2_147_483_647

/// The value the annotation carries, as the ReplicaSet controller ranks it:
/// 0 is absent, -1 is drained, and 1 to `int32_max` is the worker's cost.
pub type Mapped {
  Mapped(value: Int)
}

/// The number of thresholds at or below `value`: 0 for -1 and 0 (Tiers).
pub fn tier(value value: Int, thresholds thresholds: List(Int)) -> Int {
  list.count(thresholds, fn(threshold) { threshold <= value })
}

/// The value a reading maps to against the last applied value (Continuous,
/// Sign, Absent, Drained, Clamp, Crossing).
pub fn map(
  cost cost: Int,
  draining draining: Bool,
  applied applied: Mapped,
  thresholds thresholds: List(Int),
  margin margin: Int,
) -> Mapped {
  // Clamp: the clamped cost is what tiers are counted against and what is
  // written.
  let cost = int.min(cost, int32_max)
  let cost_tier = tier(value: cost, thresholds:)
  // An applied value below the first threshold counts as 0 (Crossing): -1 is
  // left on the reading that says so, and a positive value an override's
  // raised first threshold left behind does not survive a reading.
  let base = case tier(value: applied.value, thresholds:) {
    0 -> 0
    _ -> applied.value
  }
  let applied_tier = tier(value: base, thresholds:)
  case draining && cost_tier == 0 {
    // Drained takes precedence below the first threshold, with no margin.
    True -> Mapped(value: -1)
    False ->
      case cost_tier > applied_tier {
        // Crossing upward: the cost itself.
        True -> Mapped(value: cost)
        False ->
          case
            applied_tier >= 1
            && cost < kth_threshold(tier: applied_tier, thresholds:) - margin
          {
            // Crossing downward past the margin: the cost's own tier stands,
            // and tier 0 is absent.
            True ->
              case cost_tier >= 1 {
                True -> Mapped(value: cost)
                False -> Mapped(value: 0)
              }
            // Continuous: between crossings the applied value stands.
            False -> Mapped(value: base)
          }
      }
  }
}

/// The k-th threshold, counting from 1, for a k of at least 1.
fn kth_threshold(tier tier: Int, thresholds thresholds: List(Int)) -> Int {
  case list.drop(thresholds, tier - 1) {
    [threshold, ..] -> threshold
    [] -> 0
  }
}

/// The canonical signed decimal int32 string, or `None` for 0, which is no
/// string at all (Canonical).
pub fn render(mapped: Mapped) -> Option(String) {
  case mapped.value {
    0 -> None
    value -> Some(int.to_string(value))
  }
}

/// The inverse of `render` on canonical strings only: "-1" and the digits of
/// 1 to `int32_max` with no sign, leading zero or whitespace. Anything else,
/// "0" and "+5" among them, is `None`; reconcile's `parse_applied` reads an
/// applied record through it.
pub fn parse(text: String) -> Option(Mapped) {
  // int.parse accepts "+5" and "007"; only a value that renders back to the
  // same text is canonical.
  case int.parse(text) {
    Ok(value) ->
      case
        int.to_string(value) == text
        && { value == -1 || { value >= 1 && value <= int32_max } }
      {
        True -> Some(Mapped(value:))
        False -> None
      }
    Error(Nil) -> None
  }
}
