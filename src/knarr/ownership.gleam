//// The Ownership contract (docs/specs/ownership.allium): the marker that
//// records what knarr applied, where each owned annotation stands, the JSON
//// Patch write mode with its preconditions, the yield by which another
//// writer wins, and the Event it raises. Every function is pure: `at` is
//// passed in, nothing reads a clock, the pod or state, and nothing sends.
//// The pod's annotations arrive as k8s_client reads them: `None` for a pod
//// whose response carries no annotations map.

import gleam/bit_array
import gleam/bool
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// The marker annotation (Recorded), under config's fixed prefix.
pub const marker_key = "knarr.io/applied"

/// An annotation knarr owns: its short name, which names its member in the
/// marker, and the full key it is written under. Exactly two exist.
pub type Owned {
  Owned(name: String, key: String)
}

/// The owned annotation Deployment scale-down reads (Recorded).
pub const pod_deletion_cost =
  Owned(
    name: "pod-deletion-cost",
    key: "controller.kubernetes.io/pod-deletion-cost",
  )

/// The owned annotation the cluster autoscaler reads (Recorded).
pub const safe_to_evict =
  Owned(
    name: "safe-to-evict",
    key: "cluster-autoscaler.kubernetes.io/safe-to-evict",
  )

/// What the marker records for one owned annotation: applied, with the value
/// knarr last wrote (`None` for a removal), or yielded, with the value knarr
/// found when it gave the annotation up (`None` for an absent one). `at` is
/// the RFC 3339 UTC time, to the second, of the write that made the record.
pub type Record {
  AppliedRecord(value: Option(String), at: String)
  YieldedRecord(value: Option(String), at: String)
}

/// One member of the marker: the owned annotation and its record (Recorded).
pub type Entry {
  Entry(owned: Owned, record: Record)
}

/// knarr's marker as read from the pod: the raw string (`None` when absent),
/// the time of knarr's last write (`None` when absent or unusable) and one
/// entry per owned annotation knarr has written (none when unusable).
pub type Marker {
  Marker(raw: Option(String), at: Option(String), entries: List(Entry))
}

/// Where one owned annotation on one pod stands with respect to knarr
/// (Adoption). `OwnedByKnarr` is the spec's `owned`.
pub type Standing {
  Unowned
  OwnedByKnarr
  Conflict
  Yielded
  Foreign
}

/// A write knarr wants to make: the string, or `None` to remove.
pub type Write {
  Write(owned: Owned, value: Option(String))
}

/// The JSON Patch operations WriteMode uses: test, add and remove.
pub type Op {
  Test
  Add
  Remove
}

/// One JSON Patch operation. `path` is the JSON Pointer; `value` is the JSON
/// text of the operand and `None` for a remove: "null" for a test of
/// absence, the quoted and escaped string for an annotation, and for the
/// marker its rendered object as one escaped JSON string.
pub type Operation {
  Operation(op: Op, path: String, value: Option(String))
}

/// The content of the Event a yield raises, on the Pod.
pub type ConflictEvent {
  ConflictEvent(
    pod_name: String,
    pod_uid: String,
    owned: Owned,
    applied: Option(String),
    found: Option(String),
  )
}

const deletion_timestamp_path = "/metadata/deletionTimestamp"

const annotations_path = "/metadata/annotations"

const null = "null"

/// The two owned annotations, which are the known marker members.
const owned_annotations = [pod_deletion_cost, safe_to_evict]

/// Reads the marker (Recorded): `raw` as found, and no entries and no `at`
/// for a string that is not usable or that differs from `render` of what it
/// reads.
pub fn read(annotations: Option(Dict(String, String))) -> Marker {
  case lookup(annotations, marker_key) {
    None -> Marker(raw: None, at: None, entries: [])
    Some(raw) ->
      case parse(raw) {
        Ok(#(at, entries)) -> {
          let marker = Marker(raw: Some(raw), at: Some(at), entries:)
          case render(marker) == raw {
            True -> marker
            False -> Marker(raw: Some(raw), at: None, entries: [])
          }
        }
        Error(Nil) -> Marker(raw: Some(raw), at: None, entries: [])
      }
  }
}

/// The at and the entries, in name order, of a usable string.
fn parse(raw: String) -> Result(#(String, List(Entry)), Nil) {
  use members <- result.try(
    json.parse(raw, decode.dict(decode.string, decode.dynamic))
    |> result.replace_error(Nil),
  )
  use at <- result.try(time(dict.get(members, "at")))
  let rest = dict.delete(members, "at")
  let known =
    list.filter_map(owned_annotations, fn(owned) {
      dict.get(rest, owned.name) |> result.map(fn(member) { #(owned, member) })
    })
  use entries <- result.try(
    list.try_map(known, fn(pair) {
      member_record(pair.1) |> result.map(Entry(pair.0, _))
    }),
  )
  case dict.size(rest) == list.length(entries) {
    True -> Ok(#(at, entries))
    False -> Error(Nil)
  }
}

/// The record one known member holds: exactly one of applied or yielded, a
/// string or null, and an at that parses.
fn member_record(member: Dynamic) -> Result(Record, Nil) {
  use fields <- result.try(
    decode.run(member, decode.dict(decode.string, decode.dynamic))
    |> result.replace_error(Nil),
  )
  use at <- result.try(time(dict.get(fields, "at")))
  let value = fn(name) {
    dict.get(fields, name)
    |> result.try(fn(field) {
      decode.run(field, decode.optional(decode.string))
      |> result.replace_error(Nil)
    })
  }
  case dict.size(fields), value("applied"), value("yielded") {
    2, Ok(applied), Error(Nil) -> Ok(AppliedRecord(applied, at))
    2, Error(Nil), Ok(yielded) -> Ok(YieldedRecord(yielded, at))
    _, _, _ -> Error(Nil)
  }
}

/// A time member that is a string of the form YYYY-MM-DDTHH:MM:SSZ with
/// every field in range.
fn time(member: Result(Dynamic, Nil)) -> Result(String, Nil) {
  use field <- result.try(member)
  use text <- result.try(
    decode.run(field, decode.string) |> result.replace_error(Nil),
  )
  case valid_time(text) {
    True -> Ok(text)
    False -> Error(Nil)
  }
}

fn valid_time(text: String) -> Bool {
  case bit_array.from_string(text) {
    <<
      year:bytes-size(4),
      "-":utf8,
      month:bytes-size(2),
      "-":utf8,
      day:bytes-size(2),
      "T":utf8,
      hour:bytes-size(2),
      ":":utf8,
      minute:bytes-size(2),
      ":":utf8,
      second:bytes-size(2),
      "Z":utf8,
    >> ->
      in_range(digits: year, low: 0, high: 9999)
      && in_range(digits: month, low: 1, high: 12)
      && in_range(digits: day, low: 1, high: 31)
      && in_range(digits: hour, low: 0, high: 23)
      && in_range(digits: minute, low: 0, high: 59)
      && in_range(digits: second, low: 0, high: 59)
    _ -> False
  }
}

/// True when every byte is an ASCII digit and the number they spell lies in
/// the range. `int.parse` alone would take a sign.
fn in_range(digits digits: BitArray, low low: Int, high high: Int) -> Bool {
  use <- bool.guard(!all_digits(digits), False)
  bit_array.to_string(digits)
  |> result.try(int.parse)
  |> result.map(fn(number) { number >= low && number <= high })
  |> result.unwrap(False)
}

fn all_digits(bytes: BitArray) -> Bool {
  case bytes {
    <<>> -> True
    <<byte, rest:bytes>> if byte >= 48 && byte <= 57 -> all_digits(rest)
    _ -> False
  }
}

/// The canonical marker string: members in lexicographic order at every
/// level, no whitespace (Recorded).
pub fn render(marker: Marker) -> String {
  let at = case marker.at {
    Some(at) -> [#("at", json.string(at))]
    None -> []
  }
  let entries =
    marker.entries
    |> list.map(fn(entry) { #(entry.owned.name, record_json(entry.record)) })
  json.to_string(sorted_object(list.append(at, entries)))
}

fn record_json(record: Record) -> Json {
  case record {
    AppliedRecord(value:, at:) ->
      sorted_object([
        #("applied", json.nullable(value, json.string)),
        #("at", json.string(at)),
      ])
    YieldedRecord(value:, at:) ->
      sorted_object([
        #("at", json.string(at)),
        #("yielded", json.nullable(value, json.string)),
      ])
  }
}

fn sorted_object(members: List(#(String, Json))) -> Json {
  members
  |> list.sort(fn(left, right) { string.compare(left.0, right.0) })
  |> json.object
}

/// The entry the marker holds for `owned`, if any.
pub fn record(marker marker: Marker, owned owned: Owned) -> Option(Record) {
  marker.entries
  |> list.find(fn(entry) { entry.owned == owned })
  |> result.map(fn(entry) { entry.record })
  |> option.from_result
}

/// Where `owned` stands on the view given (Adoption). The parse of an
/// applied record as its annotation's value is reconcile's; this reads the
/// annotation's text against the record only.
pub fn standing(
  marker marker: Marker,
  annotations annotations: Option(Dict(String, String)),
  owned owned: Owned,
) -> Standing {
  case record(marker:, owned:), lookup(annotations, owned.key) {
    None, None -> Unowned
    None, Some(_) -> Foreign
    Some(YieldedRecord(..)), _ -> Yielded
    Some(AppliedRecord(value:, ..)), found if value == found -> OwnedByKnarr
    Some(AppliedRecord(..)), _ -> Conflict
  }
}

/// True for `Unowned` and `OwnedByKnarr` only.
pub fn may_write(standing: Standing) -> Bool {
  case standing {
    Unowned | OwnedByKnarr -> True
    Conflict | Yielded | Foreign -> False
  }
}

/// The operations of one write patch (WriteMode): a write of `None` for an
/// annotation whose record is `None` or missing is dropped, and no writes
/// left gives no operations. The caller passes only writes `may_write`
/// allows.
pub fn patch(
  marker marker: Marker,
  annotations annotations: Option(Dict(String, String)),
  writes writes: List(Write),
  at at: String,
) -> List(Operation) {
  let writes =
    list.filter(writes, fn(write) {
      case write.value, applied_value(marker:, owned: write.owned) {
        None, None -> False
        _, _ -> True
      }
    })
  case writes {
    [] -> []
    _ -> {
      let entries =
        list.map(writes, fn(write) {
          Entry(write.owned, AppliedRecord(write.value, at))
        })
      let rendered = render(with_entries(marker:, entries:, at:))
      case annotations {
        None -> add_map(write_members(writes), rendered)
        Some(_) ->
          list.flatten([
            [deletion_timestamp_test(), marker_test(marker)],
            list.map(writes, write_test(marker, _)),
            list.map(writes, write_change),
            [Operation(Add, pointer(marker_key), Some(quote(rendered)))],
          ])
      }
    }
  }
}

/// The members of the map a first write adds: each write's key and string.
fn write_members(writes: List(Write)) -> List(#(String, String)) {
  list.filter_map(writes, fn(write) {
    case write.value {
      Some(value) -> Ok(#(write.owned.key, value))
      None -> Error(Nil)
    }
  })
}

/// The test that the owned annotation equals the applied record's value, or
/// is null when the record is null or missing.
fn write_test(marker: Marker, write: Write) -> Operation {
  Operation(
    Test,
    pointer(write.owned.key),
    Some(nullable(applied_value(marker:, owned: write.owned))),
  )
}

/// The add of the string, or the remove for null.
fn write_change(write: Write) -> Operation {
  case write.value {
    Some(value) -> Operation(Add, pointer(write.owned.key), Some(quote(value)))
    None -> Operation(Remove, pointer(write.owned.key), None)
  }
}

/// The operations of a yield patch, which rewrites only the marker (Yield).
pub fn yield(
  marker marker: Marker,
  annotations annotations: Option(Dict(String, String)),
  owned owned: Owned,
  at at: String,
) -> List(Operation) {
  let found = lookup(annotations, owned.key)
  let rendered =
    render(with_entries(
      marker:,
      entries: [Entry(owned, YieldedRecord(found, at))],
      at:,
    ))
  case annotations {
    None -> add_map([], rendered)
    Some(_) -> [
      deletion_timestamp_test(),
      marker_test(marker),
      Operation(Test, pointer(owned.key), Some(nullable(found))),
      Operation(Add, pointer(marker_key), Some(quote(rendered))),
    ]
  }
}

/// The marker after a write: every other entry kept, the new entries
/// recorded, and `at` set to the write's time.
fn with_entries(
  marker marker: Marker,
  entries entries: List(Entry),
  at at: String,
) -> Marker {
  let written = list.map(entries, fn(entry) { entry.owned })
  let kept =
    list.filter(marker.entries, fn(entry) {
      !list.contains(written, entry.owned)
    })
  Marker(..marker, at: Some(at), entries: list.append(kept, entries))
}

/// The value of the applied record for `owned`: `None` for a null record, a
/// yielded record or no record.
pub fn applied_value(
  marker marker: Marker,
  owned owned: Owned,
) -> Option(String) {
  case record(marker:, owned:) {
    Some(AppliedRecord(value:, ..)) -> value
    _ -> None
  }
}

/// The full annotation keys a document writes or removes, in its order,
/// tests excluded: the key each pointer under the map names, and for the
/// first write's one add of the whole map, the map's members (observability
/// Logs Lines, the `keys` field of a patch line).
pub fn keys(operations: List(Operation)) -> List(String) {
  list.flat_map(operations, fn(operation) {
    case operation.op, operation.path == annotations_path, operation.value {
      Test, _, _ -> []
      Add, True, Some(text) ->
        json.parse(text, decode.dict(decode.string, decode.dynamic))
        |> result.map(dict.keys)
        |> result.unwrap([])
        |> list.sort(string.compare)
      _, _, _ ->
        pointed_key(operation.path)
        |> result.map(fn(key) { [key] })
        |> result.unwrap([])
    }
  })
}

/// The null-map branch: after the deletionTimestamp test, a test that the
/// map is null and one add of the map holding the members and the marker.
fn add_map(
  members: List(#(String, String)),
  rendered: String,
) -> List(Operation) {
  let map =
    [#(marker_key, rendered), ..members]
    |> list.map(fn(member) { #(member.0, json.string(member.1)) })
    |> sorted_object
  [
    deletion_timestamp_test(),
    Operation(Test, annotations_path, Some(null)),
    Operation(Add, annotations_path, Some(json.to_string(map))),
  ]
}

fn deletion_timestamp_test() -> Operation {
  Operation(Test, deletion_timestamp_path, Some(null))
}

/// The test that the marker annotation equals its raw string, or is null
/// when the marker is absent.
fn marker_test(marker: Marker) -> Operation {
  Operation(Test, pointer(marker_key), Some(nullable(marker.raw)))
}

/// The JSON text of a string or of null.
fn nullable(value: Option(String)) -> String {
  case value {
    Some(value) -> quote(value)
    None -> null
  }
}

fn quote(value: String) -> String {
  json.to_string(json.string(value))
}

/// The JSON Pointer of an annotation: its key as one segment, ~ as ~0 then
/// / as ~1.
fn pointer(key: String) -> String {
  let segment =
    key
    |> string.replace("~", "~0")
    |> string.replace("/", "~1")
  annotations_path <> "/" <> segment
}

/// The annotation key a pointer under /metadata/annotations names, or
/// nothing for a deeper or an unrelated path.
fn pointed_key(path: String) -> Result(String, Nil) {
  case string.split_once(path, annotations_path <> "/") {
    Ok(#("", segment)) ->
      case string.contains(segment, "/") {
        True -> Error(Nil)
        False ->
          Ok(
            segment
            |> string.replace("~1", "/")
            |> string.replace("~0", "~"),
          )
      }
    _ -> Error(Nil)
  }
}

/// The operations as the JSON Patch body the client sends (WriteMode).
pub fn document(operations: List(Operation)) -> String {
  let members = fn(operation: Operation) {
    let op = case operation.op {
      Test -> "test"
      Add -> "add"
      Remove -> "remove"
    }
    let value = case operation.value {
      Some(value) -> ",\"value\":" <> value
      None -> ""
    }
    "{\"op\":\""
    <> op
    <> "\",\"path\":"
    <> quote(operation.path)
    <> value
    <> "}"
  }
  "[" <> string.join(list.map(operations, members), ",") <> "]"
}

/// True when every test operation of a failed patch passes against the view
/// given (Rejected).
pub fn rejected(
  operations operations: List(Operation),
  annotations annotations: Option(Dict(String, String)),
  deletion_timestamp deletion_timestamp: Option(String),
) -> Bool {
  list.all(operations, fn(operation) {
    case operation.op {
      Test -> passes(operation:, annotations:, deletion_timestamp:)
      Add | Remove -> True
    }
  })
}

/// Whether one test passes against the view, as evanphx/json-patch applies
/// it: a test of null passes for a key missing under an existing parent and
/// fails under a missing parent (Precondition).
fn passes(
  operation operation: Operation,
  annotations annotations: Option(Dict(String, String)),
  deletion_timestamp deletion_timestamp: Option(String),
) -> Bool {
  let is_null = operation.value == Some(null)
  case operation.path {
    "/metadata/deletionTimestamp" -> is_null && deletion_timestamp == None
    "/metadata/annotations" -> is_null && annotations == None
    path ->
      case pointed_key(path), annotations {
        Ok(key), Some(map) -> passes_on_key(operation:, map:, key:)
        _, _ -> False
      }
  }
}

/// A test of null passes for a key the map lacks; a test of a string passes
/// for a key holding exactly that string.
fn passes_on_key(
  operation operation: Operation,
  map map: Dict(String, String),
  key key: String,
) -> Bool {
  case operation.value {
    Some(value) if value == null -> !dict.has_key(map, key)
    Some(value) ->
      json.parse(value, decode.string)
      |> result.map(fn(expected) { dict.get(map, key) == Ok(expected) })
      |> result.unwrap(False)
    None -> False
  }
}

/// The Event of a yield, built from the view the yield patch was built from
/// (Event).
pub fn event(
  pod_name pod_name: String,
  pod_uid pod_uid: String,
  marker marker: Marker,
  annotations annotations: Option(Dict(String, String)),
  owned owned: Owned,
) -> ConflictEvent {
  ConflictEvent(
    pod_name:,
    pod_uid:,
    owned:,
    applied: applied_value(marker:, owned: owned),
    found: lookup(annotations, owned.key),
  )
}

/// "<key>: knarr applied <applied> and found <found>; another writer owns it
/// now and knarr will not write it again on this pod", with "absent" for
/// `None` (Event).
pub fn message(event: ConflictEvent) -> String {
  event.owned.key
  <> ": knarr applied "
  <> option.unwrap(event.applied, "absent")
  <> " and found "
  <> option.unwrap(event.found, "absent")
  <> "; another writer owns it now and knarr will not write it again on this pod"
}

/// The annotation under `key`, `None` when the map or the key is absent.
fn lookup(
  annotations: Option(Dict(String, String)),
  key: String,
) -> Option(String) {
  annotations
  |> option.then(fn(map) { dict.get(map, key) |> option.from_result })
}
