//// The collector, the sink that outlives every worker pod: one record per
//// pod, read back after the pods are gone.

import fake_worker/collector
import fake_worker/kill_record.{KillRecord}
import gleam/dict
import gleam/http
import gleam/http/request
import gleam/http/response

fn call(
  records: collector.Records,
  request: request.Request(String),
) -> #(response.Response(String), collector.Records) {
  collector.respond(request:, records:)
}

fn get(path: String) -> request.Request(String) {
  request.new() |> request.set_path(path)
}

fn put(path: String, body: String) -> request.Request(String) {
  get(path) |> request.set_method(http.Put) |> request.set_body(body)
}

fn with_method(path: String, method: http.Method) -> request.Request(String) {
  get(path) |> request.set_method(method)
}

const busy = KillRecord(pod: "w-1", busy: True, cost: 1800, accepting: True)

const idle = KillRecord(pod: "w-2", busy: False, cost: 0, accepting: True)

pub fn records_are_stored_by_pod_and_listed_sorted_test() -> Nil {
  let #(stored, records) =
    call(dict.new(), put("/kills/w-2", kill_record.encode(idle)))
  assert stored.status == 204
  let #(_, records) = call(records, put("/kills/w-1", kill_record.encode(busy)))
  let #(listed, after) = call(records, get("/kills"))
  assert after == records
  assert listed.status == 200
  assert response.get_header(listed, "content-type") == Ok("application/json")
  assert listed.body
    == "{\"kills\":["
    <> kill_record.encode(busy)
    <> ","
    <> kill_record.encode(idle)
    <> "]}"
}

pub fn a_repeated_delivery_counts_once_test() -> Nil {
  let #(_, once) = call(dict.new(), put("/kills/w-1", kill_record.encode(busy)))
  let #(again, twice) = call(once, put("/kills/w-1", kill_record.encode(busy)))
  assert again.status == 204
  assert twice == once
  assert dict.size(twice) == 1
}

pub fn delete_resets_test() -> Nil {
  let #(_, records) =
    call(dict.new(), put("/kills/w-1", kill_record.encode(busy)))
  let #(reset, empty) = call(records, with_method("/kills", http.Delete))
  assert reset.status == 204
  assert empty == dict.new()
  let #(listed, _) = call(empty, get("/kills"))
  assert listed.body == "{\"kills\":[]}"
}

pub fn a_record_must_name_its_own_pod_test() -> Nil {
  let #(refused, records) =
    call(dict.new(), put("/kills/w-9", kill_record.encode(busy)))
  assert refused.status == 400
  assert records == dict.new()
  let #(garbled, _) = call(dict.new(), put("/kills/w-1", "{}"))
  assert garbled.status == 400
}

pub fn routing_test() -> Nil {
  let #(health, _) = call(dict.new(), get("/healthz"))
  assert health.status == 200
  let #(missing, _) = call(dict.new(), get("/other"))
  assert missing.status == 404
  let #(post, _) = call(dict.new(), with_method("/kills", http.Post))
  assert post.status == 405
  assert response.get_header(post, "allow") == Ok("GET, DELETE")
  let #(get_one, _) = call(dict.new(), get("/kills/w-1"))
  assert get_one.status == 405
  assert response.get_header(get_one, "allow") == Ok("PUT")
}

pub fn kill_record_round_trips_test() -> Nil {
  assert kill_record.encode(busy)
    == "{\"pod\":\"w-1\",\"busy\":true,\"cost\":1800,\"accepting\":true}"
  assert kill_record.decode(kill_record.encode(busy)) == Ok(busy)
  assert kill_record.trace_line(idle)
    == "fake_worker kill " <> kill_record.encode(idle)
}
