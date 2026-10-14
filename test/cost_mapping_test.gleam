//// Tests for the CostMapping contract (docs/specs/cost_mapping.allium): the
//// tier count, the mapping from a reading and the last applied value to the
//// annotation's value, and the canonical string and its inverse. Every
//// function is pure, so each test passes literals in and compares literals
//// out. Each test names the clause or plan obligation it traces to.

import gleam/option.{None, Some}
import knarr/cost_mapping.{type Mapped, Mapped}
import qcheck

// The default thresholds, written out so no test computes an expectation
// through the module under test.
const thresholds = [300, 900, 1800, 3600]

const margin = 60

fn map(
  cost cost: Int,
  draining draining: Bool,
  applied applied: Int,
) -> Mapped {
  cost_mapping.map(
    cost:,
    draining:,
    applied: Mapped(value: applied),
    thresholds:,
    margin:,
  )
}

fn tier(value: Int) -> Int {
  cost_mapping.tier(value:, thresholds:)
}

// ----------------------------------------------------------------- Tiers ---

// CostMapping.Tiers: tier is the number of thresholds at or below the value,
// so -1 and 0 are tier 0 and each threshold starts its own tier.
pub fn tier_counts_the_thresholds_at_or_below_the_value_test() -> Nil {
  assert tier(-1) == 0
  assert tier(0) == 0
  assert tier(299) == 0
  assert tier(300) == 1
  assert tier(899) == 1
  assert tier(900) == 2
  assert tier(1800) == 3
  assert tier(3600) == 4
  assert tier(2_147_483_647) == 4
}

// CostMapping.Tiers: a single-threshold list has tiers 0 and 1 only.
pub fn tier_against_a_single_threshold_test() -> Nil {
  assert cost_mapping.tier(value: 299, thresholds: [300]) == 0
  assert cost_mapping.tier(value: 300, thresholds: [300]) == 1
  assert cost_mapping.tier(value: 5000, thresholds: [300]) == 1
}

// ---------------------------------------------------------------- Absent ---

// CostMapping.Absent: a reading below the first threshold from an absent
// annotation stays 0.
pub fn reading_below_the_first_threshold_from_absent_stays_absent_test() -> Nil {
  assert map(cost: 299, draining: False, applied: 0) == Mapped(value: 0)
  assert map(cost: 0, draining: False, applied: 0) == Mapped(value: 0)
}

// -------------------------------------------------------------- Crossing ---

// CostMapping.Crossing: a reading whose tier is above applied's maps to the
// cost itself.
pub fn crossing_the_first_threshold_maps_to_the_cost_test() -> Nil {
  assert map(cost: 300, draining: False, applied: 0) == Mapped(value: 300)
}

// CostMapping.Crossing: crossing a later threshold maps to the cost itself.
pub fn crossing_the_second_threshold_maps_to_the_cost_test() -> Nil {
  assert map(cost: 900, draining: False, applied: 300) == Mapped(value: 900)
  assert map(cost: 900, draining: False, applied: 0) == Mapped(value: 900)
}

// CostMapping.Crossing: below the k-th threshold minus the margin, the
// reading maps to the cost when the cost's own tier is at least 1.
pub fn dropping_below_the_margin_maps_to_the_cost_test() -> Nil {
  assert map(cost: 839, draining: False, applied: 900) == Mapped(value: 839)
}

// CostMapping.Crossing: within the margin below the k-th threshold the
// applied value stands.
pub fn dropping_within_the_margin_keeps_applied_test() -> Nil {
  assert map(cost: 850, draining: False, applied: 900) == Mapped(value: 900)
  assert map(cost: 250, draining: False, applied: 839) == Mapped(value: 839)
}

// CostMapping.Crossing: below the first threshold minus the margin, the
// reading maps to 0 because the cost's own tier is 0.
pub fn dropping_below_the_first_margin_maps_to_absent_test() -> Nil {
  assert map(cost: 239, draining: False, applied: 839) == Mapped(value: 0)
}

// CostMapping.Crossing: the example in the clause. A drop from 950 to 250
// with thresholds 300 and 900 and margin 60 maps to 0, the new value's own
// tier, not to 300.
pub fn dropping_two_tiers_lands_on_the_new_tier_test() -> Nil {
  assert cost_mapping.map(
      cost: 250,
      draining: False,
      applied: Mapped(value: 950),
      thresholds: [300, 900],
      margin: 60,
    )
    == Mapped(value: 0)
  assert map(cost: 250, draining: False, applied: 950) == Mapped(value: 0)
}

// CostMapping.Crossing: with margin 0 the drop is at the threshold itself.
pub fn margin_zero_drops_at_the_threshold_test() -> Nil {
  assert cost_mapping.map(
      cost: 299,
      draining: False,
      applied: Mapped(value: 300),
      thresholds: [300],
      margin: 0,
    )
    == Mapped(value: 0)
  assert cost_mapping.map(
      cost: 300,
      draining: False,
      applied: Mapped(value: 300),
      thresholds: [300],
      margin: 0,
    )
    == Mapped(value: 300)
}

// CostMapping.Crossing: an applied value above 0 whose own tier is 0, left
// behind by an override that raised the first threshold, counts as 0.
pub fn applied_below_a_raised_first_threshold_counts_as_absent_test() -> Nil {
  let raised = fn(cost, draining) {
    cost_mapping.map(
      cost:,
      draining:,
      applied: Mapped(value: 300),
      thresholds: [900, 1800],
      margin: 60,
    )
  }

  assert raised(0, False) == Mapped(value: 0)
  assert raised(100, True) == Mapped(value: -1)
  assert raised(950, False) == Mapped(value: 950)
}

// ------------------------------------------------------------ Continuous ---

// CostMapping.Continuous: between crossings the applied value stands
// whatever the cost does.
pub fn applied_stands_between_crossings_test() -> Nil {
  assert map(cost: 500, draining: False, applied: 300) == Mapped(value: 300)
  assert map(cost: 899, draining: False, applied: 300) == Mapped(value: 300)
}

// --------------------------------------------------------------- Drained ---

// CostMapping.Drained: draining below the first threshold maps to -1, from
// whatever was applied.
pub fn draining_below_the_first_threshold_maps_to_drained_test() -> Nil {
  assert map(cost: 100, draining: True, applied: 300) == Mapped(value: -1)
  assert map(cost: 0, draining: True, applied: 0) == Mapped(value: -1)
  assert map(cost: 250, draining: True, applied: 839) == Mapped(value: -1)
}

// CostMapping.Drained: -1 is left on the reading that says so. Accepting
// again below the first threshold maps to 0, with no margin.
pub fn accepting_again_below_the_first_threshold_leaves_drained_test() -> Nil {
  assert map(cost: 100, draining: False, applied: -1) == Mapped(value: 0)
}

// CostMapping.Drained: at or above the first threshold the cost rules,
// draining or not.
pub fn draining_at_the_first_threshold_maps_to_the_cost_test() -> Nil {
  assert map(cost: 300, draining: True, applied: -1) == Mapped(value: 300)
  assert map(cost: 300, draining: True, applied: 0) == Mapped(value: 300)
}

// ----------------------------------------------------------------- Clamp ---

// CostMapping.Clamp: a cost above int32 is 2147483647, however far above.
pub fn cost_above_int32_is_clamped_test() -> Nil {
  assert cost_mapping.int32_max == 2_147_483_647
  assert map(cost: 2_147_483_648, draining: False, applied: 0)
    == Mapped(value: 2_147_483_647)
  assert map(cost: 9_999_999_999_999, draining: False, applied: 0)
    == Mapped(value: 2_147_483_647)
  assert map(cost: 2_147_483_647, draining: False, applied: 0)
    == Mapped(value: 2_147_483_647)
}

// ------------------------------------------------------------- Canonical ---

// CostMapping.Canonical: render gives the plain decimal digits, "-1" for
// drained, and no string for 0.
pub fn render_gives_the_canonical_string_or_none_test() -> Nil {
  assert cost_mapping.render(Mapped(value: 1)) == Some("1")
  assert cost_mapping.render(Mapped(value: 2_147_483_647)) == Some("2147483647")
  assert cost_mapping.render(Mapped(value: -1)) == Some("-1")
  assert cost_mapping.render(Mapped(value: 0)) == None
}

// CostMapping.Canonical: parse reads back what render wrote.
pub fn parse_round_trips_render_test() -> Nil {
  assert cost_mapping.parse("1") == Some(Mapped(value: 1))
  assert cost_mapping.parse("300") == Some(Mapped(value: 300))
  assert cost_mapping.parse("2147483647") == Some(Mapped(value: 2_147_483_647))
  assert cost_mapping.parse("-1") == Some(Mapped(value: -1))
}

// CostMapping.Canonical: parse refuses every non-canonical form. "0" is never
// written, so it is never read.
pub fn parse_refuses_non_canonical_text_test() -> Nil {
  assert cost_mapping.parse("0") == None
  assert cost_mapping.parse("+5") == None
  assert cost_mapping.parse("007") == None
  assert cost_mapping.parse("") == None
  assert cost_mapping.parse(" 1") == None
  assert cost_mapping.parse("1 ") == None
  assert cost_mapping.parse("2147483648") == None
  assert cost_mapping.parse("-2") == None
  assert cost_mapping.parse("-0") == None
  assert cost_mapping.parse("abc") == None
  assert cost_mapping.parse("1.0") == None
}

// ------------------------------------------------------------------ Pure ---

// CostMapping.Pure: the same arguments give the same results.
pub fn repeated_application_gives_the_same_result_test() -> Nil {
  assert tier(900) == 2
  assert tier(900) == 2
  assert map(cost: 839, draining: False, applied: 900) == Mapped(value: 839)
  assert map(cost: 839, draining: False, applied: 900) == Mapped(value: 839)
  assert cost_mapping.render(Mapped(value: 839)) == Some("839")
  assert cost_mapping.render(Mapped(value: 839)) == Some("839")
}

// A property in the gate takes a fixed seed (docs/reference/testing.md).
// CostMapping.Clamp and CostMapping.Canonical: for any cost in 0..5000, any
// applied in {0, -1} or 300..3600 and either drain state, map's result is
// -1, 0 or 1 to 2147483647, and render of it parses back to the same value.
pub fn every_mapped_value_is_in_range_and_round_trips_test() -> Nil {
  let config = qcheck.default_config() |> qcheck.with_seed(qcheck.seed(31))
  let applied =
    qcheck.from_generators(qcheck.return(0), [
      qcheck.return(-1),
      qcheck.bounded_int(from: 300, to: 3600),
    ])
  let readings =
    qcheck.tuple3(qcheck.bounded_int(from: 0, to: 5000), qcheck.bool(), applied)
  use #(cost, draining, applied) <- qcheck.run(config, readings)
  let mapped = map(cost:, draining:, applied:)
  let value = mapped.value

  assert value == -1 || value == 0 || { value >= 1 && value <= 2_147_483_647 }
  case cost_mapping.render(mapped) {
    None -> {
      assert value == 0
    }
    Some(text) -> {
      assert cost_mapping.parse(text) == Some(mapped)
    }
  }
}

// ----------------------------------------------------------- Obligations ---

// config-default.thresholds
pub fn config_default_thresholds_test() -> Nil {
  assert cost_mapping.thresholds == [300, 900, 1800, 3600]
}

// config-default.threshold_margin
pub fn config_default_threshold_margin_test() -> Nil {
  assert cost_mapping.threshold_margin == 60
}

// value-equality.Mapped and entity-fields.Mapped: one integer field,
// compared by value.
pub fn mapped_is_a_value_compared_by_value_test() -> Nil {
  let mapped = Mapped(value: 300)

  assert mapped.value == 300
  assert mapped == Mapped(value: 300)
  assert mapped != Mapped(value: 301)
}
// contract-signature.CostMapping.tier: (value, thresholds) -> Integer. The
// Tiers tests above discharge it.

// contract-signature.CostMapping.map: (cost, draining, applied, thresholds,
// margin) -> Mapped. The Crossing, Continuous, Drained and Clamp tests above
// discharge it.

// contract-signature.CostMapping.render: (mapped) -> String?. The Canonical
// tests above discharge it.
