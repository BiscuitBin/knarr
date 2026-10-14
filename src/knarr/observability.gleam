//// The observability contracts (docs/specs/observability.allium): the
//// catalogue's label functions and series retirement, the Event reasons and
//// messages, the on-entry cadence, and the JSON log line. Every function is
//// pure; keeping the counts is `metrics`'s and writing a line is OTP
//// logger's, through `observability_ffi`.

import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import knarr/cost_mapping

/// One label of a series.
pub type Label {
  Label(name: String, value: String)
}

/// One exported series: the metric's name and its labels.
pub type Series {
  Series(name: String, labels: List(Label))
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

/// What a patch was for.
pub type Purpose {
  Apply
  Yield
  Cleanup
}

/// Log levels, least to most severe.
pub type Level {
  Debug
  Info
  Warning
  Error
}

/// config.log_level.
pub const default_log_level = Info

/// The content of the ContractAbsent Event, on the pod's Deployment.
pub type AbsentEvent {
  AbsentEvent(
    deployment_name: String,
    deployment_uid: String,
    pod_name: String,
    port: Int,
    path: String,
    reading: ReadingKind,
  )
}

/// The content of the Event raised on the first rejection of a run, on the
/// Pod. `left` holds the owned annotations a rejected cleanup leaves, as
/// key and value pairs; empty for any other purpose.
pub type RejectedEvent {
  RejectedEvent(
    pod_name: String,
    pod_uid: String,
    purpose: Purpose,
    status: Int,
    keys: List(String),
    left: List(#(String, String)),
  )
}

/// A state that is announced on entry.
pub type State {
  ForeignAnnotation
  NotReadyWithCost
  ContractAbsent
  Rejected
  CleanupRejected
}

/// One pod's place in a state that is announced on entry: the owned
/// annotation's short name for `ForeignAnnotation`, `None` otherwise.
pub type Entry {
  Entry(pod_name: String, annotation: Option(String), state: State)
}

/// One field of a log line: its name and the JSON text of its value.
pub type Field {
  Field(name: String, value: String)
}

/// One log line before it is rendered. `time` is unix milliseconds.
pub type LogLine {
  LogLine(time: Int, level: Level, msg: String, fields: List(Field))
}

/// Event reasons (Events).
pub const annotation_yielded = "AnnotationYielded"

pub const contract_absent = "ContractAbsent"

pub const patch_rejected = "PatchRejected"

pub const cleanup_rejected = "CleanupRejected"

pub const invalid_override = "InvalidOverride"

/// The fixed histogram bucket bounds, in seconds (Buckets).
pub const buckets: List(Float) = [
  0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0, 30.0, 60.0,
]

/// Metric names (Catalogue).
pub const polls_total = "knarr_polls_total"

pub const pods = "knarr_pods"

pub const annotations = "knarr_annotations"

pub const pods_not_ready_with_cost = "knarr_pods_not_ready_with_cost"

pub const pods_unknown = "knarr_pods_unknown"

pub const pods_contract_absent = "knarr_pods_contract_absent"

pub const yields_total = "knarr_yields_total"

pub const last_discovery_timestamp_seconds =
  "knarr_last_discovery_timestamp_seconds"

pub const discovery_duration_seconds = "knarr_discovery_duration_seconds"

pub const events_total = "knarr_events_total"

pub const targets = "knarr_targets"

pub const build_info = "knarr_build_info"

/// The tier label of an applied pod-deletion-cost value: "drained" for -1,
/// else cost_mapping's tier under `thresholds` in decimal, so "0" for a pod
/// knarr has not written (Tiers).
pub fn tier(value value: Int, thresholds thresholds: List(Int)) -> String {
  case value {
    -1 -> "drained"
    _ -> int.to_string(cost_mapping.tier(value:, thresholds:))
  }
}

/// The result label of a patch response: accepted, precondition_failed,
/// rejected, throttled or error; `None` is a transport failure (Patches).
pub fn patch_result(status: Option(Int)) -> String {
  case status {
    Some(status) if status >= 200 && status < 300 -> "accepted"
    Some(422) -> "precondition_failed"
    Some(400) | Some(403) -> "rejected"
    Some(429) -> "throttled"
    Some(_) | None -> "error"
  }
}

/// The result label of a LIST response: succeeded, throttled or error
/// (Budget).
pub fn list_result(status: Option(Int)) -> String {
  case status {
    Some(status) if status >= 200 && status < 300 -> "succeeded"
    Some(429) -> "throttled"
    Some(_) | None -> "error"
  }
}

/// The series given less every one whose `deployment` label is `deployment`
/// (SeriesLife).
pub fn retire(
  series series: List(Series),
  deployment deployment: String,
) -> List(Series) {
  let of_deployment = Label(name: "deployment", value: deployment)
  list.filter(series, fn(one) { !list.contains(one.labels, of_deployment) })
}

/// PatchRejected for apply and yield, CleanupRejected for cleanup
/// (Events Rejected).
pub fn reason(event: RejectedEvent) -> String {
  case event.purpose {
    Apply | Yield -> patch_rejected
    Cleanup -> cleanup_rejected
  }
}

/// The message of a PatchRejected or CleanupRejected Event (Events Rejected
/// and CleanupRejected).
pub fn rejected_message(event: RejectedEvent) -> String {
  let keys = string.join(event.keys, ", ")
  let status = int.to_string(event.status)
  case event.purpose {
    Apply | Yield ->
      keys
      <> ": the apiserver rejected knarr's patch with "
      <> status
      <> "; the previous annotations stay and knarr tries again no sooner than the patch interval"
    Cleanup -> {
      let pairs =
        event.left
        |> list.map(fn(pair) { pair.0 <> "=" <> pair.1 })
        |> string.join(", ")
      let removals =
        event.left
        |> list.map(fn(pair) { pair.0 <> "-" })
        |> string.join(" ")
      let stays = case event.left {
        [_] -> " stays"
        _ -> " stay"
      }
      keys
      <> ": the apiserver rejected knarr's cleanup with "
      <> status
      <> "; "
      <> pairs
      <> stays
      <> " on the pod until removed, for example kubectl annotate pod "
      <> event.pod_name
      <> " "
      <> removals
    }
  }
}

/// "pod <pod>: no knarr status contract at port <port> path <path>; last
/// reading <reading>" (Events ContractAbsent).
pub fn absent_message(event: AbsentEvent) -> String {
  "pod "
  <> event.pod_name
  <> ": no knarr status contract at port "
  <> int.to_string(event.port)
  <> " path "
  <> event.path
  <> "; last reading "
  <> reading_label(event.reading)
}

/// Every entry of `current` that `seen` does not hold, in the order of
/// `current` (Cadence OnEntry).
pub fn entered(
  seen seen: List(Entry),
  current current: List(Entry),
) -> List(Entry) {
  list.filter(current, fn(entry) { !list.contains(seen, entry) })
}

/// One JSON object and a newline: time as RFC 3339 UTC with milliseconds,
/// level, msg, then each field in order, no whitespace (Logs Format).
pub fn render(line: LogLine) -> String {
  let members = [
    string_field(name: "time", value: rfc3339(line.time)),
    string_field(name: "level", value: level_label(line.level)),
    string_field(name: "msg", value: line.msg),
    ..line.fields
  ]
  let body =
    members
    |> list.map(fn(field) { quote(field.name) <> ":" <> field.value })
    |> string.join(",")
  "{" <> body <> "}\n"
}

/// True when `level` is `threshold` or more severe (Logs Levels).
pub fn enabled(level level: Level, threshold threshold: Level) -> Bool {
  severity(level) >= severity(threshold)
}

/// The enum literal of a reading kind, as the `reading` label and field
/// carry it: "valid", "not_found", "invalid", "refused", "timed_out",
/// "unreachable".
pub fn reading_label(kind: ReadingKind) -> String {
  case kind {
    Valid -> "valid"
    NotFound -> "not_found"
    Invalid -> "invalid"
    Refused -> "refused"
    TimedOut -> "timed_out"
    Unreachable -> "unreachable"
  }
}

/// The enum literal of a purpose: "apply", "yield", "cleanup".
pub fn purpose_label(purpose: Purpose) -> String {
  case purpose {
    Apply -> "apply"
    Yield -> "yield"
    Cleanup -> "cleanup"
  }
}

/// The enum literal of a level: "debug", "info", "warning", "error".
pub fn level_label(level: Level) -> String {
  case level {
    Debug -> "debug"
    Info -> "info"
    Warning -> "warning"
    Error -> "error"
  }
}

/// The inverse of `level_label`; `None` for any other text.
pub fn parse_level(text: String) -> Option(Level) {
  case text {
    "debug" -> Some(Debug)
    "info" -> Some(Info)
    "warning" -> Some(Warning)
    "error" -> Some(Error)
    _ -> None
  }
}

/// A field holding a JSON string, quoted and escaped.
pub fn string_field(name name: String, value value: String) -> Field {
  Field(name:, value: quote(value))
}

/// A field holding a JSON integer.
pub fn int_field(name name: String, value value: Int) -> Field {
  Field(name:, value: int.to_string(value))
}

/// A field holding a JSON boolean.
pub fn bool_field(name name: String, value value: Bool) -> Field {
  Field(name:, value: case value {
    True -> "true"
    False -> "false"
  })
}

/// A field holding a JSON array of strings.
pub fn strings_field(name name: String, values values: List(String)) -> Field {
  Field(name:, value: json.to_string(json.array(values, json.string)))
}

/// The JSON text of a string: quoted and escaped.
fn quote(text: String) -> String {
  json.to_string(json.string(text))
}

/// The place of a level in Level's order, least to most severe.
fn severity(level: Level) -> Int {
  case level {
    Debug -> 0
    Info -> 1
    Warning -> 2
    Error -> 3
  }
}

const millis_per_second = 1000

const millis_per_day = 86_400_000

/// Unix milliseconds as RFC 3339 UTC with milliseconds,
/// `YYYY-MM-DDTHH:MM:SS.mmmZ` (Logs Format). The civil date is computed from
/// days since the epoch; the time is not read here (Logs Pure).
fn rfc3339(millis: Int) -> String {
  let days = millis / millis_per_day
  let of_day = millis % millis_per_day
  let #(year, month, day) = civil_from_days(days)
  let seconds = of_day / millis_per_second
  let fraction = of_day % millis_per_second
  int.to_string(year)
  <> "-"
  <> two(month)
  <> "-"
  <> two(day)
  <> "T"
  <> two(seconds / 3600)
  <> ":"
  <> two(seconds % 3600 / 60)
  <> ":"
  <> two(seconds % 60)
  <> "."
  <> string.pad_start(int.to_string(fraction), 3, "0")
  <> "Z"
}

fn two(value: Int) -> String {
  string.pad_start(int.to_string(value), 2, "0")
}

/// The proleptic Gregorian year, month and day of a count of days since
/// 1970-01-01, by Howard Hinnant's civil_from_days: the calendar is shifted
/// to start on 1 March so a leap day falls last, and counted in 400-year
/// eras of 146097 days.
fn civil_from_days(days: Int) -> #(Int, Int, Int) {
  let shifted = days + 719_468
  let era = shifted / 146_097
  let day_of_era = shifted - era * 146_097
  let year_of_era =
    {
      day_of_era
      - day_of_era
      / 1460
      + day_of_era
      / 36_524
      - day_of_era
      / 146_096
    }
    / 365
  let day_of_year =
    day_of_era - { 365 * year_of_era + year_of_era / 4 - year_of_era / 100 }
  let shifted_month = { 5 * day_of_year + 2 } / 153
  let day = day_of_year - { 153 * shifted_month + 2 } / 5 + 1
  let month = case shifted_month < 10 {
    True -> shifted_month + 3
    False -> shifted_month - 9
  }
  let year = year_of_era + era * 400
  let year = case month <= 2 {
    True -> year + 1
    False -> year
  }
  #(year, month, day)
}
