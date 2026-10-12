//// What a worker leaves behind when SIGTERM arrives: its pod, whether it was
//// busy, and the cost and accepting it reported at that moment. The collector
//// keeps one per pod, so a run can count busy kills after the pods are gone.

import gleam/dynamic/decode
import gleam/json

pub type KillRecord {
  KillRecord(pod: String, busy: Bool, cost: Int, accepting: Bool)
}

pub fn to_json(record: KillRecord) -> json.Json {
  json.object([
    #("pod", json.string(record.pod)),
    #("busy", json.bool(record.busy)),
    #("cost", json.int(record.cost)),
    #("accepting", json.bool(record.accepting)),
  ])
}

pub fn encode(record: KillRecord) -> String {
  record |> to_json |> json.to_string
}

fn decoder() -> decode.Decoder(KillRecord) {
  use pod <- decode.field("pod", decode.string)
  use busy <- decode.field("busy", decode.bool)
  use cost <- decode.field("cost", decode.int)
  use accepting <- decode.field("accepting", decode.bool)
  decode.success(KillRecord(pod:, busy:, cost:, accepting:))
}

pub fn decode(body: String) -> Result(KillRecord, json.DecodeError) {
  json.parse(body, decoder())
}

/// The line a worker prints when SIGTERM arrives. It is a trace for reading a
/// pod's log, not the sink: it goes when the pod object goes.
pub fn trace_line(record: KillRecord) -> String {
  "fake_worker kill " <> encode(record)
}
