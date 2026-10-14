//// The Configuration contract (docs/specs/config.allium): the opt-in label,
//// the six override annotations and the safe-to-evict opt-in, their parse
//// against the install-wide defaults, the invalid and unknown keys, the
//// target set discovery derives from one cycle's three LISTs, and the pods
//// that leave it. Nothing here reads the cluster, a clock or application
//// configuration: the install-wide values arrive in `Defaults`, and the LIST
//// results as k8s_client's values. `installed` is the one check of the
//// install-wide values the application callback makes at start (Installed).

import gleam/bool
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import knarr/k8s_client.{type Deployment, type Pod, type ReplicaSet}
import knarr/observability.{type Level}

/// Every key knarr reads on a Deployment is under this prefix (Prefix).
pub const prefix = "knarr.io/"

/// The opt-in label, whose value must be exactly "true" (OptIn).
pub const enabled_key = "knarr.io/enabled"

/// The override of config.status_port (Keys).
pub const status_port_key = "knarr.io/status-port"

/// The override of config.status_path (Keys).
pub const status_path_key = "knarr.io/status-path"

/// The override of config.thresholds (Keys).
pub const thresholds_key = "knarr.io/thresholds"

/// The override of config.threshold_margin (Keys).
pub const threshold_margin_key = "knarr.io/threshold-margin"

/// The override of config.poll_interval (Keys).
pub const poll_interval_key = "knarr.io/poll-interval"

/// The override of config.patch_interval (Keys).
pub const patch_interval_key = "knarr.io/patch-interval"

/// The safe-to-evict opt-in annotation, whose value must be exactly "true"
/// (SafeToEvict).
pub const safe_to_evict_key = "knarr.io/safe-to-evict"

/// The install-wide values the parse fills in and checks against. Every
/// duration is whole seconds.
pub type Defaults {
  Defaults(
    status_port: Int,
    status_path: String,
    thresholds: List(Int),
    threshold_margin: Int,
    poll_interval: Int,
    patch_interval: Int,
    poll_timeout: Int,
  )
}

/// One Deployment's effective settings (Effective).
pub type Settings {
  Settings(
    status_port: Int,
    status_path: String,
    thresholds: List(Int),
    threshold_margin: Int,
    poll_interval: Int,
    patch_interval: Int,
    safe_to_evict: Bool,
  )
}

/// One annotation under the prefix whose value the parse ignored: its full
/// key, the trimmed value text found, and why (InvalidValue).
pub type Invalid {
  Invalid(key: String, value: String, reason: String)
}

/// One member of the target set: a pod, the Deployment it was matched to by
/// name and uid, and that Deployment's effective settings.
pub type Target {
  Target(
    pod_name: String,
    deployment_name: String,
    deployment_uid: String,
    settings: Settings,
  )
}

/// Every install-wide value the application reads at start, checked
/// (Installed). `max_body_bytes` is worker_contract's, `unknown_polls` and
/// `absent_after` reconcile's, `list_interval` and `poll_concurrency`
/// budget's, `log_level` observability's; the rest are in `defaults`.
pub type Installed {
  Installed(
    defaults: Defaults,
    max_body_bytes: Int,
    unknown_polls: Int,
    absent_after: Int,
    list_interval: Int,
    poll_concurrency: Int,
    log_level: Level,
  )
}

/// Why the install-wide values were refused: the first key whose value is
/// not of its type or is outside its range, and why.
pub type InstalledError {
  InstalledError(key: String, reason: String)
}

/// The largest threshold member, which cost_mapping's Clamp makes the top of
/// the reachable range (Syntax).
const max_threshold = 2_147_483_647

/// True exactly for the pair knarr.io/enabled = "true" (OptIn).
pub fn opted_in(labels: Dict(String, String)) -> Bool {
  dict.get(labels, enabled_key) == Ok("true")
}

/// The effective settings: each override when present and valid, else its
/// default, with the two cross-value rules read against effective values
/// (Effective, Syntax, Keys, SafeToEvict). A Deployment with no annotations
/// map has an empty dict, as k8s_client reads it.
pub fn parse(
  annotations annotations: Dict(String, String),
  defaults defaults: Defaults,
) -> Settings {
  read(annotations:, defaults:).settings
}

/// One entry per invalid key, in the order status-port, status-path,
/// thresholds, threshold-margin, poll-interval, patch-interval,
/// safe-to-evict; `parse` reads each as its fallback (InvalidValue).
pub fn invalid(
  annotations annotations: Dict(String, String),
  defaults defaults: Defaults,
) -> List(Invalid) {
  read(annotations:, defaults:).invalid
}

/// Each unknown key under the prefix as "label <key>" or "annotation <key>",
/// labels first, each group in lexicographic key order (Unknown).
pub fn unknown(
  labels labels: Dict(String, String),
  annotations annotations: Dict(String, String),
) -> List(String) {
  let under = fn(map: Dict(String, String), known: List(String), kind: String) {
    dict.keys(map)
    |> list.filter(fn(key) {
      string.starts_with(key, prefix) && !list.contains(known, key)
    })
    |> list.sort(string.compare)
    |> list.map(fn(key) { kind <> " " <> key })
  }

  list.append(
    under(labels, [enabled_key], "label"),
    under(annotations, annotation_keys, "annotation"),
  )
}

/// "<key>: <value> is invalid, <reason>; <fallback> stands", with the value
/// in double quotes and "the default" or "0" for the fallback (InvalidValue).
pub fn message(invalid: Invalid) -> String {
  let fallback = case invalid.reason == reason(NotBelowFirstThreshold) {
    True -> "0"
    False -> "the default"
  }
  invalid.key
  <> ": \""
  <> invalid.value
  <> "\" is invalid, "
  <> invalid.reason
  <> "; "
  <> fallback
  <> " stands"
}

/// One Target per listed pod whose controller owner is a listed ReplicaSet
/// whose controller owner is a listed, opted-in Deployment, matched by uid,
/// in the order of `pods` (Discovery).
pub fn targets(
  deployments deployments: List(Deployment),
  replica_sets replica_sets: List(ReplicaSet),
  pods pods: List(Pod),
  defaults defaults: Defaults,
) -> List(Target) {
  let deployments =
    deployments
    |> list.filter(fn(deployment) { opted_in(deployment.labels) })
    |> list.map(fn(deployment) { #(deployment.uid, deployment) })
    |> dict.from_list
  let replica_sets =
    replica_sets
    |> list.map(fn(replica_set) { #(replica_set.uid, replica_set) })
    |> dict.from_list

  list.filter_map(pods, fn(pod) {
    use replica_set <- result.try(controlled_by(pod.owner, replica_sets))
    use deployment <- result.try(controlled_by(replica_set.owner, deployments))
    Ok(Target(
      pod_name: pod.name,
      deployment_name: deployment.name,
      deployment_uid: deployment.uid,
      settings: parse(annotations: deployment.annotations, defaults:),
    ))
  })
}

/// The listed object the controller owner reference names by uid, if any.
fn controlled_by(
  owner: Option(k8s_client.Owner),
  listed: Dict(String, a),
) -> Result(a, Nil) {
  case owner {
    Some(owner) -> dict.get(listed, owner.uid)
    None -> Error(Nil)
  }
}

/// The pod names in `previous` and not in `current` that `pods` still shows,
/// in the order of `previous` (Effective).
pub fn leaving(
  previous previous: List(Target),
  current current: List(Target),
  pods pods: List(Pod),
) -> List(String) {
  let current = list.map(current, fn(target) { target.pod_name })
  let listed = list.map(pods, fn(pod) { pod.name })

  previous
  |> list.map(fn(target) { target.pod_name })
  |> list.filter(fn(name) {
    !list.contains(current, name) && list.contains(listed, name)
  })
}

/// Checks every install-wide value the application read, given as the key
/// and the term OTP application configuration holds for it, each already
/// present (the callback fills in the default for an unset key): an integer
/// for every key but `status_path`, a string, `thresholds`, a list of
/// integers, and `log_level`, one of "debug", "info", "warning" and "error".
/// Ranges: status_port 1 to 65535; status_path absolute, starting with "/",
/// no "?" or "#"; max_body_bytes at least 1; thresholds strictly increasing
/// positive integers up to 2147483647 with at least one member;
/// threshold_margin 0 or more and below the first threshold; unknown_polls 1
/// to 100; absent_after 30 to 3600; poll_interval 5 to 300; poll_timeout 1
/// to poll_interval less one; patch_interval 0 to 3600; list_interval 10 to
/// 600; poll_concurrency 1 to 1024. The first key refused, in that order,
/// is the error (Installed).
pub fn installed(
  values: List(#(String, Dynamic)),
) -> Result(Installed, InstalledError) {
  let int_in = fn(key, low, high) {
    installed_value(values, key, decode.int, NotAnInteger, fn(value) {
      in_range(value:, low:, high:)
    })
  }

  use status_port <- result.try(int_in("status_port", 1, 65_535))
  use status_path <- result.try(installed_value(
    values,
    "status_path",
    decode.string,
    NotAString,
    check_path,
  ))
  use max_body_bytes <- result.try(
    installed_value(
      values,
      "max_body_bytes",
      decode.int,
      NotAnInteger,
      at_least(_, 1),
    ),
  )
  use thresholds <- result.try(installed_value(
    values,
    "thresholds",
    decode.list(decode.int),
    NotAListOfIntegers,
    check_thresholds,
  ))
  use threshold_margin <- result.try(
    installed_value(
      values,
      "threshold_margin",
      decode.int,
      NotAnInteger,
      fn(margin) {
        use margin <- result.try(at_least(margin, 0))
        check_margin(margin, thresholds)
      },
    ),
  )
  use unknown_polls <- result.try(int_in("unknown_polls", 1, 100))
  use absent_after <- result.try(int_in("absent_after", 30, 3600))
  use poll_interval <- result.try(int_in("poll_interval", 5, 300))
  use poll_timeout <- result.try(
    installed_value(
      values,
      "poll_timeout",
      decode.int,
      NotAnInteger,
      fn(timeout) {
        use timeout <- result.try(at_least(timeout, 1))
        use <- bool.guard(timeout >= poll_interval, Error(NotBelowPollInterval))
        Ok(timeout)
      },
    ),
  )
  use patch_interval <- result.try(int_in("patch_interval", 0, 3600))
  use list_interval <- result.try(int_in("list_interval", 10, 600))
  use poll_concurrency <- result.try(int_in("poll_concurrency", 1, 1024))
  use log_level <- result.try(
    installed_value(values, "log_level", decode.string, NotAString, fn(text) {
      option.to_result(observability.parse_level(text), NotALevel)
    }),
  )

  Ok(Installed(
    defaults: Defaults(
      status_port:,
      status_path:,
      thresholds:,
      threshold_margin:,
      poll_interval:,
      patch_interval:,
      poll_timeout:,
    ),
    max_body_bytes:,
    unknown_polls:,
    absent_after:,
    list_interval:,
    poll_concurrency:,
    log_level:,
  ))
}

/// One install-wide value: found by its key, decoded as its type, then
/// checked; each failure names the key.
fn installed_value(
  values: List(#(String, Dynamic)),
  key: String,
  decoder: decode.Decoder(a),
  wrong_type: Refusal,
  check: fn(a) -> Result(b, Refusal),
) -> Result(b, InstalledError) {
  let refuse = fn(refusal) { InstalledError(key:, reason: reason(refusal)) }
  use value <- result.try(
    list.key_find(values, key) |> result.replace_error(refuse(Missing)),
  )
  use decoded <- result.try(
    decode.run(value, decoder) |> result.replace_error(refuse(wrong_type)),
  )
  check(decoded) |> result.map_error(refuse)
}

// --------------------------------------------------------------- Parsing ---

/// The override annotation keys, in the order `invalid` lists them, with the
/// safe-to-evict opt-in last.
const annotation_keys = [
  status_port_key,
  status_path_key,
  thresholds_key,
  threshold_margin_key,
  poll_interval_key,
  patch_interval_key,
  safe_to_evict_key,
]

/// `parse` and `invalid` read the same `Read`, so they agree.
type Read {
  Read(settings: Settings, invalid: List(Invalid))
}

/// One override as read: the value when the key is present and valid, else
/// the fallback, and the entry when it is invalid.
type Override(a) {
  Override(value: a, invalid: Option(Invalid))
}

/// Why a value was refused, under Syntax, Keys, Effective or Installed;
/// `reason` is its text in an `Invalid` or `InstalledError`.
type Refusal {
  Missing
  NotAnInteger
  NotAString
  NotAListOfIntegers
  NotALevel
  Outside(low: Int, high: Int)
  Below(low: Int)
  NotAbsolute
  QueryOrFragment
  Empty
  MemberNotAnInteger
  MemberNotPositive
  MemberAboveMax
  NotIncreasing
  NotBelowFirstThreshold
  NotAboveTimeout
  NotBelowPollInterval
  NotTrue
}

/// The short, stable text of a refusal, the same in `invalid` and
/// `installed` where the rule is the same.
fn reason(refusal: Refusal) -> String {
  case refusal {
    Missing -> "missing"
    NotAnInteger -> "not an integer"
    NotAString -> "not a string"
    NotAListOfIntegers -> "not a list of integers"
    NotALevel -> "not a level"
    Outside(low:, high:) ->
      "outside " <> int.to_string(low) <> " to " <> int.to_string(high)
    Below(low:) -> "below " <> int.to_string(low)
    NotAbsolute -> "not absolute"
    QueryOrFragment -> "has a query or fragment"
    Empty -> "empty"
    MemberNotAnInteger -> "member not an integer"
    MemberNotPositive -> "member not positive"
    MemberAboveMax -> "member above " <> int.to_string(max_threshold)
    NotIncreasing -> "not strictly increasing"
    NotBelowFirstThreshold -> "not below the first threshold"
    NotAboveTimeout -> "not greater than the poll timeout"
    NotBelowPollInterval -> "not below the poll interval"
    NotTrue -> "not true"
  }
}

fn read(
  annotations annotations: Dict(String, String),
  defaults defaults: Defaults,
) -> Read {
  let status_port =
    override(annotations, status_port_key, defaults.status_port, fn(text) {
      use port <- result.try(integer(text))
      in_range(value: port, low: 1, high: 65_535)
    })
  let status_path =
    override(annotations, status_path_key, defaults.status_path, check_path)
  let thresholds =
    override(annotations, thresholds_key, defaults.thresholds, fn(text) {
      use members <- result.try(threshold_members(text))
      check_thresholds(members)
    })
  let threshold_margin =
    margin(
      annotations:,
      default: defaults.threshold_margin,
      thresholds: thresholds.value,
    )
  let poll_interval =
    override(annotations, poll_interval_key, defaults.poll_interval, fn(text) {
      use seconds <- result.try(integer(text))
      use seconds <- result.try(in_range(value: seconds, low: 5, high: 300))
      use <- bool.guard(
        seconds <= defaults.poll_timeout,
        Error(NotAboveTimeout),
      )
      Ok(seconds)
    })
  let patch_interval =
    override(annotations, patch_interval_key, defaults.patch_interval, fn(text) {
      use seconds <- result.try(integer(text))
      in_range(value: seconds, low: 0, high: 3600)
    })
  let safe_to_evict =
    override(annotations, safe_to_evict_key, False, fn(text) {
      case text {
        "true" -> Ok(True)
        _ -> Error(NotTrue)
      }
    })

  Read(
    settings: Settings(
      status_port: status_port.value,
      status_path: status_path.value,
      thresholds: thresholds.value,
      threshold_margin: threshold_margin.value,
      poll_interval: poll_interval.value,
      patch_interval: patch_interval.value,
      safe_to_evict: safe_to_evict.value,
    ),
    invalid: list.filter_map(
      [
        status_port.invalid,
        status_path.invalid,
        thresholds.invalid,
        threshold_margin.invalid,
        poll_interval.invalid,
        patch_interval.invalid,
        safe_to_evict.invalid,
      ],
      option.to_result(_, Nil),
    ),
  )
}

/// One key read from the map: absent is the fallback with no entry; present
/// is trimmed and checked, the fallback standing with an entry when the
/// check refuses it (Syntax, InvalidValue).
fn override(
  annotations: Dict(String, String),
  key: String,
  fallback: a,
  check: fn(String) -> Result(a, Refusal),
) -> Override(a) {
  case dict.get(annotations, key) {
    Error(Nil) -> Override(value: fallback, invalid: None)
    Ok(found) -> {
      let value = trim(found)
      case check(value) {
        Ok(parsed) -> Override(value: parsed, invalid: None)
        Error(refusal) ->
          Override(
            value: fallback,
            invalid: Some(Invalid(key:, value:, reason: reason(refusal))),
          )
      }
    }
  }
}

/// The margin, read against the effective thresholds (Effective): the
/// candidate is the override when it is present and parses, else the
/// default, with the default's digits as the entry's value when the key is
/// absent. A candidate not below the first threshold leaves 0 standing; an
/// override that does not parse leaves the default standing when that is
/// below the first threshold.
fn margin(
  annotations annotations: Dict(String, String),
  default default: Int,
  thresholds thresholds: List(Int),
) -> Override(Int) {
  let #(text, parsed) = case dict.get(annotations, threshold_margin_key) {
    Error(Nil) -> #(int.to_string(default), Ok(default))
    Ok(found) -> {
      let text = trim(found)
      #(text, integer(text))
    }
  }
  let candidate = result.unwrap(parsed, default)
  let invalid = fn(refusal) {
    Some(Invalid(
      key: threshold_margin_key,
      value: text,
      reason: reason(refusal),
    ))
  }

  case check_margin(candidate, thresholds), parsed {
    Error(refusal), _ -> Override(value: 0, invalid: invalid(refusal))
    Ok(_), Error(refusal) -> Override(value: default, invalid: invalid(refusal))
    Ok(margin), Ok(_) -> Override(value: margin, invalid: None)
  }
}

/// Leading and trailing ASCII space, tab, carriage return and line feed
/// removed (Syntax).
fn trim(text: String) -> String {
  text |> trim_start |> string.reverse |> trim_start |> string.reverse
}

fn trim_start(text: String) -> String {
  case text {
    " " <> rest | "\t" <> rest | "\r" <> rest | "\n" <> rest -> trim_start(rest)
    _ -> text
  }
}

/// Decimal digits only, with no leading zero except the single digit 0
/// (Syntax).
fn integer(text: String) -> Result(Int, Refusal) {
  let digits = case text {
    "0" -> True
    "0" <> _ | "" -> False
    _ -> string.to_graphemes(text) |> list.all(is_digit)
  }
  use <- bool.guard(!digits, Error(NotAnInteger))
  int.parse(text) |> result.replace_error(NotAnInteger)
}

fn is_digit(grapheme: String) -> Bool {
  case grapheme {
    "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" -> True
    _ -> False
  }
}

/// The threshold list's members, each trimmed and parsed as an integer; an
/// empty string has none (Syntax).
fn threshold_members(text: String) -> Result(List(Int), Refusal) {
  case text {
    "" -> Ok([])
    _ ->
      string.split(text, ",")
      |> list.try_map(fn(member) {
        integer(trim(member)) |> result.replace_error(MemberNotAnInteger)
      })
  }
}

// ---------------------------------------------------------------- Checks ---

/// The ranges and rules the overrides and the install-wide values share
/// (Keys, Installed).
fn in_range(
  value value: Int,
  low low: Int,
  high high: Int,
) -> Result(Int, Refusal) {
  use <- bool.guard(value < low || value > high, Error(Outside(low:, high:)))
  Ok(value)
}

fn at_least(value: Int, low: Int) -> Result(Int, Refusal) {
  use <- bool.guard(value < low, Error(Below(low:)))
  Ok(value)
}

/// Absolute, starting with "/", with no query or fragment.
fn check_path(path: String) -> Result(String, Refusal) {
  use <- bool.guard(!string.starts_with(path, "/"), Error(NotAbsolute))
  use <- bool.guard(
    string.contains(path, "?") || string.contains(path, "#"),
    Error(QueryOrFragment),
  )
  Ok(path)
}

/// Strictly increasing positive integers up to 2147483647, at least one.
fn check_thresholds(members: List(Int)) -> Result(List(Int), Refusal) {
  use <- bool.guard(members == [], Error(Empty))
  use <- bool.guard(
    list.any(members, fn(member) { member < 1 }),
    Error(MemberNotPositive),
  )
  use <- bool.guard(
    list.any(members, fn(member) { member > max_threshold }),
    Error(MemberAboveMax),
  )
  use <- bool.guard(!increasing(members), Error(NotIncreasing))
  Ok(members)
}

fn increasing(members: List(Int)) -> Bool {
  case members {
    [first, second, ..rest] -> first < second && increasing([second, ..rest])
    _ -> True
  }
}

/// Below the first threshold.
fn check_margin(margin: Int, thresholds: List(Int)) -> Result(Int, Refusal) {
  case thresholds {
    [first, ..] if margin < first -> Ok(margin)
    _ -> Error(NotBelowFirstThreshold)
  }
}
