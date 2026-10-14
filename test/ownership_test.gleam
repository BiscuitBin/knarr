//// Tests for the Ownership contract (docs/specs/ownership.allium): the
//// marker and its canonical form, where an owned annotation stands, the
//// write and yield patches, the patch document, the rejection test and the
//// Event. Every function is pure, so each test passes values in and reads
//// values out. Each test names the clause or plan obligation it traces to.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import knarr/ownership.{
  type Operation, Add, AppliedRecord, Conflict, ConflictEvent, Entry, Foreign,
  Marker, Operation, OwnedByKnarr, Remove, Test, Unowned, Write, Yielded,
  YieldedRecord,
}
import qcheck

const at = "2026-10-13T10:00:00Z"

const earlier = "2026-10-13T09:00:00Z"

const earliest = "2026-10-13T08:00:00Z"

const pdc = ownership.pod_deletion_cost

const ste = ownership.safe_to_evict

const pdc_key = "controller.kubernetes.io/pod-deletion-cost"

const ste_key = "cluster-autoscaler.kubernetes.io/safe-to-evict"

const marker_key = "knarr.io/applied"

const deletion_path = "/metadata/deletionTimestamp"

const annotations_path = "/metadata/annotations"

const marker_path = "/metadata/annotations/knarr.io~1applied"

const pdc_path =
  "/metadata/annotations/controller.kubernetes.io~1pod-deletion-cost"

const ste_path =
  "/metadata/annotations/cluster-autoscaler.kubernetes.io~1safe-to-evict"

const deletion_test = Operation(Test, deletion_path, Some("null"))

const absent_marker_test = Operation(Test, marker_path, Some("null"))

// The canonical marker holding both entries: pod-deletion-cost applied 300
// at `earlier`, safe-to-evict yielded "false" at `earliest`, last write `at`.
const both_raw =
  "{\"at\":\"2026-10-13T10:00:00Z\",\"pod-deletion-cost\":{\"applied\":\"300\",\"at\":\"2026-10-13T09:00:00Z\"},\"safe-to-evict\":{\"at\":\"2026-10-13T08:00:00Z\",\"yielded\":\"false\"}}"

const both_entries = [
  Entry(pdc, AppliedRecord(Some("300"), earlier)),
  Entry(ste, YieldedRecord(Some("false"), earliest)),
]

// The canonical marker after one applied write of 300 at `earlier`, and the
// same string as the JSON string the marker test and the marker add carry.
const applied_300_raw =
  "{\"at\":\"2026-10-13T09:00:00Z\",\"pod-deletion-cost\":{\"applied\":\"300\",\"at\":\"2026-10-13T09:00:00Z\"}}"

const applied_300_quoted =
  "\"{\\\"at\\\":\\\"2026-10-13T09:00:00Z\\\",\\\"pod-deletion-cost\\\":{\\\"applied\\\":\\\"300\\\",\\\"at\\\":\\\"2026-10-13T09:00:00Z\\\"}}\""

const applied_300_marker =
  Marker(
    Some(applied_300_raw),
    Some(earlier),
    [
      Entry(pdc, AppliedRecord(Some("300"), earlier)),
    ],
  )

const absent_marker = Marker(None, None, [])

// A marker another writer edited by hand: raw kept, nothing read.
const unusable_marker = Marker(Some("{\"at\": \"garbage\"}"), None, [])

fn annotations(pairs: List(#(String, String))) -> Option(Dict(String, String)) {
  Some(dict.from_list(pairs))
}

fn ops(operations: List(Operation)) -> List(#(ownership.Op, String)) {
  list.map(operations, fn(operation) { #(operation.op, operation.path) })
}

// -------------------------------------------------------------- Recorded ---

// Ownership.Recorded: render is canonical, members in lexicographic order at
// every level and no whitespace. "at" precedes "pod-deletion-cost" precedes
// "safe-to-evict"; inside, "applied" precedes "at" and "at" precedes
// "yielded".
pub fn render_orders_members_lexicographically_at_every_level_test() -> Nil {
  assert ownership.render(Marker(None, Some(at), both_entries)) == both_raw
}

// Ownership.Recorded: entries may arrive in any order; render sorts them.
pub fn render_sorts_entries_given_out_of_order_test() -> Nil {
  assert ownership.render(Marker(None, Some(at), list.reverse(both_entries)))
    == both_raw
}

// Ownership.Recorded: a null applied record renders as null, and raw plays
// no part in rendering.
pub fn render_writes_a_null_record_as_null_test() -> Nil {
  assert ownership.render(
      Marker(Some("ignored"), Some(at), [Entry(pdc, AppliedRecord(None, at))]),
    )
    == "{\"at\":\"2026-10-13T10:00:00Z\",\"pod-deletion-cost\":{\"applied\":null,\"at\":\"2026-10-13T10:00:00Z\"}}"
}

// Ownership.Recorded: a marker without an at renders no "at" member.
pub fn render_without_an_at_omits_the_member_test() -> Nil {
  assert ownership.render(
      Marker(None, None, [Entry(ste, YieldedRecord(None, at))]),
    )
    == "{\"safe-to-evict\":{\"at\":\"2026-10-13T10:00:00Z\",\"yielded\":null}}"
}

// Ownership.Recorded: quotes and backslashes in a value are escaped.
pub fn render_escapes_a_value_test() -> Nil {
  assert ownership.render(
      Marker(None, Some(at), [Entry(pdc, AppliedRecord(Some("a\"b\\c"), at))]),
    )
    == "{\"at\":\"2026-10-13T10:00:00Z\",\"pod-deletion-cost\":{\"applied\":\"a\\\"b\\\\c\",\"at\":\"2026-10-13T10:00:00Z\"}}"
}

// Ownership.Recorded: read of the canonical string gives raw as found, the
// top-level at and one entry per member, in name order.
pub fn read_of_the_canonical_string_round_trips_test() -> Nil {
  assert ownership.read(
      annotations([#(marker_key, both_raw), #(pdc_key, "300")]),
    )
    == Marker(Some(both_raw), Some(at), both_entries)
}

// Ownership.Recorded: a null applied record reads as None.
pub fn read_of_a_null_record_gives_none_test() -> Nil {
  let raw =
    "{\"at\":\"2026-10-13T10:00:00Z\",\"pod-deletion-cost\":{\"applied\":null,\"at\":\"2026-10-13T09:00:00Z\"}}"

  assert ownership.read(annotations([#(marker_key, raw)]))
    == Marker(Some(raw), Some(at), [Entry(pdc, AppliedRecord(None, earlier))])
}

// Ownership.Recorded: a marker holding only the top-level at reads as no
// entries, with its at.
pub fn read_of_an_entryless_marker_gives_its_at_test() -> Nil {
  let raw = "{\"at\":\"2026-10-13T10:00:00Z\"}"

  assert ownership.read(annotations([#(marker_key, raw)]))
    == Marker(Some(raw), Some(at), [])
}

// Ownership.Recorded: a pod with no annotations map has no marker.
pub fn read_of_a_pod_without_a_map_is_the_absent_marker_test() -> Nil {
  assert ownership.read(None) == absent_marker
}

// Ownership.Recorded: a map without the marker annotation has no marker.
pub fn read_of_a_map_without_the_marker_is_the_absent_marker_test() -> Nil {
  assert ownership.read(annotations([#(pdc_key, "300"), #("app", "worker")]))
    == absent_marker
}

// Ownership.Recorded: a string that keeps the shape but not the canonical
// form, whitespace or members out of order, reads as raw kept, no at and
// no entries.
pub fn read_of_a_non_canonical_string_keeps_raw_and_reads_nothing_test() -> Nil {
  let cases = [
    "{\"at\": \"2026-10-13T10:00:00Z\"}",
    "{\"at\":\"2026-10-13T10:00:00Z\" }",
    " {\"at\":\"2026-10-13T10:00:00Z\"}",
    "{\"pod-deletion-cost\":{\"applied\":\"300\",\"at\":\"2026-10-13T09:00:00Z\"},\"at\":\"2026-10-13T10:00:00Z\"}",
    "{\"at\":\"2026-10-13T10:00:00Z\",\"pod-deletion-cost\":{\"at\":\"2026-10-13T09:00:00Z\",\"applied\":\"300\"}}",
    "{\"at\":\"2026-10-13T10:00:00Z\",\"safe-to-evict\":{\"yielded\":null,\"at\":\"2026-10-13T09:00:00Z\"}}",
  ]

  list.each(cases, fn(raw) {
    assert ownership.read(annotations([#(marker_key, raw)]))
      == Marker(Some(raw), None, [])
  })
}

// Ownership.Recorded: a member of any other name makes the string unusable,
// at the top level and inside a known member.
pub fn read_of_a_string_with_an_unknown_member_reads_nothing_test() -> Nil {
  let cases = [
    "{\"at\":\"2026-10-13T10:00:00Z\",\"note\":\"hi\"}",
    "{\"at\":\"2026-10-13T10:00:00Z\",\"pod-deletion-cost\":{\"applied\":\"300\",\"at\":\"2026-10-13T09:00:00Z\",\"by\":\"me\"}}",
    "{\"at\":\"2026-10-13T10:00:00Z\",\"pod_deletion_cost\":{\"applied\":\"300\",\"at\":\"2026-10-13T09:00:00Z\"}}",
  ]

  list.each(cases, fn(raw) {
    assert ownership.read(annotations([#(marker_key, raw)]))
      == Marker(Some(raw), None, [])
  })
}

// Ownership.Recorded: an at that is not RFC 3339 UTC to the second makes
// the string unusable, at the top level and inside a member, and so does a
// missing at.
pub fn read_of_a_string_with_a_bad_time_reads_nothing_test() -> Nil {
  let cases = [
    "{\"at\":\"2026-10-13T10:00:00\"}",
    "{\"at\":\"2026-10-13T10:00:00+00:00\"}",
    "{\"at\":\"2026-10-13T10:00:00.000Z\"}",
    "{\"at\":\"2026-10-13 10:00:00Z\"}",
    "{\"at\":\"2026-13-13T10:00:00Z\"}",
    "{\"at\":\"2026-00-13T10:00:00Z\"}",
    "{\"at\":\"2026-10-32T10:00:00Z\"}",
    "{\"at\":\"2026-10-00T10:00:00Z\"}",
    "{\"at\":\"2026-10-13T24:00:00Z\"}",
    "{\"at\":\"2026-10-13T10:60:00Z\"}",
    "{\"at\":\"2026-10-13T10:00:60Z\"}",
    "{\"at\":\"2026-10-13T1O:00:00Z\"}",
    "{\"at\":\"+026-10-13T10:00:00Z\"}",
    "{\"at\":\"\"}",
    "{\"at\":null}",
    "{\"at\":20261013}",
    "{}",
    "{\"pod-deletion-cost\":{\"applied\":\"300\",\"at\":\"2026-10-13T09:00:00Z\"}}",
    "{\"at\":\"2026-10-13T10:00:00Z\",\"pod-deletion-cost\":{\"applied\":\"300\",\"at\":\"soon\"}}",
    "{\"at\":\"2026-10-13T10:00:00Z\",\"pod-deletion-cost\":{\"applied\":\"300\"}}",
  ]

  list.each(cases, fn(raw) {
    assert ownership.read(annotations([#(marker_key, raw)]))
      == Marker(Some(raw), None, [])
  })
}

// Ownership.Recorded: a member needs exactly one of applied or yielded, a
// string or null; both, neither, or another type is unusable.
pub fn read_of_a_member_without_exactly_one_kind_reads_nothing_test() -> Nil {
  let cases = [
    "{\"at\":\"2026-10-13T10:00:00Z\",\"pod-deletion-cost\":{\"applied\":\"300\",\"at\":\"2026-10-13T09:00:00Z\",\"yielded\":null}}",
    "{\"at\":\"2026-10-13T10:00:00Z\",\"pod-deletion-cost\":{\"at\":\"2026-10-13T09:00:00Z\"}}",
    "{\"at\":\"2026-10-13T10:00:00Z\",\"pod-deletion-cost\":{\"applied\":300,\"at\":\"2026-10-13T09:00:00Z\"}}",
    "{\"at\":\"2026-10-13T10:00:00Z\",\"pod-deletion-cost\":{\"applied\":true,\"at\":\"2026-10-13T09:00:00Z\"}}",
    "{\"at\":\"2026-10-13T10:00:00Z\",\"pod-deletion-cost\":\"300\"}",
    "{\"at\":\"2026-10-13T10:00:00Z\",\"safe-to-evict\":null}",
  ]

  list.each(cases, fn(raw) {
    assert ownership.read(annotations([#(marker_key, raw)]))
      == Marker(Some(raw), None, [])
  })
}

// Ownership.Recorded: a string that is not a JSON object is unusable.
pub fn read_of_a_non_object_reads_nothing_test() -> Nil {
  let cases = ["", "300", "\"{}\"", "[]", "null", "{", "not json"]

  list.each(cases, fn(raw) {
    assert ownership.read(annotations([#(marker_key, raw)]))
      == Marker(Some(raw), None, [])
  })
}

// Ownership.Recorded: the marker is one annotation, knarr.io/applied.
pub fn marker_key_is_knarr_io_applied_test() -> Nil {
  assert ownership.marker_key == "knarr.io/applied"
}

// Ownership.Recorded: exactly two owned annotations, named by their marker
// member and written under their full key.
pub fn the_two_owned_annotations_test() -> Nil {
  assert ownership.pod_deletion_cost
    == ownership.Owned(
      name: "pod-deletion-cost",
      key: "controller.kubernetes.io/pod-deletion-cost",
    )
  assert ownership.safe_to_evict
    == ownership.Owned(
      name: "safe-to-evict",
      key: "cluster-autoscaler.kubernetes.io/safe-to-evict",
    )
}

// Ownership.Recorded: record finds the entry for an owned annotation.
pub fn record_finds_the_entry_for_an_owned_annotation_test() -> Nil {
  let marker = Marker(Some(both_raw), Some(at), both_entries)

  assert ownership.record(marker, pdc)
    == Some(AppliedRecord(Some("300"), earlier))
  assert ownership.record(marker, ste)
    == Some(YieldedRecord(Some("false"), earliest))
  assert ownership.record(applied_300_marker, ste) == None
  assert ownership.record(absent_marker, pdc) == None
}

// -------------------------------------------------------------- Adoption ---

// Ownership.Adoption: with no record, an absent annotation is unowned. A
// marker that is absent, or that read found unusable, reads as no record.
pub fn standing_without_a_record_and_an_absent_annotation_is_unowned_test() -> Nil {
  assert ownership.standing(
      marker: absent_marker,
      annotations: None,
      owned: pdc,
    )
    == Unowned
  assert ownership.standing(
      marker: absent_marker,
      annotations: annotations([#("app", "worker")]),
      owned: pdc,
    )
    == Unowned
  assert ownership.standing(
      marker: unusable_marker,
      annotations: annotations([#(marker_key, "{\"at\": \"garbage\"}")]),
      owned: pdc,
    )
    == Unowned
  assert ownership.standing(
      marker: applied_300_marker,
      annotations: annotations([
        #(marker_key, applied_300_raw),
        #(pdc_key, "300"),
      ]),
      owned: ste,
    )
    == Unowned
}

// Ownership.Adoption: with no record, a present annotation is foreign,
// whether the marker is absent or unusable.
pub fn standing_without_a_record_and_a_present_annotation_is_foreign_test() -> Nil {
  assert ownership.standing(
      marker: absent_marker,
      annotations: annotations([#(pdc_key, "300")]),
      owned: pdc,
    )
    == Foreign
  assert ownership.standing(
      marker: unusable_marker,
      annotations: annotations([
        #(marker_key, "{\"at\": \"garbage\"}"),
        #(pdc_key, "300"),
      ]),
      owned: pdc,
    )
    == Foreign
  assert ownership.standing(
      marker: applied_300_marker,
      annotations: annotations([
        #(marker_key, applied_300_raw),
        #(pdc_key, "300"),
        #(ste_key, "true"),
      ]),
      owned: ste,
    )
    == Foreign
}

// Ownership.Adoption: with an applied record, an annotation equal to the
// recorded value is owned.
pub fn standing_with_an_applied_record_and_the_same_value_is_owned_test() -> Nil {
  assert ownership.standing(
      marker: applied_300_marker,
      annotations: annotations([
        #(marker_key, applied_300_raw),
        #(pdc_key, "300"),
      ]),
      owned: pdc,
    )
    == OwnedByKnarr
}

// Ownership.Adoption: a null applied record with the annotation absent is
// owned: the removal that spells 0 keeps the pod owned.
pub fn standing_with_a_null_record_and_an_absent_annotation_is_owned_test() -> Nil {
  let marker =
    Marker(Some("unused"), Some(at), [Entry(pdc, AppliedRecord(None, at))])

  assert ownership.standing(
      marker:,
      annotations: annotations([#(marker_key, "unused")]),
      owned: pdc,
    )
    == OwnedByKnarr
}

// Ownership.Adoption: with an applied record, any other reading is a
// conflict: a different value, a removal by another writer, or a value
// where the record is null.
pub fn standing_with_an_applied_record_and_another_reading_is_conflict_test() -> Nil {
  assert ownership.standing(
      marker: applied_300_marker,
      annotations: annotations([
        #(marker_key, applied_300_raw),
        #(pdc_key, "301"),
      ]),
      owned: pdc,
    )
    == Conflict
  assert ownership.standing(
      marker: applied_300_marker,
      annotations: annotations([
        #(marker_key, applied_300_raw),
        #(pdc_key, " 300"),
      ]),
      owned: pdc,
    )
    == Conflict
  assert ownership.standing(
      marker: applied_300_marker,
      annotations: annotations([#(marker_key, applied_300_raw)]),
      owned: pdc,
    )
    == Conflict
  assert ownership.standing(
      marker: Marker(Some("unused"), Some(at), [
        Entry(pdc, AppliedRecord(None, at)),
      ]),
      annotations: annotations([#(marker_key, "unused"), #(pdc_key, "0")]),
      owned: pdc,
    )
    == Conflict
}

// Ownership.Adoption: a yielded record is yielded whatever the annotation
// holds, present or absent, and the yield is per annotation.
pub fn standing_with_a_yielded_record_is_yielded_test() -> Nil {
  let marker = Marker(Some(both_raw), Some(at), both_entries)

  assert ownership.standing(
      marker:,
      annotations: annotations([#(marker_key, both_raw), #(ste_key, "false")]),
      owned: ste,
    )
    == Yielded
  assert ownership.standing(
      marker:,
      annotations: annotations([#(marker_key, both_raw), #(ste_key, "true")]),
      owned: ste,
    )
    == Yielded
  assert ownership.standing(
      marker:,
      annotations: annotations([#(marker_key, both_raw)]),
      owned: ste,
    )
    == Yielded
  assert ownership.standing(
      marker:,
      annotations: annotations([#(marker_key, both_raw), #(pdc_key, "300")]),
      owned: pdc,
    )
    == OwnedByKnarr
}

// Ownership.Adoption: may_write is true for unowned and owned only.
pub fn may_write_is_true_for_unowned_and_owned_only_test() -> Nil {
  assert ownership.may_write(Unowned) == True
  assert ownership.may_write(OwnedByKnarr) == True
  assert ownership.may_write(Conflict) == False
  assert ownership.may_write(Yielded) == False
  assert ownership.may_write(Foreign) == False
}

// ------------------------------------------------------------- WriteMode ---

// Ownership.WriteMode and Ownership.Applied: the first write on a pod with
// no annotations map tests deletionTimestamp null and the map null, then
// adds the map holding the value and the marker together, members sorted.
// This is the patch the k8s_client snapshot carries.
pub fn patch_on_a_pod_without_a_map_adds_the_map_test() -> Nil {
  assert ownership.patch(
      marker: absent_marker,
      annotations: None,
      writes: [Write(pdc, Some("300"))],
      at:,
    )
    == [
      deletion_test,
      Operation(Test, annotations_path, Some("null")),
      Operation(
        Add,
        annotations_path,
        Some(
          "{\"controller.kubernetes.io/pod-deletion-cost\":\"300\",\"knarr.io/applied\":\"{\\\"at\\\":\\\"2026-10-13T10:00:00Z\\\",\\\"pod-deletion-cost\\\":{\\\"applied\\\":\\\"300\\\",\\\"at\\\":\\\"2026-10-13T10:00:00Z\\\"}}\"}",
        ),
      ),
    ]
}

// Ownership.WriteMode: the map add holds every write, sorted by key, so a
// safe-to-evict key sorts before the cost key and the marker last.
pub fn patch_on_a_pod_without_a_map_sorts_every_write_test() -> Nil {
  assert ownership.patch(
      marker: absent_marker,
      annotations: None,
      writes: [Write(pdc, Some("300")), Write(ste, Some("false"))],
      at:,
    )
    == [
      deletion_test,
      Operation(Test, annotations_path, Some("null")),
      Operation(
        Add,
        annotations_path,
        Some(
          "{\"cluster-autoscaler.kubernetes.io/safe-to-evict\":\"false\",\"controller.kubernetes.io/pod-deletion-cost\":\"300\",\"knarr.io/applied\":\"{\\\"at\\\":\\\"2026-10-13T10:00:00Z\\\",\\\"pod-deletion-cost\\\":{\\\"applied\\\":\\\"300\\\",\\\"at\\\":\\\"2026-10-13T10:00:00Z\\\"},\\\"safe-to-evict\\\":{\\\"applied\\\":\\\"false\\\",\\\"at\\\":\\\"2026-10-13T10:00:00Z\\\"}}\"}",
        ),
      ),
    ]
}

// Ownership.WriteMode: a map without the marker tests the marker null and
// the key null, adds the value, then adds the marker as one JSON string.
pub fn patch_on_a_map_without_the_marker_tests_null_test() -> Nil {
  assert ownership.patch(
      marker: absent_marker,
      annotations: annotations([#("app", "worker")]),
      writes: [Write(pdc, Some("300"))],
      at:,
    )
    == [
      deletion_test,
      absent_marker_test,
      Operation(Test, pdc_path, Some("null")),
      Operation(Add, pdc_path, Some("\"300\"")),
      Operation(
        Add,
        marker_path,
        Some(
          "\"{\\\"at\\\":\\\"2026-10-13T10:00:00Z\\\",\\\"pod-deletion-cost\\\":{\\\"applied\\\":\\\"300\\\",\\\"at\\\":\\\"2026-10-13T10:00:00Z\\\"}}\"",
        ),
      ),
    ]
}

// Ownership.WriteMode: with a marker present, the marker test carries its
// raw string, the key test the applied value, and the new marker keeps the
// other entry while the written one is recorded applied at `at`.
pub fn patch_with_a_marker_present_tests_its_raw_string_test() -> Nil {
  assert ownership.patch(
      marker: applied_300_marker,
      annotations: annotations([
        #(marker_key, applied_300_raw),
        #(pdc_key, "300"),
      ]),
      writes: [Write(ste, Some("false"))],
      at:,
    )
    == [
      deletion_test,
      Operation(Test, marker_path, Some(applied_300_quoted)),
      Operation(Test, ste_path, Some("null")),
      Operation(Add, ste_path, Some("\"false\"")),
      Operation(
        Add,
        marker_path,
        Some(
          "\"{\\\"at\\\":\\\"2026-10-13T10:00:00Z\\\",\\\"pod-deletion-cost\\\":{\\\"applied\\\":\\\"300\\\",\\\"at\\\":\\\"2026-10-13T09:00:00Z\\\"},\\\"safe-to-evict\\\":{\\\"applied\\\":\\\"false\\\",\\\"at\\\":\\\"2026-10-13T10:00:00Z\\\"}}\"",
        ),
      ),
    ]
}

// Ownership.WriteMode: an unusable marker is overwritten under the test on
// its raw string.
pub fn patch_with_an_unusable_marker_tests_its_raw_string_test() -> Nil {
  assert ownership.patch(
      marker: unusable_marker,
      annotations: annotations([#(marker_key, "{\"at\": \"garbage\"}")]),
      writes: [Write(pdc, Some("300"))],
      at:,
    )
    == [
      deletion_test,
      Operation(Test, marker_path, Some("\"{\\\"at\\\": \\\"garbage\\\"}\"")),
      Operation(Test, pdc_path, Some("null")),
      Operation(Add, pdc_path, Some("\"300\"")),
      Operation(
        Add,
        marker_path,
        Some(
          "\"{\\\"at\\\":\\\"2026-10-13T10:00:00Z\\\",\\\"pod-deletion-cost\\\":{\\\"applied\\\":\\\"300\\\",\\\"at\\\":\\\"2026-10-13T10:00:00Z\\\"}}\"",
        ),
      ),
    ]
}

// Ownership.WriteMode: the operations are in this order: deletionTimestamp
// test, marker test, every key test, every add or remove, the marker add.
pub fn patch_orders_its_operations_test() -> Nil {
  let operations =
    ownership.patch(
      marker: applied_300_marker,
      annotations: annotations([
        #(marker_key, applied_300_raw),
        #(pdc_key, "300"),
      ]),
      writes: [Write(pdc, Some("500")), Write(ste, Some("false"))],
      at:,
    )

  assert ops(operations)
    == [
      #(Test, deletion_path),
      #(Test, marker_path),
      #(Test, pdc_path),
      #(Test, ste_path),
      #(Add, pdc_path),
      #(Add, ste_path),
      #(Add, marker_path),
    ]
}

// Ownership.WriteMode: a key is a pointer segment with ~ as ~0 and / as ~1.
pub fn patch_escapes_the_key_as_a_pointer_segment_test() -> Nil {
  let odd = ownership.Owned(name: "odd", key: "a~b/c~/d")

  assert ops(ownership.patch(
      marker: absent_marker,
      annotations: annotations([]),
      writes: [Write(odd, Some("1"))],
      at:,
    ))
    == [
      #(Test, deletion_path),
      #(Test, marker_path),
      #(Test, "/metadata/annotations/a~0b~1c~0~1d"),
      #(Add, "/metadata/annotations/a~0b~1c~0~1d"),
      #(Add, marker_path),
    ]
}

// Ownership.WriteMode: a write of null for an annotation whose record is
// missing or null is dropped; with no write left there is no patch.
pub fn patch_drops_a_removal_with_nothing_to_remove_test() -> Nil {
  assert ownership.patch(
      marker: absent_marker,
      annotations: None,
      writes: [Write(pdc, None)],
      at:,
    )
    == []
  assert ownership.patch(
      marker: absent_marker,
      annotations: annotations([]),
      writes: [Write(pdc, None)],
      at:,
    )
    == []
  assert ownership.patch(
      marker: Marker(Some("unused"), Some(at), [
        Entry(pdc, AppliedRecord(None, earlier)),
      ]),
      annotations: annotations([#(marker_key, "unused")]),
      writes: [Write(pdc, None)],
      at:,
    )
    == []
}

// Ownership.WriteMode: the dropped write leaves the others in the patch.
pub fn patch_keeps_the_other_writes_when_one_is_dropped_test() -> Nil {
  assert ops(ownership.patch(
      marker: absent_marker,
      annotations: annotations([]),
      writes: [Write(pdc, None), Write(ste, Some("false"))],
      at:,
    ))
    == [
      #(Test, deletion_path),
      #(Test, marker_path),
      #(Test, ste_path),
      #(Add, ste_path),
      #(Add, marker_path),
    ]
}

// Ownership.WriteMode: no writes give no operations.
pub fn patch_with_no_writes_is_empty_test() -> Nil {
  assert ownership.patch(
      marker: applied_300_marker,
      annotations: annotations([
        #(marker_key, applied_300_raw),
        #(pdc_key, "300"),
      ]),
      writes: [],
      at:,
    )
    == []
  assert ownership.patch(
      marker: absent_marker,
      annotations: None,
      writes: [],
      at:,
    )
    == []
}

// Ownership.WriteMode and Ownership.Applied: the removal that spells 0 tests
// the applied value, removes the key and keeps the marker with a null
// applied record.
pub fn patch_removal_tests_the_applied_value_and_records_null_test() -> Nil {
  assert ownership.patch(
      marker: applied_300_marker,
      annotations: annotations([
        #(marker_key, applied_300_raw),
        #(pdc_key, "300"),
      ]),
      writes: [Write(pdc, None)],
      at:,
    )
    == [
      deletion_test,
      Operation(Test, marker_path, Some(applied_300_quoted)),
      Operation(Test, pdc_path, Some("\"300\"")),
      Operation(Remove, pdc_path, None),
      Operation(
        Add,
        marker_path,
        Some(
          "\"{\\\"at\\\":\\\"2026-10-13T10:00:00Z\\\",\\\"pod-deletion-cost\\\":{\\\"applied\\\":null,\\\"at\\\":\\\"2026-10-13T10:00:00Z\\\"}}\"",
        ),
      ),
    ]
}

// Ownership.WriteMode: a write over a null applied record tests null.
pub fn patch_over_a_null_record_tests_null_test() -> Nil {
  let raw =
    "{\"at\":\"2026-10-13T09:00:00Z\",\"pod-deletion-cost\":{\"applied\":null,\"at\":\"2026-10-13T09:00:00Z\"}}"

  assert ownership.patch(
      marker: Marker(Some(raw), Some(earlier), [
        Entry(pdc, AppliedRecord(None, earlier)),
      ]),
      annotations: annotations([#(marker_key, raw)]),
      writes: [Write(pdc, Some("7"))],
      at:,
    )
    == [
      deletion_test,
      Operation(
        Test,
        marker_path,
        Some(
          "\"{\\\"at\\\":\\\"2026-10-13T09:00:00Z\\\",\\\"pod-deletion-cost\\\":{\\\"applied\\\":null,\\\"at\\\":\\\"2026-10-13T09:00:00Z\\\"}}\"",
        ),
      ),
      Operation(Test, pdc_path, Some("null")),
      Operation(Add, pdc_path, Some("\"7\"")),
      Operation(
        Add,
        marker_path,
        Some(
          "\"{\\\"at\\\":\\\"2026-10-13T10:00:00Z\\\",\\\"pod-deletion-cost\\\":{\\\"applied\\\":\\\"7\\\",\\\"at\\\":\\\"2026-10-13T10:00:00Z\\\"}}\"",
        ),
      ),
    ]
}

// Ownership.WriteMode: no operation names a path outside
// /metadata/annotations except the deletionTimestamp test.
pub fn patch_names_no_path_outside_the_annotations_test() -> Nil {
  let operations =
    ownership.patch(
      marker: applied_300_marker,
      annotations: annotations([
        #(marker_key, applied_300_raw),
        #(pdc_key, "300"),
      ]),
      writes: [Write(pdc, Some("500")), Write(ste, None)],
      at:,
    )

  assert list.all(operations, fn(operation) {
    operation.path == deletion_path
    || string.starts_with(operation.path, "/metadata/annotations/")
  })
}

// ----------------------------------------------------------------- Yield ---

// Ownership.Yield: the yield tests the same preconditions, with the owned
// annotation equal to the value found, and rewrites only the marker: the
// record becomes yielded with the found value at `at`, the other entry is
// kept, and the annotation stays.
pub fn yield_with_a_found_value_rewrites_only_the_marker_test() -> Nil {
  assert ownership.yield(
      marker: applied_300_marker,
      annotations: annotations([
        #(marker_key, applied_300_raw),
        #(pdc_key, "999"),
      ]),
      owned: pdc,
      at:,
    )
    == [
      deletion_test,
      Operation(Test, marker_path, Some(applied_300_quoted)),
      Operation(Test, pdc_path, Some("\"999\"")),
      Operation(
        Add,
        marker_path,
        Some(
          "\"{\\\"at\\\":\\\"2026-10-13T10:00:00Z\\\",\\\"pod-deletion-cost\\\":{\\\"at\\\":\\\"2026-10-13T10:00:00Z\\\",\\\"yielded\\\":\\\"999\\\"}}\"",
        ),
      ),
    ]
}

// Ownership.Yield: a removal by another writer is yielded with null, under a
// test that the annotation is null.
pub fn yield_with_the_annotation_absent_records_null_test() -> Nil {
  assert ownership.yield(
      marker: applied_300_marker,
      annotations: annotations([#(marker_key, applied_300_raw)]),
      owned: pdc,
      at:,
    )
    == [
      deletion_test,
      Operation(Test, marker_path, Some(applied_300_quoted)),
      Operation(Test, pdc_path, Some("null")),
      Operation(
        Add,
        marker_path,
        Some(
          "\"{\\\"at\\\":\\\"2026-10-13T10:00:00Z\\\",\\\"pod-deletion-cost\\\":{\\\"at\\\":\\\"2026-10-13T10:00:00Z\\\",\\\"yielded\\\":null}}\"",
        ),
      ),
    ]
}

// Ownership.Yield: the yield is per annotation; the other entry is kept as
// it was.
pub fn yield_keeps_the_other_entry_test() -> Nil {
  let marker = Marker(Some(both_raw), Some(at), both_entries)
  let later = "2026-10-13T11:00:00Z"

  assert ownership.yield(
      marker:,
      annotations: annotations([
        #(marker_key, both_raw),
        #(pdc_key, "1"),
        #(ste_key, "false"),
      ]),
      owned: pdc,
      at: later,
    )
    == [
      deletion_test,
      Operation(
        Test,
        marker_path,
        Some(
          "\"{\\\"at\\\":\\\"2026-10-13T10:00:00Z\\\",\\\"pod-deletion-cost\\\":{\\\"applied\\\":\\\"300\\\",\\\"at\\\":\\\"2026-10-13T09:00:00Z\\\"},\\\"safe-to-evict\\\":{\\\"at\\\":\\\"2026-10-13T08:00:00Z\\\",\\\"yielded\\\":\\\"false\\\"}}\"",
        ),
      ),
      Operation(Test, pdc_path, Some("\"1\"")),
      Operation(
        Add,
        marker_path,
        Some(
          "\"{\\\"at\\\":\\\"2026-10-13T11:00:00Z\\\",\\\"pod-deletion-cost\\\":{\\\"at\\\":\\\"2026-10-13T11:00:00Z\\\",\\\"yielded\\\":\\\"1\\\"},\\\"safe-to-evict\\\":{\\\"at\\\":\\\"2026-10-13T08:00:00Z\\\",\\\"yielded\\\":\\\"false\\\"}}\"",
        ),
      ),
    ]
}

// Ownership.Yield: a pod without a map cannot hold a conflict, but the
// yield is total: it takes the null-map branch with the marker alone.
pub fn yield_on_a_pod_without_a_map_adds_the_map_test() -> Nil {
  assert ownership.yield(
      marker: absent_marker,
      annotations: None,
      owned: pdc,
      at:,
    )
    == [
      deletion_test,
      Operation(Test, annotations_path, Some("null")),
      Operation(
        Add,
        annotations_path,
        Some(
          "{\"knarr.io/applied\":\"{\\\"at\\\":\\\"2026-10-13T10:00:00Z\\\",\\\"pod-deletion-cost\\\":{\\\"at\\\":\\\"2026-10-13T10:00:00Z\\\",\\\"yielded\\\":null}}\"}",
        ),
      ),
    ]
}

// -------------------------------------------------------------- Document ---

// Ownership.WriteMode: document encodes the operations as the JSON Patch
// body, a value as its JSON text, no "value" member for a remove.
pub fn document_encodes_the_operations_test() -> Nil {
  assert ownership.document([
      deletion_test,
      Operation(Test, pdc_path, Some("\"300\"")),
      Operation(Remove, pdc_path, None),
      Operation(Add, marker_path, Some("\"{}\"")),
    ])
    == "[{\"op\":\"test\",\"path\":\"/metadata/deletionTimestamp\",\"value\":null},{\"op\":\"test\",\"path\":\"/metadata/annotations/controller.kubernetes.io~1pod-deletion-cost\",\"value\":\"300\"},{\"op\":\"remove\",\"path\":\"/metadata/annotations/controller.kubernetes.io~1pod-deletion-cost\"},{\"op\":\"add\",\"path\":\"/metadata/annotations/knarr.io~1applied\",\"value\":\"{}\"}]"
}

// Ownership.WriteMode: the path is escaped as a JSON string, and the value
// travels as the text it is, escapes included.
pub fn document_escapes_the_path_and_keeps_the_value_text_test() -> Nil {
  assert ownership.document([
      Operation(Add, "/metadata/annotations/a\"b\\c", Some("\"x\\\"y\"")),
    ])
    == "[{\"op\":\"add\",\"path\":\"/metadata/annotations/a\\\"b\\\\c\",\"value\":\"x\\\"y\"}]"
}

// Ownership.WriteMode: the document of the first write, as the client sends
// it.
pub fn document_of_the_first_write_test() -> Nil {
  assert ownership.document(ownership.patch(
      marker: absent_marker,
      annotations: None,
      writes: [Write(pdc, Some("300"))],
      at:,
    ))
    == "[{\"op\":\"test\",\"path\":\"/metadata/deletionTimestamp\",\"value\":null},{\"op\":\"test\",\"path\":\"/metadata/annotations\",\"value\":null},{\"op\":\"add\",\"path\":\"/metadata/annotations\",\"value\":{\"controller.kubernetes.io/pod-deletion-cost\":\"300\",\"knarr.io/applied\":\"{\\\"at\\\":\\\"2026-10-13T10:00:00Z\\\",\\\"pod-deletion-cost\\\":{\\\"applied\\\":\\\"300\\\",\\\"at\\\":\\\"2026-10-13T10:00:00Z\\\"}}\"}}]"
}

// Ownership.WriteMode: no operations is an empty array.
pub fn document_of_no_operations_is_an_empty_array_test() -> Nil {
  assert ownership.document([]) == "[]"
}

// observability Logs Lines: keys names every annotation a document writes
// or removes, in document order, tests excluded; the first write's one add
// of the whole map names the map's members.
pub fn keys_names_the_annotations_a_document_writes_test() -> Nil {
  assert ownership.keys([
      deletion_test,
      Operation(Test, pdc_path, Some("\"300\"")),
      Operation(Remove, pdc_path, None),
      Operation(Add, marker_path, Some("\"{}\"")),
    ])
    == [pdc_key, ownership.marker_key]
  assert ownership.keys(ownership.patch(
      marker: absent_marker,
      annotations: None,
      writes: [Write(pdc, Some("300"))],
      at:,
    ))
    == [pdc_key, ownership.marker_key]
  assert ownership.keys([deletion_test]) == []
}

// -------------------------------------------------------------- Rejected ---

// Ownership.Rejected: every test passes against the view: a nil
// deletionTimestamp, a null map test against no map, a null key test
// against a map without the key, and a string test against the key holding
// it.
pub fn rejected_is_true_when_every_test_passes_test() -> Nil {
  assert ownership.rejected(
      operations: [
        deletion_test,
        Operation(Test, annotations_path, Some("null")),
        Operation(Add, annotations_path, Some("{}")),
      ],
      annotations: None,
      deletion_timestamp: None,
    )
    == True
  assert ownership.rejected(
      operations: [
        deletion_test,
        Operation(Test, marker_path, Some(applied_300_quoted)),
        Operation(Test, pdc_path, Some("\"300\"")),
        Operation(Test, ste_path, Some("null")),
        Operation(Add, ste_path, Some("\"false\"")),
        Operation(Add, marker_path, Some("\"{}\"")),
      ],
      annotations: annotations([
        #(marker_key, applied_300_raw),
        #(pdc_key, "300"),
      ]),
      deletion_timestamp: None,
    )
    == True
}

// Ownership.Rejected: a set deletionTimestamp fails its test.
pub fn rejected_is_false_when_the_pod_is_terminating_test() -> Nil {
  assert ownership.rejected(
      operations: [deletion_test],
      annotations: None,
      deletion_timestamp: Some("2026-10-13T10:00:01Z"),
    )
    == False
}

// Ownership.Rejected: the null map test fails against a map, even an empty
// one.
pub fn rejected_is_false_when_the_map_test_finds_a_map_test() -> Nil {
  assert ownership.rejected(
      operations: [
        deletion_test,
        Operation(Test, annotations_path, Some("null")),
      ],
      annotations: annotations([]),
      deletion_timestamp: None,
    )
    == False
}

// Ownership.Rejected: a null key test fails when the key is present, and
// under a missing parent, since a test under a missing parent fails.
pub fn rejected_is_false_when_a_null_key_test_fails_test() -> Nil {
  assert ownership.rejected(
      operations: [Operation(Test, pdc_path, Some("null"))],
      annotations: annotations([#(pdc_key, "300")]),
      deletion_timestamp: None,
    )
    == False
  assert ownership.rejected(
      operations: [Operation(Test, pdc_path, Some("null"))],
      annotations: None,
      deletion_timestamp: None,
    )
    == False
}

// Ownership.Rejected: a string key test fails when the key is absent, holds
// another string, or has no parent.
pub fn rejected_is_false_when_a_string_key_test_fails_test() -> Nil {
  assert ownership.rejected(
      operations: [Operation(Test, pdc_path, Some("\"300\""))],
      annotations: annotations([]),
      deletion_timestamp: None,
    )
    == False
  assert ownership.rejected(
      operations: [Operation(Test, pdc_path, Some("\"300\""))],
      annotations: annotations([#(pdc_key, "301")]),
      deletion_timestamp: None,
    )
    == False
  assert ownership.rejected(
      operations: [Operation(Test, pdc_path, Some("\"300\""))],
      annotations: None,
      deletion_timestamp: None,
    )
    == False
}

// Ownership.Rejected: one failing test among passing ones fails the whole.
pub fn rejected_is_false_when_one_test_fails_test() -> Nil {
  assert ownership.rejected(
      operations: [
        deletion_test,
        absent_marker_test,
        Operation(Test, pdc_path, Some("\"300\"")),
      ],
      annotations: annotations([#(marker_key, "{}"), #(pdc_key, "300")]),
      deletion_timestamp: None,
    )
    == False
}

// Ownership.Rejected: a test of a path WriteMode never names, a test with
// no operand, or a test of a non-string operand fails.
pub fn rejected_is_false_for_a_test_outside_write_mode_test() -> Nil {
  assert ownership.rejected(
      operations: [Operation(Test, "/metadata/name", Some("\"p\""))],
      annotations: annotations([]),
      deletion_timestamp: None,
    )
    == False
  assert ownership.rejected(
      operations: [Operation(Test, "/metadata/annotations/a/b", Some("null"))],
      annotations: annotations([]),
      deletion_timestamp: None,
    )
    == False
  assert ownership.rejected(
      operations: [Operation(Test, pdc_path, None)],
      annotations: annotations([]),
      deletion_timestamp: None,
    )
    == False
  assert ownership.rejected(
      operations: [Operation(Test, pdc_path, Some("300"))],
      annotations: annotations([#(pdc_key, "300")]),
      deletion_timestamp: None,
    )
    == False
}

// Ownership.Rejected: the key under test is read back through the pointer
// escaping, ~1 before ~0.
pub fn rejected_reads_an_escaped_key_test() -> Nil {
  let operations = [
    Operation(Test, "/metadata/annotations/a~0b~1c~0~1d", Some("\"1\"")),
  ]

  assert ownership.rejected(
      operations:,
      annotations: annotations([#("a~b/c~/d", "1")]),
      deletion_timestamp: None,
    )
    == True
  assert ownership.rejected(
      operations:,
      annotations: annotations([#("a~0b~1c~0~1d", "1")]),
      deletion_timestamp: None,
    )
    == False
}

// Ownership.Rejected: a patch with no test is vacuously rejected.
pub fn rejected_is_true_for_a_patch_without_tests_test() -> Nil {
  assert ownership.rejected(
      operations: [Operation(Add, pdc_path, Some("\"300\""))],
      annotations: None,
      deletion_timestamp: Some("2026-10-13T10:00:01Z"),
    )
    == True
  assert ownership.rejected(
      operations: [],
      annotations: None,
      deletion_timestamp: None,
    )
    == True
}

// ----------------------------------------------------------------- Event ---

// Ownership.Event: event is built from the marker and the annotations the
// yield patch was built from, so applied is the record the yield replaced
// and found is the value the other writer left.
pub fn event_carries_the_applied_and_found_values_test() -> Nil {
  assert ownership.event(
      pod_name: "worker-abc",
      pod_uid: "4a3b",
      marker: applied_300_marker,
      annotations: annotations([
        #(marker_key, applied_300_raw),
        #(pdc_key, "999"),
      ]),
      owned: pdc,
    )
    == ConflictEvent(
      pod_name: "worker-abc",
      pod_uid: "4a3b",
      owned: pdc,
      applied: Some("300"),
      found: Some("999"),
    )
}

// Ownership.Event: a null applied record and an absent annotation are None,
// as is a missing record.
pub fn event_with_absent_values_test() -> Nil {
  assert ownership.event(
      pod_name: "worker-abc",
      pod_uid: "4a3b",
      marker: Marker(Some("unused"), Some(at), [
        Entry(pdc, AppliedRecord(None, at)),
      ]),
      annotations: annotations([#(marker_key, "unused")]),
      owned: pdc,
    )
    == ConflictEvent(
      pod_name: "worker-abc",
      pod_uid: "4a3b",
      owned: pdc,
      applied: None,
      found: None,
    )
  assert ownership.event(
      pod_name: "worker-abc",
      pod_uid: "4a3b",
      marker: absent_marker,
      annotations: None,
      owned: ste,
    )
    == ConflictEvent(
      pod_name: "worker-abc",
      pod_uid: "4a3b",
      owned: ste,
      applied: None,
      found: None,
    )
}

// Ownership.Event: message renders the key, the two values unquoted, and
// the fixed sentence.
pub fn message_renders_the_values_test() -> Nil {
  assert ownership.message(ConflictEvent(
      pod_name: "worker-abc",
      pod_uid: "4a3b",
      owned: pdc,
      applied: Some("300"),
      found: Some("999"),
    ))
    == "controller.kubernetes.io/pod-deletion-cost: knarr applied 300 and found 999; another writer owns it now and knarr will not write it again on this pod"
}

// Ownership.Event: "absent" stands for a null applied or found, on either
// side.
pub fn message_renders_absent_on_either_side_test() -> Nil {
  assert ownership.message(ConflictEvent(
      pod_name: "worker-abc",
      pod_uid: "4a3b",
      owned: ste,
      applied: None,
      found: Some("true"),
    ))
    == "cluster-autoscaler.kubernetes.io/safe-to-evict: knarr applied absent and found true; another writer owns it now and knarr will not write it again on this pod"
  assert ownership.message(ConflictEvent(
      pod_name: "worker-abc",
      pod_uid: "4a3b",
      owned: pdc,
      applied: Some("300"),
      found: None,
    ))
    == "controller.kubernetes.io/pod-deletion-cost: knarr applied 300 and found absent; another writer owns it now and knarr will not write it again on this pod"
}

// ------------------------------------------------------------------ Pure ---

// Ownership.Pure: every signature is a function of its arguments alone, so
// a second application gives the same result.
pub fn every_function_is_pure_under_repeated_application_test() -> Nil {
  let view = annotations([#(marker_key, applied_300_raw), #(pdc_key, "999")])
  let marker = Marker(Some(both_raw), Some(at), both_entries)
  let writes = [Write(pdc, Some("5"))]
  let patch =
    ownership.patch(marker: applied_300_marker, annotations: view, writes:, at:)
  let yield =
    ownership.yield(
      marker: applied_300_marker,
      annotations: view,
      owned: pdc,
      at:,
    )

  assert ownership.read(view) == ownership.read(view)
  assert ownership.render(marker) == ownership.render(marker)
  assert ownership.standing(
      marker: applied_300_marker,
      annotations: view,
      owned: pdc,
    )
    == ownership.standing(
      marker: applied_300_marker,
      annotations: view,
      owned: pdc,
    )
  assert patch
    == ownership.patch(
      marker: applied_300_marker,
      annotations: view,
      writes:,
      at:,
    )
  assert yield
    == ownership.yield(
      marker: applied_300_marker,
      annotations: view,
      owned: pdc,
      at:,
    )
  assert ownership.document(patch) == ownership.document(patch)
  assert ownership.rejected(
      operations: yield,
      annotations: view,
      deletion_timestamp: None,
    )
    == ownership.rejected(
      operations: yield,
      annotations: view,
      deletion_timestamp: None,
    )
  assert ownership.event(
      pod_name: "p",
      pod_uid: "u",
      marker: applied_300_marker,
      annotations: view,
      owned: pdc,
    )
    == ownership.event(
      pod_name: "p",
      pod_uid: "u",
      marker: applied_300_marker,
      annotations: view,
      owned: pdc,
    )
}

fn pad(number: Int, width: Int) -> String {
  string.pad_start(int.to_string(number), width, "0")
}

// An RFC 3339 UTC time to the second, every field within its range.
fn time_generator() -> qcheck.Generator(String) {
  qcheck.map6(
    qcheck.bounded_int(from: 0, to: 9999),
    qcheck.bounded_int(from: 1, to: 12),
    qcheck.bounded_int(from: 1, to: 31),
    qcheck.bounded_int(from: 0, to: 23),
    qcheck.bounded_int(from: 0, to: 59),
    qcheck.bounded_int(from: 0, to: 59),
    fn(year, month, day, hour, minute, second) {
      pad(year, 4)
      <> "-"
      <> pad(month, 2)
      <> "-"
      <> pad(day, 2)
      <> "T"
      <> pad(hour, 2)
      <> ":"
      <> pad(minute, 2)
      <> ":"
      <> pad(second, 2)
      <> "Z"
    },
  )
}

// A property in the gate takes a fixed seed (docs/reference/testing.md).
// Ownership.Recorded: render is canonical, so for any times and any values,
// read of a map holding render of a marker reads back exactly its entries
// and its at.
pub fn read_of_a_rendered_marker_reads_back_its_entries_test() -> Nil {
  let config = qcheck.default_config() |> qcheck.with_seed(qcheck.seed(31))
  let times =
    qcheck.tuple3(time_generator(), time_generator(), time_generator())
  let values =
    qcheck.tuple2(
      qcheck.option_from(qcheck.string()),
      qcheck.option_from(qcheck.string()),
    )
  use #(#(last, pdc_at, ste_at), #(pdc_value, ste_value)) <- qcheck.run(
    config,
    qcheck.tuple2(times, values),
  )
  let entries = [
    Entry(pdc, AppliedRecord(pdc_value, pdc_at)),
    Entry(ste, YieldedRecord(ste_value, ste_at)),
  ]
  let rendered = ownership.render(Marker(None, Some(last), entries))

  assert ownership.read(annotations([#(marker_key, rendered), #("app", "w")]))
    == Marker(Some(rendered), Some(last), entries)
}

// ----------------------------------------------------------- Obligations ---

// value-equality.Annotation and entity-fields.Annotation: an annotation is
// one key and value pair of the map the functions read, compared by value.
pub fn annotation_is_a_key_and_a_value_test() -> Nil {
  let annotation: #(String, String) = #(pdc_key, "300")

  assert annotation.0 == "controller.kubernetes.io/pod-deletion-cost"
  assert annotation.1 == "300"
  assert annotation == #("controller.kubernetes.io/pod-deletion-cost", "300")
  assert annotation != #(pdc_key, "301")
  assert dict.from_list([annotation])
    == dict.from_list([#("controller.kubernetes.io/pod-deletion-cost", "300")])
}

// value-equality.Owned and entity-fields.Owned: name and key, by value.
pub fn owned_is_a_name_and_a_key_test() -> Nil {
  let owned = ownership.Owned(name: "pod-deletion-cost", key: pdc_key)

  assert owned.name == "pod-deletion-cost"
  assert owned.key == "controller.kubernetes.io/pod-deletion-cost"
  assert owned == pdc
  assert owned != ste
}

// value-equality.Record and entity-fields.Record: kind, value and at, by
// value. The kind is the constructor.
pub fn record_is_a_kind_a_value_and_an_at_test() -> Nil {
  let applied = AppliedRecord(value: Some("300"), at: at)

  assert applied.value == Some("300")
  assert applied.at == "2026-10-13T10:00:00Z"
  assert applied == AppliedRecord(Some("300"), "2026-10-13T10:00:00Z")
  assert applied != YieldedRecord(Some("300"), "2026-10-13T10:00:00Z")
  assert applied != AppliedRecord(None, "2026-10-13T10:00:00Z")
}

// value-equality.Entry and entity-fields.Entry: owned and record, by value.
pub fn entry_is_an_owned_and_a_record_test() -> Nil {
  let entry = Entry(owned: pdc, record: AppliedRecord(Some("300"), at))

  assert entry.owned == pdc
  assert entry.record == AppliedRecord(Some("300"), "2026-10-13T10:00:00Z")
  assert entry == Entry(pdc, AppliedRecord(Some("300"), "2026-10-13T10:00:00Z"))
  assert entry != Entry(ste, AppliedRecord(Some("300"), "2026-10-13T10:00:00Z"))
}

// value-equality.Marker and entity-fields.Marker: raw, at and entries, by
// value.
pub fn marker_is_raw_at_and_entries_test() -> Nil {
  let marker = Marker(raw: Some(both_raw), at: Some(at), entries: both_entries)

  assert marker.raw == Some(both_raw)
  assert marker.at == Some("2026-10-13T10:00:00Z")
  assert marker.entries == both_entries
  assert marker
    == Marker(Some(both_raw), Some("2026-10-13T10:00:00Z"), both_entries)
  assert marker != Marker(Some(both_raw), None, both_entries)
  assert absent_marker == Marker(None, None, [])
}

// value-equality.Standing and entity-fields.Standing: the state is one of
// five, compared by value.
pub fn standing_is_one_of_five_states_test() -> Nil {
  let states = [Unowned, OwnedByKnarr, Conflict, Yielded, Foreign]

  assert list.length(states) == 5
  assert list.unique(states) == states
  assert list.contains(
    states,
    ownership.standing(marker: absent_marker, annotations: None, owned: pdc),
  )
}

// value-equality.Write and entity-fields.Write: owned and value, by value.
pub fn write_is_an_owned_and_a_value_test() -> Nil {
  let write = Write(owned: pdc, value: Some("300"))

  assert write.owned == pdc
  assert write.value == Some("300")
  assert write == Write(pdc, Some("300"))
  assert write != Write(pdc, None)
}

// value-equality.Operation and entity-fields.Operation: op, path and value,
// by value; the value is absent for a remove.
pub fn operation_is_an_op_a_path_and_a_value_test() -> Nil {
  let operation = Operation(op: Add, path: pdc_path, value: Some("\"300\""))

  assert operation.op == Add
  assert operation.path
    == "/metadata/annotations/controller.kubernetes.io~1pod-deletion-cost"
  assert operation.value == Some("\"300\"")
  assert operation == Operation(Add, pdc_path, Some("\"300\""))
  assert operation != Operation(Remove, pdc_path, None)
  assert operation != Operation(Test, pdc_path, Some("\"300\""))
}

// value-equality.ConflictEvent and entity-fields.ConflictEvent: pod_name,
// pod_uid, owned, applied and found, by value.
pub fn conflict_event_has_five_fields_test() -> Nil {
  let event =
    ConflictEvent(
      pod_name: "worker-abc",
      pod_uid: "4a3b",
      owned: pdc,
      applied: Some("300"),
      found: None,
    )

  assert event.pod_name == "worker-abc"
  assert event.pod_uid == "4a3b"
  assert event.owned == pdc
  assert event.applied == Some("300")
  assert event.found == None
  assert event == ConflictEvent("worker-abc", "4a3b", pdc, Some("300"), None)
  assert event
    != ConflictEvent("worker-abc", "4a3b", pdc, Some("300"), Some("1"))
}
// contract-signature.Ownership.read: (annotations?) -> Marker. Covered by
// read_of_the_canonical_string_round_trips_test and
// read_of_a_pod_without_a_map_is_the_absent_marker_test.
// contract-signature.Ownership.render: (marker) -> String. Covered by
// render_orders_members_lexicographically_at_every_level_test.
// contract-signature.Ownership.standing: (marker, annotations?, owned) ->
// Standing. Covered by the five standing tests.
// contract-signature.Ownership.may_write: (standing) -> Boolean. Covered by
// may_write_is_true_for_unowned_and_owned_only_test.
// contract-signature.Ownership.patch: (marker, annotations?, writes, at) ->
// List<Operation>. Covered by patch_on_a_pod_without_a_map_adds_the_map_test
// and patch_with_a_marker_present_tests_its_raw_string_test.
// contract-signature.Ownership.yield: (marker, annotations?, owned, at) ->
// List<Operation>. Covered by
// yield_with_a_found_value_rewrites_only_the_marker_test.
// contract-signature.Ownership.document: (operations) -> String. Covered by
// document_encodes_the_operations_test. keys and applied_value are helpers
// of the module, not contract signatures.
// contract-signature.Ownership.rejected: (operations, annotations?,
// deletion_timestamp?) -> Boolean. Covered by
// rejected_is_true_when_every_test_passes_test.
// contract-signature.Ownership.event: (pod_name, pod_uid, marker,
// annotations?, owned) -> ConflictEvent. Covered by
// event_carries_the_applied_and_found_values_test.
// contract-signature.Ownership.message: (event) -> String. Covered by
// message_renders_the_values_test.
