//// Tests for the Catalogue, Events, Cadence and Logs contracts
//// (docs/specs/observability.allium). Every function is pure, so each test
//// passes values in and compares the result with a literal. Each test names
//// the clause or plan obligation it traces to.

import gleam/dynamic/decode
import gleam/json
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import knarr/observability.{
  type RejectedEvent, type Series, AbsentEvent, Apply, Cleanup, CleanupRejected,
  ContractAbsent, Debug, Entry, Field, ForeignAnnotation, Info, Invalid, Label,
  LogLine, NotFound, NotReadyWithCost, Refused, Rejected, RejectedEvent, Series,
  TimedOut, Unreachable, Valid, Warning, Yield,
}
import qcheck

const defaults = [300, 900, 1800, 3600]

const cost_key = "controller.kubernetes.io/pod-deletion-cost"

const evict_key = "cluster-autoscaler.kubernetes.io/safe-to-evict"

fn deployment_series(name: String, deployment: String) -> Series {
  Series(name:, labels: [Label(name: "deployment", value: deployment)])
}

// ----------------------------------------------------------------- Tiers ---

// Catalogue.Tiers: tier returns "drained" for -1.
pub fn tier_of_drained_is_drained_test() -> Nil {
  assert observability.tier(value: -1, thresholds: defaults) == "drained"
}

// Catalogue.Tiers: a pod knarr has not written is tier "0".
pub fn tier_of_zero_is_zero_test() -> Nil {
  assert observability.tier(value: 0, thresholds: defaults) == "0"
}

// Catalogue.Tiers: a value below the first threshold is tier "0".
pub fn tier_below_the_first_threshold_is_zero_test() -> Nil {
  assert observability.tier(value: 299, thresholds: defaults) == "0"
}

// Catalogue.Tiers: a value at the first threshold is tier "1".
pub fn tier_at_the_first_threshold_is_one_test() -> Nil {
  assert observability.tier(value: 300, thresholds: defaults) == "1"
}

// Catalogue.Tiers: a value at the last threshold is the length of the list.
pub fn tier_at_the_last_threshold_is_the_list_length_test() -> Nil {
  assert observability.tier(value: 3600, thresholds: defaults) == "4"
}

// Catalogue.Tiers: the tier is under the Deployment's own thresholds.
pub fn tier_uses_the_thresholds_given_test() -> Nil {
  assert observability.tier(value: 950, thresholds: [900]) == "1"
}

// --------------------------------------------------------------- Patches ---

// Catalogue.Patches: accepted for a 2xx.
pub fn patch_result_of_200_is_accepted_test() -> Nil {
  assert observability.patch_result(Some(200)) == "accepted"
}

// Catalogue.Patches: any 2xx is accepted.
pub fn patch_result_of_201_is_accepted_test() -> Nil {
  assert observability.patch_result(Some(201)) == "accepted"
}

// Catalogue.Patches: precondition_failed for 422.
pub fn patch_result_of_422_is_precondition_failed_test() -> Nil {
  assert observability.patch_result(Some(422)) == "precondition_failed"
}

// Catalogue.Patches: rejected for 400.
pub fn patch_result_of_400_is_rejected_test() -> Nil {
  assert observability.patch_result(Some(400)) == "rejected"
}

// Catalogue.Patches: rejected for 403.
pub fn patch_result_of_403_is_rejected_test() -> Nil {
  assert observability.patch_result(Some(403)) == "rejected"
}

// Catalogue.Patches: throttled for 429.
pub fn patch_result_of_429_is_throttled_test() -> Nil {
  assert observability.patch_result(Some(429)) == "throttled"
}

// Catalogue.Patches: error for every other status.
pub fn patch_result_of_500_is_error_test() -> Nil {
  assert observability.patch_result(Some(500)) == "error"
}

// Catalogue.Patches: error for null, a transport failure.
pub fn patch_result_of_a_transport_failure_is_error_test() -> Nil {
  assert observability.patch_result(None) == "error"
}

// ---------------------------------------------------------------- Budget ---

// Catalogue.Budget: succeeded for a 2xx.
pub fn list_result_of_200_is_succeeded_test() -> Nil {
  assert observability.list_result(Some(200)) == "succeeded"
}

// Catalogue.Budget: throttled for 429.
pub fn list_result_of_429_is_throttled_test() -> Nil {
  assert observability.list_result(Some(429)) == "throttled"
}

// Catalogue.Budget: a refused LIST is error, not rejected.
pub fn list_result_of_403_is_error_test() -> Nil {
  assert observability.list_result(Some(403)) == "error"
}

// Catalogue.Budget: error for every other status.
pub fn list_result_of_500_is_error_test() -> Nil {
  assert observability.list_result(Some(500)) == "error"
}

// Catalogue.Budget: error for null, a transport failure.
pub fn list_result_of_a_transport_failure_is_error_test() -> Nil {
  assert observability.list_result(None) == "error"
}

// ------------------------------------------------------------ SeriesLife ---

// Catalogue.SeriesLife: retire removes every series whose deployment label
// is the name, counters included, and keeps the rest in order.
pub fn retire_removes_every_series_of_the_deployment_test() -> Nil {
  let kept_pods = deployment_series(observability.pods, "emails")
  let kept_polls =
    Series(name: observability.polls_total, labels: [
      Label(name: "deployment", value: "emails"),
      Label(name: "reading", value: "valid"),
    ])
  let series = [
    deployment_series(observability.pods, "reports"),
    kept_pods,
    Series(name: observability.polls_total, labels: [
      Label(name: "reading", value: "valid"),
      Label(name: "deployment", value: "reports"),
    ]),
    kept_polls,
    deployment_series(observability.pods_unknown, "reports"),
  ]

  assert observability.retire(series, "reports") == [kept_pods, kept_polls]
}

// Catalogue.SeriesLife: a series without a deployment label is kept, and a
// label of another name whose value is the Deployment's name does not count.
pub fn retire_keeps_a_series_without_a_deployment_label_test() -> Nil {
  let depth = Series(name: "knarr_poll_queue_depth", labels: [])
  let targets =
    Series(name: observability.targets, labels: [
      Label(name: "kind", value: "reports"),
    ])
  let series = [
    deployment_series(observability.pods, "reports"),
    depth,
    targets,
  ]

  assert observability.retire(series, "reports") == [depth, targets]
}

// Catalogue.SeriesLife: a Deployment with no series leaves the list as it is.
pub fn retire_of_an_unknown_deployment_keeps_everything_test() -> Nil {
  let series = [deployment_series(observability.pods, "emails")]

  assert observability.retire(series, "reports") == series
}

// --------------------------------------------------------- Catalogue Pure ---

// Catalogue.Pure: the four functions give the same answer every time.
pub fn catalogue_functions_are_pure_test() -> Nil {
  let series = [deployment_series(observability.pods, "emails")]

  assert observability.tier(value: 300, thresholds: defaults)
    == observability.tier(value: 300, thresholds: defaults)
  assert observability.patch_result(Some(422))
    == observability.patch_result(Some(422))
  assert observability.list_result(Some(429))
    == observability.list_result(Some(429))
  assert observability.retire(series, "emails")
    == observability.retire(series, "emails")
}

// ---------------------------------------------------------------- Events ---

// Events.Rejected: PatchRejected for purpose apply.
pub fn reason_of_a_rejected_apply_is_patch_rejected_test() -> Nil {
  assert observability.reason(rejected(Apply)) == "PatchRejected"
}

// Events.Rejected: PatchRejected for purpose yield.
pub fn reason_of_a_rejected_yield_is_patch_rejected_test() -> Nil {
  assert observability.reason(rejected(Yield)) == "PatchRejected"
}

// Events.Rejected: CleanupRejected for purpose cleanup.
pub fn reason_of_a_rejected_cleanup_is_cleanup_rejected_test() -> Nil {
  assert observability.reason(rejected(Cleanup)) == "CleanupRejected"
}

// Events.Conventions: every reason is UpperCamelCase with no knarr prefix.
pub fn reasons_are_upper_camel_case_without_a_prefix_test() -> Nil {
  assert observability.annotation_yielded == "AnnotationYielded"
  assert observability.contract_absent == "ContractAbsent"
  assert observability.patch_rejected == "PatchRejected"
  assert observability.cleanup_rejected == "CleanupRejected"
  assert observability.invalid_override == "InvalidOverride"
}

fn rejected(purpose: observability.Purpose) -> RejectedEvent {
  RejectedEvent(
    pod_name: "emails-7d9f-abcde",
    pod_uid: "0f1e2d3c",
    purpose:,
    status: 422,
    keys: [cost_key, evict_key],
    left: [],
  )
}

// Events.Rejected: the PatchRejected message names the full keys joined by
// ", " and the status.
pub fn rejected_message_of_a_patch_names_the_keys_and_status_test() -> Nil {
  assert observability.rejected_message(rejected(Apply))
    == "controller.kubernetes.io/pod-deletion-cost, cluster-autoscaler.kubernetes.io/safe-to-evict: the apiserver rejected knarr's patch with 422; the previous annotations stay and knarr tries again no sooner than the patch interval"
}

// Events.Rejected: a yield renders the same message as an apply.
pub fn rejected_message_of_a_yield_is_a_patch_message_test() -> Nil {
  assert observability.rejected_message(
      RejectedEvent(..rejected(Yield), status: 403, keys: [cost_key]),
    )
    == "controller.kubernetes.io/pod-deletion-cost: the apiserver rejected knarr's patch with 403; the previous annotations stay and knarr tries again no sooner than the patch interval"
}

// Events.CleanupRejected: one annotation left "stays", with one removal.
pub fn rejected_message_of_a_cleanup_leaving_one_annotation_test() -> Nil {
  let event =
    RejectedEvent(..rejected(Cleanup), status: 403, keys: [cost_key], left: [
      #(cost_key, "1800"),
    ])

  assert observability.rejected_message(event)
    == "controller.kubernetes.io/pod-deletion-cost: the apiserver rejected knarr's cleanup with 403; controller.kubernetes.io/pod-deletion-cost=1800 stays on the pod until removed, for example kubectl annotate pod emails-7d9f-abcde controller.kubernetes.io/pod-deletion-cost-"
}

// Events.CleanupRejected: two annotations left "stay", the pairs joined by
// ", " and the removals by " ".
pub fn rejected_message_of_a_cleanup_leaving_two_annotations_test() -> Nil {
  let event =
    RejectedEvent(..rejected(Cleanup), left: [
      #(cost_key, "1800"),
      #(evict_key, "false"),
    ])

  assert observability.rejected_message(event)
    == "controller.kubernetes.io/pod-deletion-cost, cluster-autoscaler.kubernetes.io/safe-to-evict: the apiserver rejected knarr's cleanup with 422; controller.kubernetes.io/pod-deletion-cost=1800, cluster-autoscaler.kubernetes.io/safe-to-evict=false stay on the pod until removed, for example kubectl annotate pod emails-7d9f-abcde controller.kubernetes.io/pod-deletion-cost- cluster-autoscaler.kubernetes.io/safe-to-evict-"
}

const absent =
  AbsentEvent(
    deployment_name: "emails",
    deployment_uid: "9a8b7c6d",
    pod_name: "emails-7d9f-abcde",
    port: 8080,
    path: "/knarr/v1/status",
    reading: NotFound,
  )

// Events.ContractAbsent: the message names the pod, port, path and the last
// reading's literal.
pub fn absent_message_names_the_pod_port_path_and_reading_test() -> Nil {
  assert observability.absent_message(absent)
    == "pod emails-7d9f-abcde: no knarr status contract at port 8080 path /knarr/v1/status; last reading not_found"
}

// Events.ContractAbsent: the reading literal is ReadingKind's, with an
// underscore.
pub fn absent_message_carries_a_timed_out_reading_test() -> Nil {
  assert observability.absent_message(
      AbsentEvent(..absent, port: 9000, path: "/internal", reading: TimedOut),
    )
    == "pod emails-7d9f-abcde: no knarr status contract at port 9000 path /internal; last reading timed_out"
}

// Events.Pure: reason and both messages give the same answer every time.
pub fn event_functions_are_pure_test() -> Nil {
  assert observability.reason(rejected(Cleanup))
    == observability.reason(rejected(Cleanup))
  assert observability.rejected_message(rejected(Apply))
    == observability.rejected_message(rejected(Apply))
  assert observability.absent_message(absent)
    == observability.absent_message(absent)
}

// --------------------------------------------------------------- Cadence ---

const foreign_cost =
  Entry(
    pod_name: "emails-7d9f-abcde",
    annotation: Some("pod-deletion-cost"),
    state: ForeignAnnotation,
  )

const absent_entry =
  Entry(pod_name: "emails-7d9f-abcde", annotation: None, state: ContractAbsent)

const not_ready =
  Entry(
    pod_name: "emails-7d9f-fghij",
    annotation: None,
    state: NotReadyWithCost,
  )

// Cadence.OnEntry: an entry seen does not hold is announced.
pub fn entered_announces_a_new_entry_test() -> Nil {
  assert observability.entered(seen: [not_ready], current: [
      not_ready,
      absent_entry,
    ])
    == [absent_entry]
}

// Cadence.OnEntry: a state that stays is not announced again.
pub fn entered_is_silent_while_a_state_stays_test() -> Nil {
  assert observability.entered(seen: [absent_entry], current: [absent_entry])
    == []
}

// Cadence.OnEntry: a state re-entered after leaving is announced again.
pub fn entered_announces_a_re_entry_test() -> Nil {
  let after_leaving =
    observability.entered(seen: [absent_entry], current: [not_ready])
  assert after_leaving == [not_ready]

  assert observability.entered(seen: [not_ready], current: [absent_entry])
    == [absent_entry]
}

// Cadence.OnEntry: the announced entries keep current's order.
pub fn entered_keeps_the_order_of_current_test() -> Nil {
  assert observability.entered(seen: [], current: [
      not_ready,
      absent_entry,
      foreign_cost,
    ])
    == [not_ready, absent_entry, foreign_cost]
}

// Cadence.Restart: seen is empty after a restart, so every current state is
// announced once more.
pub fn entered_announces_every_state_after_a_restart_test() -> Nil {
  assert observability.entered(seen: [], current: [absent_entry, not_ready])
    == [absent_entry, not_ready]
}

// Cadence.OnEntry: foreign is per owned annotation, so the same pod's other
// annotation turning foreign is a new entry.
pub fn entered_announces_foreign_per_annotation_test() -> Nil {
  let foreign_evict = Entry(..foreign_cost, annotation: Some("safe-to-evict"))

  assert observability.entered(seen: [foreign_cost], current: [
      foreign_cost,
      foreign_evict,
    ])
    == [foreign_evict]
}

// Cadence.OnEntry: a pod in two states at once is two entries.
pub fn entered_tells_the_states_of_one_pod_apart_test() -> Nil {
  let rejected_entry = Entry(..absent_entry, state: Rejected)
  let cleanup_entry = Entry(..absent_entry, state: CleanupRejected)

  assert observability.entered(seen: [rejected_entry], current: [
      rejected_entry,
      cleanup_entry,
    ])
    == [cleanup_entry]
}

// Cadence.Pure: entered gives the same answer every time.
pub fn entered_is_pure_test() -> Nil {
  assert observability.entered(seen: [not_ready], current: [absent_entry])
    == observability.entered(seen: [not_ready], current: [absent_entry])
}

// ------------------------------------------------------------------ Logs ---

// Logs.Format: time, level and msg in that order, then each field in order,
// no whitespace, and a newline.
pub fn render_writes_time_level_msg_then_the_fields_test() -> Nil {
  let line =
    LogLine(time: 1_760_000_000_123, level: Info, msg: "discovery", fields: [
      observability.int_field("deployments", 3),
      observability.int_field("pods", 12),
    ])

  assert observability.render(line)
    == "{\"time\":\"2025-10-09T08:53:20.123Z\",\"level\":\"info\",\"msg\":\"discovery\",\"deployments\":3,\"pods\":12}\n"
}

// Logs.Format: a line with no fields is the three members alone.
pub fn render_of_no_fields_has_the_three_members_test() -> Nil {
  let line = LogLine(time: 0, level: observability.Error, msg: "x", fields: [])

  assert observability.render(line)
    == "{\"time\":\"1970-01-01T00:00:00.000Z\",\"level\":\"error\",\"msg\":\"x\"}\n"
}

// Logs.Format: the time is RFC 3339 UTC with milliseconds.
pub fn render_writes_the_epoch_plus_one_second_test() -> Nil {
  assert observability.render(
      LogLine(time: 1000, level: Debug, msg: "poll", fields: []),
    )
    == "{\"time\":\"1970-01-01T00:00:01.000Z\",\"level\":\"debug\",\"msg\":\"poll\"}\n"
}

// Logs.Format: a midnight in 2026.
pub fn render_writes_a_midnight_in_2026_test() -> Nil {
  assert observability.render(
      LogLine(time: 1_771_200_000_000, level: Warning, msg: "x", fields: []),
    )
    == "{\"time\":\"2026-02-16T00:00:00.000Z\",\"level\":\"warning\",\"msg\":\"x\"}\n"
}

// Logs.Format: the leap day of 2024.
pub fn render_writes_a_leap_day_test() -> Nil {
  assert observability.render(
      LogLine(time: 1_709_164_800_000, level: Info, msg: "x", fields: []),
    )
    == "{\"time\":\"2024-02-29T00:00:00.000Z\",\"level\":\"info\",\"msg\":\"x\"}\n"
}

// Logs.Format: 2100 is not a leap year, so the day after 2100-02-28 is
// 2100-03-01.
pub fn render_writes_the_day_after_the_2100_non_leap_february_test() -> Nil {
  assert observability.render(
      LogLine(time: 4_107_542_400_000, level: Info, msg: "x", fields: []),
    )
    == "{\"time\":\"2100-03-01T00:00:00.000Z\",\"level\":\"info\",\"msg\":\"x\"}\n"
}

// Logs.Format: the msg and a string field are escaped as JSON strings.
pub fn render_escapes_the_msg_and_a_string_field_test() -> Nil {
  let line =
    LogLine(time: 0, level: Info, msg: "a\"b\\c\nd", fields: [
      observability.string_field("reason", "a\"b\\c\nd"),
    ])

  assert observability.render(line)
    == "{\"time\":\"1970-01-01T00:00:00.000Z\",\"level\":\"info\",\"msg\":\"a\\\"b\\\\c\\nd\",\"reason\":\"a\\\"b\\\\c\\nd\"}\n"
}

// Logs.Format: an int, a bool and an array field render as JSON values, in
// the order given.
pub fn render_writes_int_bool_and_array_fields_in_order_test() -> Nil {
  let line =
    LogLine(time: 0, level: Debug, msg: "patch", fields: [
      observability.string_field("pod", "emails-7d9f-abcde"),
      observability.bool_field("accepting", True),
      observability.strings_field("keys", [cost_key, evict_key]),
      observability.int_field("status", 200),
      observability.bool_field("applied", False),
    ])

  assert observability.render(line)
    == "{\"time\":\"1970-01-01T00:00:00.000Z\",\"level\":\"debug\",\"msg\":\"patch\",\"pod\":\"emails-7d9f-abcde\",\"accepting\":true,\"keys\":[\"controller.kubernetes.io/pod-deletion-cost\",\"cluster-autoscaler.kubernetes.io/safe-to-evict\"],\"status\":200,\"applied\":false}\n"
}

// Logs.Format: a field is a name and the JSON text of its value.
pub fn fields_hold_json_value_text_test() -> Nil {
  assert observability.string_field("pod", "p\"q")
    == Field(name: "pod", value: "\"p\\\"q\"")
  assert observability.int_field("cost", -1) == Field(name: "cost", value: "-1")
  assert observability.bool_field("accepting", True)
    == Field(name: "accepting", value: "true")
  assert observability.bool_field("accepting", False)
    == Field(name: "accepting", value: "false")
  assert observability.strings_field("keys", ["a", "b\"c"])
    == Field(name: "keys", value: "[\"a\",\"b\\\"c\"]")
  assert observability.strings_field("keys", [])
    == Field(name: "keys", value: "[]")
}

// Logs.Levels: enabled is true when level is threshold or more severe, for
// every pair of the four levels.
pub fn enabled_for_every_pair_of_levels_test() -> Nil {
  let error = observability.Error

  assert observability.enabled(level: Debug, threshold: Debug)
  assert observability.enabled(level: Info, threshold: Debug)
  assert observability.enabled(level: Warning, threshold: Debug)
  assert observability.enabled(level: error, threshold: Debug)

  assert !observability.enabled(level: Debug, threshold: Info)
  assert observability.enabled(level: Info, threshold: Info)
  assert observability.enabled(level: Warning, threshold: Info)
  assert observability.enabled(level: error, threshold: Info)

  assert !observability.enabled(level: Debug, threshold: Warning)
  assert !observability.enabled(level: Info, threshold: Warning)
  assert observability.enabled(level: Warning, threshold: Warning)
  assert observability.enabled(level: error, threshold: Warning)

  assert !observability.enabled(level: Debug, threshold: error)
  assert !observability.enabled(level: Info, threshold: error)
  assert !observability.enabled(level: Warning, threshold: error)
  assert observability.enabled(level: error, threshold: error)
}

// A property in the gate takes a fixed seed (docs/reference/testing.md).
// Logs.Levels: enabled is monotone in severity: raising the level never
// disables a line and raising the threshold never enables one.
pub fn enabled_is_monotone_in_severity_test() -> Nil {
  let config = qcheck.default_config() |> qcheck.with_seed(qcheck.seed(31))
  let level = fn(rank: Int) {
    case rank {
      0 -> Debug
      1 -> Info
      2 -> Warning
      _ -> observability.Error
    }
  }
  let ranks = qcheck.bounded_int(0, 3)
  let pairs = qcheck.tuple3(ranks, ranks, ranks)
  use #(low, high, threshold) <- qcheck.run(config, pairs)
  let #(low, high) = case low <= high {
    True -> #(low, high)
    False -> #(high, low)
  }

  // A line at the lower level enabled means the higher level is enabled too.
  assert !observability.enabled(level: level(low), threshold: level(threshold))
    || observability.enabled(level: level(high), threshold: level(threshold))
  // Enabled under the higher threshold means enabled under the lower one.
  assert !observability.enabled(level: level(threshold), threshold: level(high))
    || observability.enabled(level: level(threshold), threshold: level(low))
}

// Logs.Pure: render and enabled give the same answer every time; the time
// is passed in.
pub fn log_functions_are_pure_test() -> Nil {
  let line = LogLine(time: 1000, level: Info, msg: "started", fields: [])

  assert observability.render(line) == observability.render(line)
  assert observability.enabled(level: Info, threshold: Warning)
    == observability.enabled(level: Info, threshold: Warning)
}

// ---------------------------------------------------------------- Labels ---

// Catalogue.Polls: reading is worker_contract's Reading kind verbatim.
pub fn reading_labels_are_the_enum_literals_test() -> Nil {
  assert observability.reading_label(Valid) == "valid"
  assert observability.reading_label(NotFound) == "not_found"
  assert observability.reading_label(Invalid) == "invalid"
  assert observability.reading_label(Refused) == "refused"
  assert observability.reading_label(TimedOut) == "timed_out"
  assert observability.reading_label(Unreachable) == "unreachable"
}

// Catalogue.Patches: purpose is Purpose's literal.
pub fn purpose_labels_are_the_enum_literals_test() -> Nil {
  assert observability.purpose_label(Apply) == "apply"
  assert observability.purpose_label(Yield) == "yield"
  assert observability.purpose_label(Cleanup) == "cleanup"
}

// Logs.Format: level is Level's literal.
pub fn level_labels_are_the_enum_literals_test() -> Nil {
  assert observability.level_label(Debug) == "debug"
  assert observability.level_label(Info) == "info"
  assert observability.level_label(Warning) == "warning"
  assert observability.level_label(observability.Error) == "error"
}

// Logs.Levels: the threshold is set by configuration text, so parse_level
// reads each literal back and nothing else.
pub fn parse_level_reads_each_literal_and_nothing_else_test() -> Nil {
  assert observability.parse_level("debug") == Some(Debug)
  assert observability.parse_level("info") == Some(Info)
  assert observability.parse_level("warning") == Some(Warning)
  assert observability.parse_level("error") == Some(observability.Error)
  assert observability.parse_level("verbose") == None
  assert observability.parse_level("Info") == None
  assert observability.parse_level("") == None
}

// Logs.Levels: parse_level is the inverse of level_label.
pub fn parse_level_inverts_level_label_test() -> Nil {
  assert [
      observability.parse_level(observability.level_label(Debug)),
      observability.parse_level(observability.level_label(Info)),
      observability.parse_level(observability.level_label(Warning)),
      observability.parse_level(observability.level_label(observability.Error)),
    ]
    == [Some(Debug), Some(Info), Some(Warning), Some(observability.Error)]
}

// --------------------------------------------------------------- Buckets ---

// Catalogue.Buckets: the fixed bucket bounds, not derived from config.
pub fn buckets_are_the_fixed_bounds_test() -> Nil {
  assert observability.buckets
    == [0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0, 30.0, 60.0]
}

// Catalogue.Naming: every metric name is knarr_<subject>_<unit>.
pub fn metric_names_follow_the_naming_convention_test() -> Nil {
  assert observability.polls_total == "knarr_polls_total"
  assert observability.pods == "knarr_pods"
  assert observability.annotations == "knarr_annotations"
  assert observability.pods_not_ready_with_cost
    == "knarr_pods_not_ready_with_cost"
  assert observability.pods_unknown == "knarr_pods_unknown"
  assert observability.pods_contract_absent == "knarr_pods_contract_absent"
  assert observability.yields_total == "knarr_yields_total"
  assert observability.last_discovery_timestamp_seconds
    == "knarr_last_discovery_timestamp_seconds"
  assert observability.discovery_duration_seconds
    == "knarr_discovery_duration_seconds"
  assert observability.events_total == "knarr_events_total"
  assert observability.targets == "knarr_targets"
  assert observability.build_info == "knarr_build_info"
}

// ----------------------------------------------------------- Obligations ---

// config-default.log_level
pub fn config_default_log_level_test() -> Nil {
  assert observability.default_log_level == Info
}

// value-equality.Label and entity-fields.Label: a name and a value, compared
// by value.
pub fn label_is_a_name_and_a_value_test() -> Nil {
  let label = Label(name: "deployment", value: "emails")

  assert label.name == "deployment"
  assert label.value == "emails"
  assert label == Label(name: "deployment", value: "emails")
  assert label != Label(..label, value: "reports")
}

// value-equality.Series and entity-fields.Series: a name and labels,
// compared by value.
pub fn series_is_a_name_and_labels_test() -> Nil {
  let series = deployment_series(observability.pods, "emails")

  assert series.name == "knarr_pods"
  assert series.labels == [Label(name: "deployment", value: "emails")]
  assert series == deployment_series("knarr_pods", "emails")
  assert series != Series(..series, labels: [])
}

// value-equality.Annotation and entity-fields.Annotation: the key and value
// pair RejectedEvent.left holds, compared by value.
pub fn annotation_is_a_key_and_a_value_test() -> Nil {
  let annotation: #(String, String) = #(cost_key, "1800")

  assert annotation.0 == "controller.kubernetes.io/pod-deletion-cost"
  assert annotation.1 == "1800"
  assert annotation == #("controller.kubernetes.io/pod-deletion-cost", "1800")
  assert annotation != #(cost_key, "900")
}

// value-equality.AbsentEvent and entity-fields.AbsentEvent.
pub fn absent_event_has_six_fields_and_compares_by_value_test() -> Nil {
  assert absent.deployment_name == "emails"
  assert absent.deployment_uid == "9a8b7c6d"
  assert absent.pod_name == "emails-7d9f-abcde"
  assert absent.port == 8080
  assert absent.path == "/knarr/v1/status"
  assert absent.reading == NotFound
  assert absent
    == AbsentEvent(
      deployment_name: "emails",
      deployment_uid: "9a8b7c6d",
      pod_name: "emails-7d9f-abcde",
      port: 8080,
      path: "/knarr/v1/status",
      reading: NotFound,
    )
  assert absent != AbsentEvent(..absent, reading: Refused)
}

// value-equality.RejectedEvent and entity-fields.RejectedEvent.
pub fn rejected_event_has_six_fields_and_compares_by_value_test() -> Nil {
  let event = RejectedEvent(..rejected(Cleanup), left: [#(cost_key, "1800")])

  assert event.pod_name == "emails-7d9f-abcde"
  assert event.pod_uid == "0f1e2d3c"
  assert event.purpose == Cleanup
  assert event.status == 422
  assert event.keys
    == [
      "controller.kubernetes.io/pod-deletion-cost",
      "cluster-autoscaler.kubernetes.io/safe-to-evict",
    ]
  assert event.left == [#("controller.kubernetes.io/pod-deletion-cost", "1800")]
  assert event
    == RejectedEvent(
      pod_name: "emails-7d9f-abcde",
      pod_uid: "0f1e2d3c",
      purpose: Cleanup,
      status: 422,
      keys: [cost_key, evict_key],
      left: [#(cost_key, "1800")],
    )
  assert event != RejectedEvent(..event, status: 403)
}

// value-equality.Entry and entity-fields.Entry: the pod, the annotation for
// foreign and null otherwise, and the state.
pub fn entry_is_a_pod_an_optional_annotation_and_a_state_test() -> Nil {
  assert foreign_cost.pod_name == "emails-7d9f-abcde"
  assert foreign_cost.annotation == Some("pod-deletion-cost")
  assert foreign_cost.state == ForeignAnnotation
  assert absent_entry.annotation == None
  assert foreign_cost
    == Entry(
      pod_name: "emails-7d9f-abcde",
      annotation: Some("pod-deletion-cost"),
      state: ForeignAnnotation,
    )
  assert foreign_cost
    != Entry(..foreign_cost, annotation: Some("safe-to-evict"))
  assert foreign_cost != Entry(..foreign_cost, state: Rejected)
}

// value-equality.Field and entity-fields.Field: a name and the JSON text of
// the value, compared by value.
pub fn field_is_a_name_and_json_text_test() -> Nil {
  let field = Field(name: "status", value: "200")

  assert field.name == "status"
  assert field.value == "200"
  assert field == Field(name: "status", value: "200")
  assert field != Field(..field, value: "\"200\"")
}

// value-equality.LogLine and entity-fields.LogLine: time, level, msg and
// fields, compared by value.
pub fn log_line_has_four_fields_and_compares_by_value_test() -> Nil {
  let line =
    LogLine(time: 1000, level: Warning, msg: "contract absent", fields: [
      Field(name: "pod", value: "\"p\""),
    ])

  assert line.time == 1000
  assert line.level == Warning
  assert line.msg == "contract absent"
  assert line.fields == [Field(name: "pod", value: "\"p\"")]
  assert line
    == LogLine(time: 1000, level: Warning, msg: "contract absent", fields: [
      Field(name: "pod", value: "\"p\""),
    ])
  assert line != LogLine(..line, level: Info)
}

// enum-comparable.ReadingKind: the kinds compare as values, read back from
// a field.
pub fn reading_kinds_are_comparable_test() -> Nil {
  let reading = fn(kind) { AbsentEvent(..absent, reading: kind).reading }

  assert reading(Valid) == Valid
  assert reading(NotFound) == NotFound
  assert reading(NotFound) != Invalid
  assert reading(Refused) != TimedOut
  assert reading(TimedOut) != Unreachable
}

// enum-comparable.Purpose: the purposes compare as values, read back from a
// field.
pub fn purposes_are_comparable_test() -> Nil {
  let purpose = fn(purpose) { rejected(purpose).purpose }

  assert purpose(Apply) == Apply
  assert purpose(Yield) == Yield
  assert purpose(Apply) != Yield
  assert purpose(Yield) != Cleanup
}

// enum-comparable.Level: the levels compare as values, read back from a
// field.
pub fn levels_are_comparable_test() -> Nil {
  let level = fn(level) { LogLine(time: 0, level:, msg: "", fields: []).level }

  assert level(Debug) == Debug
  assert level(Warning) == Warning
  assert level(Debug) != Info
  assert level(Warning) != observability.Error
}

@external(erlang, "observability_test_ffi", "line_of_string")
fn line_of_string(text: String) -> String

@external(erlang, "observability_test_ffi", "line_of_integer_msg")
fn line_of_integer_msg() -> String

@external(erlang, "observability_test_ffi", "line_of_long_report")
fn line_of_long_report() -> String

// Logs.Format and NeverLogged, for the formatter adapter: whatever OTP hands
// it, the line is one JSON object and a newline. A string cut at 400 inside
// a two-byte character is cut by character, a msg that is not text renders
// as a fixed line, and a labelled report's picture is bounded.
pub fn the_formatter_always_emits_one_json_object_test() -> Nil {
  let object = decode.dict(decode.string, decode.dynamic)
  let is_object = fn(line) {
    string.ends_with(line, "\n") && result.is_ok(json.parse(line, object))
  }
  let split = line_of_string("a" <> string.repeat("\u{e9}", 500))

  assert is_object(split)
  assert string.contains(split, "...")
  assert is_object(line_of_integer_msg())
  assert is_object(line_of_long_report())
  assert string.contains(line_of_long_report(), "\"report\":")
}
// contract-signature.Catalogue.tier: (value, thresholds) -> String, the
// Tiers tests above.
// contract-signature.Catalogue.patch_result: (status?) -> String, the
// Patches tests above.
// contract-signature.Catalogue.list_result: (status?) -> String, the Budget
// tests above.
// contract-signature.Catalogue.retire: (series, deployment) -> List<Series>,
// the SeriesLife tests above.
// contract-signature.Events.reason: (event) -> String, the reason tests
// above.
// contract-signature.Events.rejected_message: (event) -> String, the
// rejected_message tests above.
// contract-signature.Events.absent_message: (event) -> String, the
// absent_message tests above.
// contract-signature.Cadence.entered: (seen, current) -> List<Entry>, the
// Cadence tests above.
// contract-signature.Logs.render: (line) -> String, the render tests above.
// contract-signature.Logs.enabled: (level, threshold) -> Boolean, the
// enabled tests above.
