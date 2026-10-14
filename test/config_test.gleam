//// Tests for the Configuration contract (docs/specs/config.allium): the
//// opt-in, the parse of the six overrides and the safe-to-evict opt-in
//// against the install-wide defaults, the invalid and unknown keys, the
//// target set and the pods that leave it, and the check of the install-wide
//// values. Every function is pure, so each test passes values in and reads
//// values out. Each test names the clause or plan obligation it traces to.

import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/option.{type Option, None, Some}
import knarr/config.{
  type Invalid, type Settings, Defaults, Installed, InstalledError, Invalid,
  Settings, Target,
}
import knarr/k8s_client.{Deployment, Owner, Pod, ReplicaSet}
import knarr/observability

const defaults =
  Defaults(
    status_port: 8080,
    status_path: "/knarr/v1/status",
    thresholds: [300, 900, 1800, 3600],
    threshold_margin: 60,
    poll_interval: 30,
    patch_interval: 60,
    poll_timeout: 5,
  )

/// The settings of a Deployment with no override.
const settings =
  Settings(
    status_port: 8080,
    status_path: "/knarr/v1/status",
    thresholds: [300, 900, 1800, 3600],
    threshold_margin: 60,
    poll_interval: 30,
    patch_interval: 60,
    safe_to_evict: False,
  )

const opted_in_labels = [#("knarr.io/enabled", "true")]

fn parsed(annotations: List(#(String, String))) -> Settings {
  config.parse(dict.from_list(annotations), defaults)
}

fn invalids(annotations: List(#(String, String))) -> List(Invalid) {
  config.invalid(dict.from_list(annotations), defaults)
}

/// Asserts that one annotation parses to the settings and invalid list
/// given.
fn expect(
  key key: String,
  value value: String,
  settings expected: Settings,
  invalid invalid: List(Invalid),
) -> Nil {
  assert parsed([#(key, value)]) == expected
  assert invalids([#(key, value)]) == invalid
}

/// Asserts that one annotation is invalid with the reason given, so the
/// default settings stand.
fn expect_invalid(
  key key: String,
  value value: String,
  reason reason: String,
) -> Nil {
  expect(key:, value:, settings: settings, invalid: [
    Invalid(key:, value:, reason:),
  ])
}

fn deployment(
  name name: String,
  uid uid: String,
  labels labels: List(#(String, String)),
) -> k8s_client.Deployment {
  Deployment(
    name:,
    uid:,
    labels: dict.from_list(labels),
    annotations: dict.new(),
  )
}

fn replica_set(
  name name: String,
  uid uid: String,
  deployment deployment: Option(#(String, String)),
) -> k8s_client.ReplicaSet {
  ReplicaSet(name:, uid:, owner: owner("Deployment", deployment))
}

fn pod(name: String, replica_set: Option(#(String, String))) -> k8s_client.Pod {
  Pod(
    name:,
    uid: name <> "-uid",
    annotations: None,
    deletion_timestamp: None,
    pod_ip: Some("10.1.2.3"),
    ready: True,
    owner: owner("ReplicaSet", replica_set),
  )
}

fn owner(
  kind: String,
  named: Option(#(String, String)),
) -> Option(k8s_client.Owner) {
  case named {
    Some(#(name, uid)) -> Some(Owner(kind:, name:, uid:))
    None -> None
  }
}

fn target(pod_name: String, deployment: #(String, String)) -> config.Target {
  Target(
    pod_name:,
    deployment_name: deployment.0,
    deployment_uid: deployment.1,
    settings:,
  )
}

/// The install-wide values at their module defaults.
fn installed_defaults() -> List(#(String, Dynamic)) {
  [
    #("status_port", dynamic.int(8080)),
    #("status_path", dynamic.string("/knarr/v1/status")),
    #("max_body_bytes", dynamic.int(4096)),
    #(
      "thresholds",
      dynamic.list([
        dynamic.int(300),
        dynamic.int(900),
        dynamic.int(1800),
        dynamic.int(3600),
      ]),
    ),
    #("threshold_margin", dynamic.int(60)),
    #("unknown_polls", dynamic.int(3)),
    #("absent_after", dynamic.int(300)),
    #("poll_interval", dynamic.int(30)),
    #("poll_timeout", dynamic.int(5)),
    #("patch_interval", dynamic.int(60)),
    #("list_interval", dynamic.int(60)),
    #("poll_concurrency", dynamic.int(64)),
    #("log_level", dynamic.string("info")),
  ]
}

/// The defaults with one value replaced.
fn with(key: String, value: Dynamic) -> List(#(String, Dynamic)) {
  list.map(installed_defaults(), fn(pair) {
    case pair.0 == key {
      True -> #(key, value)
      False -> pair
    }
  })
}

fn without(key: String) -> List(#(String, Dynamic)) {
  list.filter(installed_defaults(), fn(pair) { pair.0 != key })
}

// ---------------------------------------------------------------- Prefix ---

// Configuration.Prefix and Keys: every key knarr reads is under knarr.io/,
// the opt-in label, the six override annotations hyphenated after the
// config key each overrides, and the safe-to-evict opt-in.
pub fn every_key_is_under_the_fixed_prefix_test() -> Nil {
  assert config.prefix == "knarr.io/"
  assert config.enabled_key == "knarr.io/enabled"
  assert config.status_port_key == "knarr.io/status-port"
  assert config.status_path_key == "knarr.io/status-path"
  assert config.thresholds_key == "knarr.io/thresholds"
  assert config.threshold_margin_key == "knarr.io/threshold-margin"
  assert config.poll_interval_key == "knarr.io/poll-interval"
  assert config.patch_interval_key == "knarr.io/patch-interval"
  assert config.safe_to_evict_key == "knarr.io/safe-to-evict"
}

// ----------------------------------------------------------------- OptIn ---

// Configuration.OptIn: opted_in is true exactly for knarr.io/enabled = "true".
pub fn opted_in_is_true_for_the_exact_value_test() -> Nil {
  assert config.opted_in(dict.from_list(opted_in_labels))
  assert config.opted_in(
    dict.from_list([#("app", "worker"), #("knarr.io/enabled", "true")]),
  )
}

// Configuration.OptIn: "True", "yes", "" and the label absent are not opted
// in.
pub fn opted_in_is_false_for_any_other_value_or_absent_test() -> Nil {
  assert !config.opted_in(dict.from_list([#("knarr.io/enabled", "True")]))
  assert !config.opted_in(dict.from_list([#("knarr.io/enabled", "yes")]))
  assert !config.opted_in(dict.from_list([#("knarr.io/enabled", "")]))
  assert !config.opted_in(dict.from_list([#("knarr.io/enabled", " true")]))
  assert !config.opted_in(dict.from_list([#("app", "worker")]))
  assert !config.opted_in(dict.new())
}

// ------------------------------------------------------------- Effective ---

// Configuration.Effective: with no annotation every setting is its default
// and nothing is invalid.
pub fn parse_of_no_annotations_is_the_defaults_test() -> Nil {
  assert parsed([]) == settings
  assert invalids([]) == []
}

// Configuration.Effective: an annotation outside the prefix changes nothing.
pub fn parse_ignores_keys_outside_the_prefix_test() -> Nil {
  expect(key: "status-port", value: "9000", settings: settings, invalid: [])
  expect(
    key: "other.io/status-port",
    value: "9000",
    settings: settings,
    invalid: [],
  )
}

// Configuration.Effective: every override present and valid is read, and
// the invalid ones fall back while the others keep their result.
pub fn parse_reads_every_valid_override_and_only_those_test() -> Nil {
  let annotations = [
    #("knarr.io/status-port", "9000"),
    #("knarr.io/status-path", "/internal/knarr"),
    #("knarr.io/thresholds", "100,200"),
    #("knarr.io/threshold-margin", "10"),
    #("knarr.io/poll-interval", "15"),
    #("knarr.io/patch-interval", "0"),
    #("knarr.io/safe-to-evict", "true"),
  ]

  assert parsed(annotations)
    == Settings(
      status_port: 9000,
      status_path: "/internal/knarr",
      thresholds: [100, 200],
      threshold_margin: 10,
      poll_interval: 15,
      patch_interval: 0,
      safe_to_evict: True,
    )
  assert invalids(annotations) == []

  let mixed = [
    #("knarr.io/status-port", "70000"),
    #("knarr.io/status-path", "/internal/knarr"),
    #("knarr.io/thresholds", "100,200"),
    #("knarr.io/threshold-margin", "10"),
    #("knarr.io/poll-interval", "4"),
    #("knarr.io/patch-interval", "0"),
    #("knarr.io/safe-to-evict", "yes"),
  ]

  assert parsed(mixed)
    == Settings(
      status_port: 8080,
      status_path: "/internal/knarr",
      thresholds: [100, 200],
      threshold_margin: 10,
      poll_interval: 30,
      patch_interval: 0,
      safe_to_evict: False,
    )
  assert invalids(mixed)
    == [
      Invalid(
        key: "knarr.io/status-port",
        value: "70000",
        reason: "outside 1 to 65535",
      ),
      Invalid(
        key: "knarr.io/poll-interval",
        value: "4",
        reason: "outside 5 to 300",
      ),
      Invalid(key: "knarr.io/safe-to-evict", value: "yes", reason: "not true"),
    ]
}

// ---------------------------------------------------------- Keys: ranges ---

// Configuration.Keys: knarr.io/status-port is 1 to 65535.
pub fn status_port_edges_test() -> Nil {
  let port = fn(port) { Settings(..settings, status_port: port) }

  expect(
    key: "knarr.io/status-port",
    value: "1",
    settings: port(1),
    invalid: [],
  )
  expect(
    key: "knarr.io/status-port",
    value: "65535",
    settings: port(65_535),
    invalid: [],
  )
  expect_invalid(
    key: "knarr.io/status-port",
    value: "0",
    reason: "outside 1 to 65535",
  )
  expect_invalid(
    key: "knarr.io/status-port",
    value: "65536",
    reason: "outside 1 to 65535",
  )
}

// Configuration.Keys: knarr.io/status-path is absolute, starts with /, and
// has no query or fragment.
pub fn status_path_edges_test() -> Nil {
  let path = fn(path) { Settings(..settings, status_path: path) }

  expect(
    key: "knarr.io/status-path",
    value: "/",
    settings: path("/"),
    invalid: [],
  )
  expect(
    key: "knarr.io/status-path",
    value: "/internal/knarr",
    settings: path("/internal/knarr"),
    invalid: [],
  )
  expect_invalid(
    key: "knarr.io/status-path",
    value: "internal/knarr",
    reason: "not absolute",
  )
  expect_invalid(
    key: "knarr.io/status-path",
    value: "/internal?x=1",
    reason: "has a query or fragment",
  )
  expect_invalid(
    key: "knarr.io/status-path",
    value: "/internal#top",
    reason: "has a query or fragment",
  )
}

// Configuration.Keys: knarr.io/thresholds is strictly increasing positive
// integers with at least one member.
pub fn thresholds_edges_test() -> Nil {
  let thresholds = fn(thresholds) { Settings(..settings, thresholds:) }

  expect(
    key: "knarr.io/thresholds",
    value: "61",
    settings: thresholds([61]),
    invalid: [],
  )
  expect(
    key: "knarr.io/thresholds",
    value: "100,2147483647",
    settings: thresholds([100, 2_147_483_647]),
    invalid: [],
  )
  expect_invalid(
    key: "knarr.io/thresholds",
    value: "0",
    reason: "member not positive",
  )
  expect_invalid(
    key: "knarr.io/thresholds",
    value: "100,2147483648",
    reason: "member above 2147483647",
  )
}

// Configuration.Keys: knarr.io/threshold-margin is 0 or more and below the
// first effective threshold.
pub fn threshold_margin_edges_test() -> Nil {
  let margin = fn(margin) { Settings(..settings, threshold_margin: margin) }

  expect(
    key: "knarr.io/threshold-margin",
    value: "0",
    settings: margin(0),
    invalid: [],
  )
  expect(
    key: "knarr.io/threshold-margin",
    value: "299",
    settings: margin(299),
    invalid: [],
  )
  expect(
    key: "knarr.io/threshold-margin",
    value: "300",
    settings: margin(0),
    invalid: [
      Invalid(
        key: "knarr.io/threshold-margin",
        value: "300",
        reason: "not below the first threshold",
      ),
    ],
  )
}

// Configuration.Keys: knarr.io/poll-interval is 5 to 300 whole seconds.
pub fn poll_interval_edges_test() -> Nil {
  let interval = fn(interval) { Settings(..settings, poll_interval: interval) }

  expect(
    key: "knarr.io/poll-interval",
    value: "6",
    settings: interval(6),
    invalid: [],
  )
  expect(
    key: "knarr.io/poll-interval",
    value: "300",
    settings: interval(300),
    invalid: [],
  )
  expect_invalid(
    key: "knarr.io/poll-interval",
    value: "4",
    reason: "outside 5 to 300",
  )
  expect_invalid(
    key: "knarr.io/poll-interval",
    value: "301",
    reason: "outside 5 to 300",
  )
}

// Configuration.Effective: knarr.io/poll-interval must be greater than
// defaults.poll_timeout, read against the effective value.
pub fn poll_interval_must_exceed_the_poll_timeout_test() -> Nil {
  expect_invalid(
    key: "knarr.io/poll-interval",
    value: "5",
    reason: "not greater than the poll timeout",
  )
  expect(
    key: "knarr.io/poll-interval",
    value: "6",
    settings: Settings(..settings, poll_interval: 6),
    invalid: [],
  )

  let slow = Defaults(..defaults, poll_timeout: 20)
  let annotations = dict.from_list([#("knarr.io/poll-interval", "20")])

  assert config.parse(annotations, slow) == settings
  assert config.invalid(annotations, slow)
    == [
      Invalid(
        key: "knarr.io/poll-interval",
        value: "20",
        reason: "not greater than the poll timeout",
      ),
    ]
}

// Configuration.Keys: knarr.io/patch-interval is 0 to 3600 whole seconds,
// 0 valid.
pub fn patch_interval_edges_test() -> Nil {
  let interval = fn(interval) { Settings(..settings, patch_interval: interval) }

  expect(
    key: "knarr.io/patch-interval",
    value: "0",
    settings: interval(0),
    invalid: [],
  )
  expect(
    key: "knarr.io/patch-interval",
    value: "3600",
    settings: interval(3600),
    invalid: [],
  )
  expect_invalid(
    key: "knarr.io/patch-interval",
    value: "3601",
    reason: "outside 0 to 3600",
  )
}

// ---------------------------------------------------------------- Syntax ---

// Configuration.Syntax: ASCII space, tab, carriage return and line feed are
// trimmed from both ends of every value.
pub fn whitespace_around_a_value_is_trimmed_test() -> Nil {
  expect(
    key: "knarr.io/status-port",
    value: " \t9000\r\n",
    settings: Settings(..settings, status_port: 9000),
    invalid: [],
  )
  expect(
    key: "knarr.io/status-path",
    value: "  /internal/knarr\n",
    settings: Settings(..settings, status_path: "/internal/knarr"),
    invalid: [],
  )
  expect(
    key: "knarr.io/thresholds",
    value: " 300, 900 ",
    settings: Settings(..settings, thresholds: [300, 900]),
    invalid: [],
  )
  expect(
    key: "knarr.io/threshold-margin",
    value: "\t30\t",
    settings: Settings(..settings, threshold_margin: 30),
    invalid: [],
  )
  expect(
    key: "knarr.io/poll-interval",
    value: " 30 ",
    settings: Settings(..settings, poll_interval: 30),
    invalid: [],
  )
  expect(
    key: "knarr.io/patch-interval",
    value: "30\n",
    settings: Settings(..settings, patch_interval: 30),
    invalid: [],
  )
  expect(
    key: "knarr.io/safe-to-evict",
    value: " true\n",
    settings: Settings(..settings, safe_to_evict: True),
    invalid: [],
  )
}

// Configuration.Syntax: an integer has no sign.
pub fn a_signed_integer_is_invalid_test() -> Nil {
  expect_invalid(
    key: "knarr.io/status-port",
    value: "+30",
    reason: "not an integer",
  )
  expect_invalid(
    key: "knarr.io/status-path",
    value: "+30",
    reason: "not absolute",
  )
  expect_invalid(
    key: "knarr.io/thresholds",
    value: "+30",
    reason: "member not an integer",
  )
  expect_invalid(
    key: "knarr.io/threshold-margin",
    value: "+30",
    reason: "not an integer",
  )
  expect_invalid(
    key: "knarr.io/poll-interval",
    value: "+30",
    reason: "not an integer",
  )
  expect_invalid(
    key: "knarr.io/patch-interval",
    value: "+30",
    reason: "not an integer",
  )
  expect_invalid(
    key: "knarr.io/patch-interval",
    value: "-30",
    reason: "not an integer",
  )
}

// Configuration.Syntax: no leading zero except the single digit 0.
pub fn a_leading_zero_is_invalid_test() -> Nil {
  expect_invalid(
    key: "knarr.io/status-port",
    value: "030",
    reason: "not an integer",
  )
  expect_invalid(
    key: "knarr.io/status-path",
    value: "030",
    reason: "not absolute",
  )
  expect_invalid(
    key: "knarr.io/thresholds",
    value: "030",
    reason: "member not an integer",
  )
  expect_invalid(
    key: "knarr.io/threshold-margin",
    value: "030",
    reason: "not an integer",
  )
  expect_invalid(
    key: "knarr.io/poll-interval",
    value: "030",
    reason: "not an integer",
  )
  expect_invalid(
    key: "knarr.io/patch-interval",
    value: "030",
    reason: "not an integer",
  )
  expect_invalid(
    key: "knarr.io/patch-interval",
    value: "00",
    reason: "not an integer",
  )
}

// Configuration.Syntax: no unit, fraction or exponent.
pub fn a_unit_is_invalid_test() -> Nil {
  expect_invalid(
    key: "knarr.io/status-port",
    value: "30s",
    reason: "not an integer",
  )
  expect_invalid(
    key: "knarr.io/status-path",
    value: "30s",
    reason: "not absolute",
  )
  expect_invalid(
    key: "knarr.io/thresholds",
    value: "30s",
    reason: "member not an integer",
  )
  expect_invalid(
    key: "knarr.io/threshold-margin",
    value: "30s",
    reason: "not an integer",
  )
  expect_invalid(
    key: "knarr.io/poll-interval",
    value: "30s",
    reason: "not an integer",
  )
  expect_invalid(
    key: "knarr.io/patch-interval",
    value: "30s",
    reason: "not an integer",
  )
  expect_invalid(
    key: "knarr.io/poll-interval",
    value: "1m",
    reason: "not an integer",
  )
  expect_invalid(
    key: "knarr.io/poll-interval",
    value: "30.0",
    reason: "not an integer",
  )
  expect_invalid(
    key: "knarr.io/poll-interval",
    value: "3e1",
    reason: "not an integer",
  )
}

// Configuration.Syntax: an empty value is invalid for every key.
pub fn an_empty_value_is_invalid_test() -> Nil {
  expect_invalid(
    key: "knarr.io/status-port",
    value: "",
    reason: "not an integer",
  )
  expect_invalid(key: "knarr.io/status-path", value: "", reason: "not absolute")
  expect_invalid(key: "knarr.io/thresholds", value: "", reason: "empty")
  expect_invalid(
    key: "knarr.io/threshold-margin",
    value: "",
    reason: "not an integer",
  )
  expect_invalid(
    key: "knarr.io/poll-interval",
    value: "",
    reason: "not an integer",
  )
  expect_invalid(
    key: "knarr.io/patch-interval",
    value: "",
    reason: "not an integer",
  )
  expect_invalid(key: "knarr.io/safe-to-evict", value: "", reason: "not true")
  expect(
    key: "knarr.io/poll-interval",
    value: " \n",
    settings: settings,
    invalid: [
      Invalid(
        key: "knarr.io/poll-interval",
        value: "",
        reason: "not an integer",
      ),
    ],
  )
}

// Configuration.Syntax: the threshold list's members are each trimmed, so
// "300, 900" and "300,900" are equal.
pub fn thresholds_members_are_trimmed_test() -> Nil {
  let expected = Settings(..settings, thresholds: [300, 900])

  expect(
    key: "knarr.io/thresholds",
    value: "300, 900",
    settings: expected,
    invalid: [],
  )
  expect(
    key: "knarr.io/thresholds",
    value: "300,900",
    settings: expected,
    invalid: [],
  )
  expect(
    key: "knarr.io/thresholds",
    value: "300 ,\t900",
    settings: expected,
    invalid: [],
  )
}

// Configuration.Syntax: a trailing comma and an empty member are invalid.
pub fn thresholds_with_an_empty_member_are_invalid_test() -> Nil {
  expect_invalid(
    key: "knarr.io/thresholds",
    value: "300,900,",
    reason: "member not an integer",
  )
  expect_invalid(
    key: "knarr.io/thresholds",
    value: "300,,900",
    reason: "member not an integer",
  )
  expect_invalid(
    key: "knarr.io/thresholds",
    value: ",300",
    reason: "member not an integer",
  )
  expect_invalid(
    key: "knarr.io/thresholds",
    value: "300, ,900",
    reason: "member not an integer",
  )
}

// Configuration.Syntax: a duplicate, a member not greater than the one
// before it, a 0 and a member above 2147483647 are invalid.
pub fn thresholds_out_of_order_or_range_are_invalid_test() -> Nil {
  expect_invalid(
    key: "knarr.io/thresholds",
    value: "300,300",
    reason: "not strictly increasing",
  )
  expect_invalid(
    key: "knarr.io/thresholds",
    value: "900,300",
    reason: "not strictly increasing",
  )
  expect_invalid(
    key: "knarr.io/thresholds",
    value: "0,300",
    reason: "member not positive",
  )
  expect_invalid(
    key: "knarr.io/thresholds",
    value: "2147483648",
    reason: "member above 2147483647",
  )
}

// Configuration.Syntax: the path is taken as written after trimming.
pub fn status_path_is_taken_as_written_test() -> Nil {
  expect(
    key: "knarr.io/status-path",
    value: "/Knarr/V1//status/",
    settings: Settings(..settings, status_path: "/Knarr/V1//status/"),
    invalid: [],
  )
}

// ---------------------------------------------------- Effective: margin ---

// Configuration.Effective: a valid thresholds override that drops the first
// threshold to or below the default margin makes the margin invalid: the
// thresholds stand, the margin is 0, and the entry carries the default's
// digits as its value.
pub fn thresholds_override_below_the_default_margin_zeroes_the_margin_test() -> Nil {
  let annotations = [#("knarr.io/thresholds", "50,900")]

  assert parsed(annotations)
    == Settings(..settings, thresholds: [50, 900], threshold_margin: 0)
  assert invalids(annotations)
    == [
      Invalid(
        key: "knarr.io/threshold-margin",
        value: "60",
        reason: "not below the first threshold",
      ),
    ]
}

// Configuration.Effective: a thresholds override equal to the default margin
// is "to or below", so the margin is invalid.
pub fn thresholds_override_equal_to_the_default_margin_zeroes_the_margin_test() -> Nil {
  let annotations = [#("knarr.io/thresholds", "60,900")]

  assert parsed(annotations)
    == Settings(..settings, thresholds: [60, 900], threshold_margin: 0)
  assert invalids(annotations)
    == [
      Invalid(
        key: "knarr.io/threshold-margin",
        value: "60",
        reason: "not below the first threshold",
      ),
    ]
}

// Configuration.Effective: the same with a margin override present: its
// text is the value, and the override is ignored for 0.
pub fn margin_override_not_below_the_thresholds_override_is_zero_test() -> Nil {
  let annotations = [
    #("knarr.io/thresholds", "50,900"),
    #("knarr.io/threshold-margin", "70"),
  ]

  assert parsed(annotations)
    == Settings(..settings, thresholds: [50, 900], threshold_margin: 0)
  assert invalids(annotations)
    == [
      Invalid(
        key: "knarr.io/threshold-margin",
        value: "70",
        reason: "not below the first threshold",
      ),
    ]
}

// Configuration.Effective: a margin override below the thresholds override
// is valid, even where the default margin would not be.
pub fn margin_override_below_the_thresholds_override_is_valid_test() -> Nil {
  let annotations = [
    #("knarr.io/thresholds", "50,900"),
    #("knarr.io/threshold-margin", "49"),
  ]

  assert parsed(annotations)
    == Settings(..settings, thresholds: [50, 900], threshold_margin: 49)
  assert invalids(annotations) == []
}

// Configuration.Effective: validity is decided after the defaults are filled
// in, so an invalid thresholds override leaves the default thresholds, and
// the margin is read against those.
pub fn margin_is_read_against_the_default_thresholds_when_the_override_is_invalid_test() -> Nil {
  let annotations = [
    #("knarr.io/thresholds", "50,abc"),
    #("knarr.io/threshold-margin", "200"),
  ]

  assert parsed(annotations) == Settings(..settings, threshold_margin: 200)
  assert invalids(annotations)
    == [
      Invalid(
        key: "knarr.io/thresholds",
        value: "50,abc",
        reason: "member not an integer",
      ),
    ]
}

// Configuration.Effective: a margin override that does not parse falls back
// to the default; when that default is not below the first effective
// threshold either, 0 stands under the cross-value reason.
pub fn margin_override_that_does_not_parse_falls_back_to_the_default_or_zero_test() -> Nil {
  let against_default = [#("knarr.io/threshold-margin", "abc")]

  assert parsed(against_default) == settings
  assert invalids(against_default)
    == [
      Invalid(
        key: "knarr.io/threshold-margin",
        value: "abc",
        reason: "not an integer",
      ),
    ]

  let against_low = [
    #("knarr.io/thresholds", "50,900"),
    #("knarr.io/threshold-margin", "abc"),
  ]

  assert parsed(against_low)
    == Settings(..settings, thresholds: [50, 900], threshold_margin: 0)
  assert invalids(against_low)
    == [
      Invalid(
        key: "knarr.io/threshold-margin",
        value: "abc",
        reason: "not below the first threshold",
      ),
    ]
}

// ----------------------------------------------------------- SafeToEvict ---

// Configuration.SafeToEvict: "true" opts in.
pub fn safe_to_evict_true_opts_in_test() -> Nil {
  expect(
    key: "knarr.io/safe-to-evict",
    value: "true",
    settings: Settings(..settings, safe_to_evict: True),
    invalid: [],
  )
}

// Configuration.SafeToEvict: any other value is invalid and off stands.
pub fn safe_to_evict_other_value_is_invalid_test() -> Nil {
  expect_invalid(
    key: "knarr.io/safe-to-evict",
    value: "false",
    reason: "not true",
  )
  expect_invalid(
    key: "knarr.io/safe-to-evict",
    value: "True",
    reason: "not true",
  )
  expect_invalid(
    key: "knarr.io/safe-to-evict",
    value: "yes",
    reason: "not true",
  )
}

// Configuration.SafeToEvict: absent is off and not invalid.
pub fn safe_to_evict_absent_is_off_test() -> Nil {
  assert parsed([]).safe_to_evict == False
  assert invalids([]) == []
}

// ---------------------------------------------------------- InvalidValue ---

// Configuration.InvalidValue: invalid lists the keys in the order
// status-port, status-path, thresholds, threshold-margin, poll-interval,
// patch-interval, safe-to-evict, whatever the map's order.
pub fn invalid_lists_keys_in_the_fixed_order_test() -> Nil {
  let annotations = [
    #("knarr.io/safe-to-evict", "yes"),
    #("knarr.io/patch-interval", "x"),
    #("knarr.io/poll-interval", "x"),
    #("knarr.io/threshold-margin", "x"),
    #("knarr.io/thresholds", "x"),
    #("knarr.io/status-path", "x"),
    #("knarr.io/status-port", "x"),
  ]

  assert parsed(annotations) == settings
  assert list.map(invalids(annotations), fn(invalid) { invalid.key })
    == [
      "knarr.io/status-port",
      "knarr.io/status-path",
      "knarr.io/thresholds",
      "knarr.io/threshold-margin",
      "knarr.io/poll-interval",
      "knarr.io/patch-interval",
      "knarr.io/safe-to-evict",
    ]
}

// Configuration.InvalidValue: the value is the trimmed text found.
pub fn invalid_carries_the_trimmed_text_test() -> Nil {
  assert invalids([#("knarr.io/status-port", "  70000 \n")])
    == [
      Invalid(
        key: "knarr.io/status-port",
        value: "70000",
        reason: "outside 1 to 65535",
      ),
    ]
}

// Configuration.InvalidValue: message renders the key, the quoted value, the
// reason and "the default stands".
pub fn message_renders_a_default_fallback_test() -> Nil {
  assert config.message(Invalid(
      key: "knarr.io/poll-interval",
      value: "30s",
      reason: "not an integer",
    ))
    == "knarr.io/poll-interval: \"30s\" is invalid, not an integer; the default stands"
}

// Configuration.InvalidValue: the margin's cross-value fallback renders as
// "0 stands".
pub fn message_renders_the_zero_fallback_test() -> Nil {
  assert config.message(Invalid(
      key: "knarr.io/threshold-margin",
      value: "60",
      reason: "not below the first threshold",
    ))
    == "knarr.io/threshold-margin: \"60\" is invalid, not below the first threshold; 0 stands"
}

// Configuration.InvalidValue: message of every entry invalid returns is
// rendered, with each reason as invalid gave it.
pub fn message_renders_every_reason_invalid_gives_test() -> Nil {
  let messages =
    invalids([
      #("knarr.io/status-path", "status"),
      #("knarr.io/thresholds", "300,"),
      #("knarr.io/safe-to-evict", "false"),
    ])
    |> list.map(config.message)

  assert messages
    == [
      "knarr.io/status-path: \"status\" is invalid, not absolute; the default stands",
      "knarr.io/thresholds: \"300,\" is invalid, member not an integer; the default stands",
      "knarr.io/safe-to-evict: \"false\" is invalid, not true; the default stands",
    ]
}

// --------------------------------------------------------------- Unknown ---

// Configuration.Unknown: a label under the prefix other than knarr.io/enabled
// is reported as a label.
pub fn unknown_reports_a_label_under_the_prefix_test() -> Nil {
  assert config.unknown(
      dict.from_list([
        #("knarr.io/enabled", "true"),
        #("knarr.io/status-port", "9000"),
      ]),
      dict.new(),
    )
    == ["label knarr.io/status-port"]
}

// Configuration.Unknown: an annotation under the prefix other than the six
// overrides and knarr.io/safe-to-evict is reported as an annotation, the
// opt-in key included.
pub fn unknown_reports_an_annotation_under_the_prefix_test() -> Nil {
  assert config.unknown(
      dict.new(),
      dict.from_list([
        #("knarr.io/enabled", "true"),
        #("knarr.io/status_port", "9000"),
      ]),
    )
    == ["annotation knarr.io/enabled", "annotation knarr.io/status_port"]
}

// Configuration.Unknown: a key outside the prefix is not reported.
pub fn unknown_ignores_keys_outside_the_prefix_test() -> Nil {
  assert config.unknown(
      dict.from_list([#("app", "worker"), #("knarr.io/enabled", "true")]),
      dict.from_list([
        #("deployment.kubernetes.io/revision", "3"),
        #("knarr.iox/thresholds", "1"),
        #("xknarr.io/thresholds", "1"),
      ]),
    )
    == []
}

// Configuration.Unknown: the known keys are not reported.
pub fn unknown_ignores_the_known_keys_test() -> Nil {
  assert config.unknown(
      dict.from_list([#("knarr.io/enabled", "true")]),
      dict.from_list([
        #("knarr.io/status-port", "x"),
        #("knarr.io/status-path", "x"),
        #("knarr.io/thresholds", "x"),
        #("knarr.io/threshold-margin", "x"),
        #("knarr.io/poll-interval", "x"),
        #("knarr.io/patch-interval", "x"),
        #("knarr.io/safe-to-evict", "x"),
      ]),
    )
    == []
}

// Configuration.Unknown: labels first, then annotations, each group in
// lexicographic key order.
pub fn unknown_orders_labels_then_annotations_lexicographically_test() -> Nil {
  assert config.unknown(
      dict.from_list([#("knarr.io/z", ""), #("knarr.io/a", "")]),
      dict.from_list([#("knarr.io/b", ""), #("knarr.io/Z", "")]),
    )
    == [
      "label knarr.io/a",
      "label knarr.io/z",
      "annotation knarr.io/Z",
      "annotation knarr.io/b",
    ]
}

// ------------------------------------------------------------- Discovery ---

// Configuration.Discovery: a pod of a ReplicaSet of a listed, opted-in
// Deployment is a Target carrying parse of the Deployment's annotations.
pub fn targets_follows_the_owner_chain_by_uid_test() -> Nil {
  let deployments = [
    Deployment(
      name: "worker",
      uid: "d1",
      labels: dict.from_list(opted_in_labels),
      annotations: dict.from_list([#("knarr.io/poll-interval", "15")]),
    ),
  ]
  let replica_sets = [
    replica_set(
      name: "worker-abc",
      uid: "r1",
      deployment: Some(#("worker", "d1")),
    ),
  ]
  let pods = [pod("worker-abc-1", Some(#("worker-abc", "r1")))]

  assert config.targets(deployments:, replica_sets:, pods:, defaults:)
    == [
      Target(
        pod_name: "worker-abc-1",
        deployment_name: "worker",
        deployment_uid: "d1",
        settings: Settings(..settings, poll_interval: 15),
      ),
    ]
}

// Configuration.Discovery: Targets come in the order of pods.
pub fn targets_keeps_the_order_of_pods_test() -> Nil {
  let deployments = [
    deployment(name: "a", uid: "da", labels: opted_in_labels),
    deployment(name: "b", uid: "db", labels: opted_in_labels),
  ]
  let replica_sets = [
    replica_set(name: "a-1", uid: "ra", deployment: Some(#("a", "da"))),
    replica_set(name: "b-1", uid: "rb", deployment: Some(#("b", "db"))),
  ]
  let pods = [
    pod("b-1-x", Some(#("b-1", "rb"))),
    pod("a-1-x", Some(#("a-1", "ra"))),
    pod("b-1-y", Some(#("b-1", "rb"))),
  ]

  assert config.targets(deployments:, replica_sets:, pods:, defaults:)
    == [
      target("b-1-x", #("b", "db")),
      target("a-1-x", #("a", "da")),
      target("b-1-y", #("b", "db")),
    ]
}

// Configuration.Discovery: a pod of a ReplicaSet with no controller owner
// is not a target.
pub fn targets_skips_a_pod_of_an_orphan_replica_set_test() -> Nil {
  let deployments = [
    deployment(name: "worker", uid: "d1", labels: opted_in_labels),
  ]
  let replica_sets = [replica_set(name: "orphan", uid: "r1", deployment: None)]
  let pods = [pod("orphan-1", Some(#("orphan", "r1")))]

  assert config.targets(deployments:, replica_sets:, pods:, defaults:) == []
}

// Configuration.Discovery: a bare pod is not a target.
pub fn targets_skips_a_bare_pod_test() -> Nil {
  let deployments = [
    deployment(name: "worker", uid: "d1", labels: opted_in_labels),
  ]
  let replica_sets = [
    replica_set(
      name: "worker-abc",
      uid: "r1",
      deployment: Some(#("worker", "d1")),
    ),
  ]
  let pods = [pod("bare", None)]

  assert config.targets(deployments:, replica_sets:, pods:, defaults:) == []
}

// Configuration.Discovery: a pod of a ReplicaSet owned by a Deployment that
// is not listed is not a target.
pub fn targets_skips_a_pod_of_an_unlisted_deployment_test() -> Nil {
  let deployments = [
    deployment(name: "worker", uid: "d1", labels: opted_in_labels),
  ]
  let replica_sets = [
    replica_set(
      name: "other-abc",
      uid: "r2",
      deployment: Some(#("other", "d2")),
    ),
  ]
  let pods = [pod("other-abc-1", Some(#("other-abc", "r2")))]

  assert config.targets(deployments:, replica_sets:, pods:, defaults:) == []
}

// Configuration.Discovery: a pod whose owner uid names no listed ReplicaSet,
// another owner kind among them, is not a target.
pub fn targets_skips_a_pod_of_an_unlisted_or_other_owner_test() -> Nil {
  let deployments = [
    deployment(name: "worker", uid: "d1", labels: opted_in_labels),
  ]
  let replica_sets = [
    replica_set(
      name: "worker-abc",
      uid: "r1",
      deployment: Some(#("worker", "d1")),
    ),
  ]
  let pods = [
    pod("worker-abc-1", Some(#("worker-abc", "r9"))),
    Pod(
      ..pod("job-1", None),
      owner: Some(Owner(kind: "Job", name: "job", uid: "j1")),
    ),
  ]

  assert config.targets(deployments:, replica_sets:, pods:, defaults:) == []
}

// Configuration.Discovery: the match is by uid and never by name, so a
// Deployment recreated under the same name claims no pod of the old one.
pub fn targets_matches_by_uid_not_name_test() -> Nil {
  let deployments = [
    deployment(name: "worker", uid: "d-new", labels: opted_in_labels),
  ]
  let replica_sets = [
    replica_set(
      name: "worker-old",
      uid: "r-old",
      deployment: Some(#("worker", "d-old")),
    ),
    replica_set(
      name: "worker-new",
      uid: "r-new",
      deployment: Some(#("worker", "d-new")),
    ),
  ]
  let pods = [
    pod("worker-old-1", Some(#("worker-old", "r-old"))),
    pod("worker-new-1", Some(#("worker-new", "r-new"))),
  ]

  assert config.targets(deployments:, replica_sets:, pods:, defaults:)
    == [target("worker-new-1", #("worker", "d-new"))]

  let renamed = [
    pod("worker-new-1", Some(#("worker-new", "r-old"))),
  ]

  assert config.targets(deployments:, replica_sets:, pods: renamed, defaults:)
    == []
}

// Configuration.Discovery: during a rollout the pods of the old and the new
// ReplicaSet are both targets.
pub fn targets_follows_every_replica_set_of_a_deployment_test() -> Nil {
  let deployments = [
    deployment(name: "worker", uid: "d1", labels: opted_in_labels),
  ]
  let replica_sets = [
    replica_set(
      name: "worker-old",
      uid: "r-old",
      deployment: Some(#("worker", "d1")),
    ),
    replica_set(
      name: "worker-new",
      uid: "r-new",
      deployment: Some(#("worker", "d1")),
    ),
  ]
  let pods = [
    pod("worker-old-1", Some(#("worker-old", "r-old"))),
    pod("worker-new-1", Some(#("worker-new", "r-new"))),
  ]

  assert config.targets(deployments:, replica_sets:, pods:, defaults:)
    == [
      target("worker-old-1", #("worker", "d1")),
      target("worker-new-1", #("worker", "d1")),
    ]
}

// Configuration.Discovery: a listed Deployment for which opted_in is false
// gives no target, so the selector is never the rule.
pub fn targets_requires_the_opt_in_test() -> Nil {
  let deployments = [
    deployment(name: "worker", uid: "d1", labels: [
      #("knarr.io/enabled", "True"),
    ]),
    deployment(name: "plain", uid: "d2", labels: []),
  ]
  let replica_sets = [
    replica_set(
      name: "worker-abc",
      uid: "r1",
      deployment: Some(#("worker", "d1")),
    ),
    replica_set(
      name: "plain-abc",
      uid: "r2",
      deployment: Some(#("plain", "d2")),
    ),
  ]
  let pods = [
    pod("worker-abc-1", Some(#("worker-abc", "r1"))),
    pod("plain-abc-1", Some(#("plain-abc", "r2"))),
  ]

  assert config.targets(deployments:, replica_sets:, pods:, defaults:) == []
}

// Configuration.Discovery: with no pods, or no Deployments, there is no
// target.
pub fn targets_of_empty_lists_is_empty_test() -> Nil {
  assert config.targets(
      deployments: [
        deployment(name: "worker", uid: "d1", labels: opted_in_labels),
      ],
      replica_sets: [],
      pods: [],
      defaults:,
    )
    == []
  assert config.targets(
      deployments: [],
      replica_sets: [
        replica_set(
          name: "worker-abc",
          uid: "r1",
          deployment: Some(#("worker", "d1")),
        ),
      ],
      pods: [pod("worker-abc-1", Some(#("worker-abc", "r1")))],
      defaults:,
    )
    == []
}

// ----------------------------------------------------- Effective: leaving ---

// Configuration.Effective: across an opt-out, leaving names the pods in
// previous and not in current that the pod LIST still shows, in previous's
// order; a pod that is simply gone is not named.
pub fn leaving_names_the_pods_still_listed_test() -> Nil {
  let previous = [
    target("a", #("worker", "d1")),
    target("b", #("worker", "d1")),
  ]
  let pods = [pod("a", Some(#("worker-abc", "r1")))]

  assert config.leaving(previous:, current: [], pods:) == ["a"]
}

// Configuration.Effective: a pod still in current is not leaving.
pub fn leaving_excludes_the_pods_still_targeted_test() -> Nil {
  let previous = [
    target("c", #("worker", "d1")),
    target("a", #("worker", "d1")),
    target("b", #("worker", "d1")),
  ]
  let current = [target("a", #("worker", "d1"))]
  let pods = [
    pod("a", Some(#("worker-abc", "r1"))),
    pod("b", Some(#("worker-abc", "r1"))),
    pod("c", Some(#("worker-abc", "r1"))),
  ]

  assert config.leaving(previous:, current:, pods:) == ["c", "b"]
}

// Configuration.Effective: on the first cycle previous is empty and leaving
// returns nothing.
pub fn leaving_on_the_first_cycle_is_empty_test() -> Nil {
  let current = [target("a", #("worker", "d1"))]
  let pods = [pod("a", Some(#("worker-abc", "r1")))]

  assert config.leaving(previous: [], current:, pods:) == []
}

// ------------------------------------------------------------- Installed ---

/// The record the defaults give.
const installed_at_defaults =
  Installed(
    defaults: defaults,
    max_body_bytes: 4096,
    unknown_polls: 3,
    absent_after: 300,
    list_interval: 60,
    poll_concurrency: 64,
    log_level: observability.Info,
  )

// Configuration.Installed: every default is accepted and read into the
// record.
pub fn installed_accepts_every_default_test() -> Nil {
  assert config.installed(installed_defaults()) == Ok(installed_at_defaults)
}

// Configuration.Installed: each log level is read.
pub fn installed_reads_each_log_level_test() -> Nil {
  assert config.installed(with("log_level", dynamic.string("debug")))
    == Ok(Installed(..installed_at_defaults, log_level: observability.Debug))
  assert config.installed(with("log_level", dynamic.string("warning")))
    == Ok(Installed(..installed_at_defaults, log_level: observability.Warning))
  assert config.installed(with("log_level", dynamic.string("error")))
    == Ok(Installed(..installed_at_defaults, log_level: observability.Error))
}

// Configuration.Installed: a value outside its range is refused, naming the
// key.
pub fn installed_refuses_a_value_outside_its_range_test() -> Nil {
  assert config.installed(with("unknown_polls", dynamic.int(0)))
    == Error(InstalledError(key: "unknown_polls", reason: "outside 1 to 100"))
  assert config.installed(with("status_port", dynamic.int(65_536)))
    == Error(InstalledError(key: "status_port", reason: "outside 1 to 65535"))
  assert config.installed(with("max_body_bytes", dynamic.int(0)))
    == Error(InstalledError(key: "max_body_bytes", reason: "below 1"))
  assert config.installed(with("threshold_margin", dynamic.int(-1)))
    == Error(InstalledError(key: "threshold_margin", reason: "below 0"))
  assert config.installed(with("threshold_margin", dynamic.int(300)))
    == Error(InstalledError(
      key: "threshold_margin",
      reason: "not below the first threshold",
    ))
  assert config.installed(with("absent_after", dynamic.int(29)))
    == Error(InstalledError(key: "absent_after", reason: "outside 30 to 3600"))
  assert config.installed(with("poll_interval", dynamic.int(301)))
    == Error(InstalledError(key: "poll_interval", reason: "outside 5 to 300"))
  assert config.installed(with("patch_interval", dynamic.int(3601)))
    == Error(InstalledError(key: "patch_interval", reason: "outside 0 to 3600"))
  assert config.installed(with("list_interval", dynamic.int(9)))
    == Error(InstalledError(key: "list_interval", reason: "outside 10 to 600"))
  assert config.installed(with("poll_concurrency", dynamic.int(1025)))
    == Error(InstalledError(
      key: "poll_concurrency",
      reason: "outside 1 to 1024",
    ))
  assert config.installed(with("status_path", dynamic.string("status")))
    == Error(InstalledError(key: "status_path", reason: "not absolute"))
}

// Configuration.Installed: poll_timeout is 1 to poll_interval less one, so a
// timeout equal to the interval is refused, naming poll_timeout.
pub fn installed_refuses_a_poll_timeout_not_below_the_poll_interval_test() -> Nil {
  assert config.installed(with("poll_timeout", dynamic.int(30)))
    == Error(InstalledError(
      key: "poll_timeout",
      reason: "not below the poll interval",
    ))
  assert config.installed(with("poll_timeout", dynamic.int(0)))
    == Error(InstalledError(key: "poll_timeout", reason: "below 1"))
  assert config.installed(with("poll_timeout", dynamic.int(29)))
    == Ok(
      Installed(
        ..installed_at_defaults,
        defaults: Defaults(..defaults, poll_timeout: 29),
      ),
    )
}

// Configuration.Installed: a log level outside the four is refused.
pub fn installed_refuses_an_unknown_log_level_test() -> Nil {
  assert config.installed(with("log_level", dynamic.string("verbose")))
    == Error(InstalledError(key: "log_level", reason: "not a level"))
}

// Configuration.Installed: a value not of its key's type is refused.
pub fn installed_refuses_a_value_of_the_wrong_type_test() -> Nil {
  assert config.installed(with("status_path", dynamic.int(1)))
    == Error(InstalledError(key: "status_path", reason: "not a string"))
  assert config.installed(with("status_port", dynamic.string("8080")))
    == Error(InstalledError(key: "status_port", reason: "not an integer"))
  assert config.installed(with("thresholds", dynamic.int(300)))
    == Error(InstalledError(key: "thresholds", reason: "not a list of integers"))
  assert config.installed(with("log_level", dynamic.int(1)))
    == Error(InstalledError(key: "log_level", reason: "not a string"))
}

// Configuration.Installed: a missing key is refused, naming it.
pub fn installed_refuses_a_missing_key_test() -> Nil {
  assert config.installed(without("absent_after"))
    == Error(InstalledError(key: "absent_after", reason: "missing"))
  assert config.installed([])
    == Error(InstalledError(key: "status_port", reason: "missing"))
}

// Configuration.Installed: thresholds must be strictly increasing positive
// integers up to 2147483647 with at least one member.
pub fn installed_refuses_bad_thresholds_test() -> Nil {
  let thresholds = fn(members) {
    with("thresholds", dynamic.list(list.map(members, dynamic.int)))
  }

  assert config.installed(thresholds([300, 300, 900]))
    == Error(InstalledError(
      key: "thresholds",
      reason: "not strictly increasing",
    ))
  assert config.installed(thresholds([900, 300]))
    == Error(InstalledError(
      key: "thresholds",
      reason: "not strictly increasing",
    ))
  assert config.installed(thresholds([]))
    == Error(InstalledError(key: "thresholds", reason: "empty"))
  assert config.installed(thresholds([0, 300]))
    == Error(InstalledError(key: "thresholds", reason: "member not positive"))
  assert config.installed(thresholds([2_147_483_648]))
    == Error(InstalledError(
      key: "thresholds",
      reason: "member above 2147483647",
    ))
  assert config.installed(thresholds([2_147_483_647]))
    == Ok(
      Installed(
        ..installed_at_defaults,
        defaults: Defaults(..defaults, thresholds: [2_147_483_647]),
      ),
    )
}

// Configuration.Installed: the first key refused, in the fixed order, is the
// error.
pub fn installed_names_the_first_refused_key_in_order_test() -> Nil {
  let values =
    installed_defaults()
    |> list.map(fn(pair) {
      case pair.0 {
        "log_level" -> #("log_level", dynamic.string("verbose"))
        "poll_concurrency" -> #("poll_concurrency", dynamic.int(0))
        _ -> pair
      }
    })

  assert config.installed(values)
    == Error(InstalledError(
      key: "poll_concurrency",
      reason: "outside 1 to 1024",
    ))
  assert config.installed(list.reverse(values))
    == Error(InstalledError(
      key: "poll_concurrency",
      reason: "outside 1 to 1024",
    ))
}

// ------------------------------------------------------------------ Pure ---

// Configuration.Pure: every function is a function of its arguments alone,
// so repeated application gives the same value.
pub fn every_function_is_pure_by_repeated_application_test() -> Nil {
  let annotations =
    dict.from_list([
      #("knarr.io/thresholds", "50,900"),
      #("knarr.io/poll-interval", "x"),
    ])
  let labels = dict.from_list([#("knarr.io/enabled", "true")])

  assert config.parse(annotations, defaults)
    == config.parse(annotations, defaults)
  assert config.invalid(annotations, defaults)
    == config.invalid(annotations, defaults)
  assert config.unknown(labels, annotations)
    == config.unknown(labels, annotations)
  assert config.opted_in(labels) == config.opted_in(labels)
  assert config.installed(installed_defaults())
    == config.installed(installed_defaults())
}

// ----------------------------------------------------------- Obligations ---

// value-equality.Label and entity-fields.Label: a label is one pair of the
// labels dict k8s_client reads, a key and a value, compared by value.
pub fn label_is_a_key_and_a_value_test() -> Nil {
  let label: #(String, String) = #("knarr.io/enabled", "true")
  let labels: Dict(String, String) = dict.from_list([label])

  assert label.0 == "knarr.io/enabled"
  assert label.1 == "true"
  assert label == #("knarr.io/enabled", "true")
  assert label != #("knarr.io/enabled", "True")
  assert dict.to_list(labels) == [#("knarr.io/enabled", "true")]
  assert config.opted_in(labels)
}

// value-equality.Annotation and entity-fields.Annotation: an annotation is
// one pair of the annotations dict k8s_client reads, compared by value.
pub fn annotation_is_a_key_and_a_value_test() -> Nil {
  let annotation: #(String, String) = #("knarr.io/status-port", "9000")

  assert annotation.0 == "knarr.io/status-port"
  assert annotation.1 == "9000"
  assert annotation == #("knarr.io/status-port", "9000")
  assert annotation != #("knarr.io/status-port", "9001")
  assert config.parse(dict.from_list([annotation]), defaults).status_port
    == 9000
}

// value-equality.Defaults and entity-fields.Defaults: the seven install-wide
// values, compared by value.
pub fn defaults_is_seven_values_compared_by_value_test() -> Nil {
  assert defaults.status_port == 8080
  assert defaults.status_path == "/knarr/v1/status"
  assert defaults.thresholds == [300, 900, 1800, 3600]
  assert defaults.threshold_margin == 60
  assert defaults.poll_interval == 30
  assert defaults.patch_interval == 60
  assert defaults.poll_timeout == 5
  assert defaults
    == Defaults(
      status_port: 8080,
      status_path: "/knarr/v1/status",
      thresholds: [300, 900, 1800, 3600],
      threshold_margin: 60,
      poll_interval: 30,
      patch_interval: 60,
      poll_timeout: 5,
    )
  assert defaults != Defaults(..defaults, poll_timeout: 6)
}

// value-equality.Settings and entity-fields.Settings: the six effective
// values and safe_to_evict, compared by value.
pub fn settings_is_seven_values_compared_by_value_test() -> Nil {
  assert settings.status_port == 8080
  assert settings.status_path == "/knarr/v1/status"
  assert settings.thresholds == [300, 900, 1800, 3600]
  assert settings.threshold_margin == 60
  assert settings.poll_interval == 30
  assert settings.patch_interval == 60
  assert settings.safe_to_evict == False
  assert settings == parsed([])
  assert settings != Settings(..settings, safe_to_evict: True)
}

// value-equality.Invalid and entity-fields.Invalid: key, value and reason,
// compared by value.
pub fn invalid_is_a_key_a_value_and_a_reason_test() -> Nil {
  let invalid =
    Invalid(
      key: "knarr.io/status-port",
      value: "0",
      reason: "outside 1 to 65535",
    )

  assert invalid.key == "knarr.io/status-port"
  assert invalid.value == "0"
  assert invalid.reason == "outside 1 to 65535"
  assert invalids([#("knarr.io/status-port", "0")]) == [invalid]
  assert invalid != Invalid(..invalid, value: "65536")
}

// value-equality.Deployment and entity-fields.Deployment: name, uid, labels
// and annotations, as k8s_client's value carries them, compared by value; an
// absent annotations map is the empty dict.
pub fn deployment_is_a_name_uid_labels_and_annotations_test() -> Nil {
  let built =
    Deployment(
      name: "worker",
      uid: "d1",
      labels: dict.from_list([#("knarr.io/enabled", "true")]),
      annotations: dict.new(),
    )

  assert built.name == "worker"
  assert built.uid == "d1"
  assert dict.to_list(built.labels) == [#("knarr.io/enabled", "true")]
  assert dict.to_list(built.annotations) == []
  assert built == deployment(name: "worker", uid: "d1", labels: opted_in_labels)
  assert built != Deployment(..built, uid: "d2")
  assert config.parse(built.annotations, defaults) == settings
}

// value-equality.ReplicaSet and entity-fields.ReplicaSet: uid and the
// controller owner's uid, None when it has none, as k8s_client's value
// carries them, compared by value.
pub fn replica_set_is_a_uid_and_a_controller_uid_test() -> Nil {
  let built =
    ReplicaSet(
      name: "worker-abc",
      uid: "r1",
      owner: Some(Owner(kind: "Deployment", name: "worker", uid: "d1")),
    )
  let controller_uid = fn(replica_set: k8s_client.ReplicaSet) {
    option.map(replica_set.owner, fn(owner) { owner.uid })
  }

  assert built.uid == "r1"
  assert controller_uid(built) == Some("d1")
  assert controller_uid(replica_set(name: "orphan", uid: "r2", deployment: None))
    == None
  assert built
    == replica_set(
      name: "worker-abc",
      uid: "r1",
      deployment: Some(#("worker", "d1")),
    )
  assert built != ReplicaSet(..built, owner: None)
}

// value-equality.Pod and entity-fields.Pod: name and the controller owner's
// uid, None when it has none, as k8s_client's value carries them, compared
// by value.
pub fn pod_is_a_name_and_a_controller_uid_test() -> Nil {
  let built = pod("worker-abc-1", Some(#("worker-abc", "r1")))
  let controller_uid = fn(pod: k8s_client.Pod) {
    option.map(pod.owner, fn(owner) { owner.uid })
  }

  assert built.name == "worker-abc-1"
  assert controller_uid(built) == Some("r1")
  assert controller_uid(pod("bare", None)) == None
  assert built == pod("worker-abc-1", Some(#("worker-abc", "r1")))
  assert built != Pod(..built, owner: None)
}

// value-equality.Target and entity-fields.Target: pod_name, deployment_name,
// deployment_uid and settings, compared by value.
pub fn target_is_a_pod_a_deployment_and_its_settings_test() -> Nil {
  let built = target("worker-abc-1", #("worker", "d1"))

  assert built.pod_name == "worker-abc-1"
  assert built.deployment_name == "worker"
  assert built.deployment_uid == "d1"
  assert built.settings == settings
  assert built
    == Target(
      pod_name: "worker-abc-1",
      deployment_name: "worker",
      deployment_uid: "d1",
      settings:,
    )
  assert built != Target(..built, deployment_uid: "d2")
}
// contract-signature.Configuration.opted_in: (labels) -> Boolean. The OptIn
// tests above discharge it.

// contract-signature.Configuration.parse: (annotations, defaults) ->
// Settings. The Effective, Keys and Syntax tests above discharge it.

// contract-signature.Configuration.invalid: (annotations, defaults) ->
// List<Invalid>. The InvalidValue tests above discharge it.

// contract-signature.Configuration.unknown: (labels, annotations) ->
// List<String>. The Unknown tests above discharge it.

// contract-signature.Configuration.message: (invalid) -> String. The
// message tests above discharge it.

// contract-signature.Configuration.targets: (deployments, replicasets,
// pods, defaults) -> List<Target>. The Discovery tests above discharge it.

// contract-signature.Configuration.leaving: (previous, current, pods) ->
// List<String>. The leaving tests above discharge it.
