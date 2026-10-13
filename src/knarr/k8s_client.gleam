//// The k8s_client contract (docs/specs/k8s_client.allium): pure request
//// builders and response decoders for every request the controller makes
//// (list on pods, ReplicaSets and Deployments, a JSON Patch of one pod, the
//// create of a conflict Event), joined by functions that do I/O only through
//// the `send` they are given (Decision 0002). Production passes
//// `k8s_http.send` with the service-account CA; a test passes a closure.

import gleam/bool
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri

/// The apiserver, as `KUBERNETES_SERVICE_HOST` and `_PORT` name it: an IPv4
/// or IPv6 literal (ServiceAddress).
pub type Target {
  Target(host: String, port: Int)
}

/// The ownerReference whose `controller` flag is true.
pub type Owner {
  Owner(kind: String, name: String, uid: String)
}

/// What the client reads of a pod. `annotations` is `None` when the response
/// carries no annotations map, the case ownership's WriteMode branches on;
/// `ready` is whether the Ready condition is "True".
pub type Pod {
  Pod(
    name: String,
    uid: String,
    annotations: Option(Dict(String, String)),
    deletion_timestamp: Option(String),
    pod_ip: Option(String),
    ready: Bool,
    owner: Option(Owner),
  )
}

pub type ReplicaSet {
  ReplicaSet(name: String, uid: String, owner: Option(Owner))
}

/// A Deployment's labels and annotations, raw; an absent map is empty.
pub type Deployment {
  Deployment(
    name: String,
    uid: String,
    labels: Dict(String, String),
    annotations: Dict(String, String),
  )
}

/// The conflict Event ownership's Event raises on a pod. `at` is an RFC 3339
/// time, written as both its first and last timestamp.
pub type Event {
  Event(
    pod_name: String,
    pod_uid: String,
    reason: String,
    message: String,
    at: String,
  )
}

/// One page of a LIST, and the token that asks for the next, if any.
pub type Page(a) {
  Page(items: List(a), continue: Option(String))
}

/// Which request a response answers: a 422 means something different from a
/// patch.
pub type Operation {
  ListOperation
  PatchOperation
  CreateOperation
}

/// How a refused response is classified, by its status alone (Failures).
pub type Reason {
  Forbidden
  NotFound
  Conflict
  PreconditionFailed
  Throttled
  Other
}

/// A refused response: its reason, its status, its Retry-After in seconds and
/// its body, which is kept for the log and never read to classify.
pub type Failure {
  Failure(reason: Reason, status: Int, retry_after: Option(Int), body: String)
}

/// Why a call returned no value. `e` is the error type of the `send` it was
/// given.
pub type ClientError(e) {
  SendFailed(e)
  Refused(Failure)
  UndecodableBody(json.DecodeError)
}

/// The most items one LIST page asks for (Pagination).
const page_limit = 500

/// `GET /api/v1/namespaces/{namespace}/pods`, one page, as the bearer of
/// `token`.
pub fn list_pods_request(
  target target: Target,
  namespace namespace: String,
  token token: String,
  continue continue: Option(String),
) -> Request(String) {
  list_request(
    target:,
    token:,
    path: "/api/v1/namespaces/" <> namespace <> "/pods",
    continue:,
  )
}

/// `GET /apis/apps/v1/namespaces/{namespace}/replicasets`, one page.
pub fn list_replica_sets_request(
  target target: Target,
  namespace namespace: String,
  token token: String,
  continue continue: Option(String),
) -> Request(String) {
  list_request(
    target:,
    token:,
    path: "/apis/apps/v1/namespaces/" <> namespace <> "/replicasets",
    continue:,
  )
}

/// `GET /apis/apps/v1/namespaces/{namespace}/deployments`, one page.
pub fn list_deployments_request(
  target target: Target,
  namespace namespace: String,
  token token: String,
  continue continue: Option(String),
) -> Request(String) {
  list_request(
    target:,
    token:,
    path: "/apis/apps/v1/namespaces/" <> namespace <> "/deployments",
    continue:,
  )
}

fn list_request(
  target target: Target,
  token token: String,
  path path: String,
  continue continue: Option(String),
) -> Request(String) {
  let limit = #("limit", int.to_string(page_limit))
  let query = case continue {
    None -> [limit]
    Some(token) -> [limit, #("continue", token)]
  }
  // Not request.set_query: it leaves + bare, which the apiserver reads as a
  // space.
  request.Request(
    ..base_request(target:, token:)
    |> request.set_method(http.Get)
    |> request.set_path(path),
    query: Some(uri.query_to_string(query)),
  )
}

/// `PATCH /api/v1/namespaces/{namespace}/pods/{pod}` with `document`, the
/// JSON Patch ownership renders, sent as given.
pub fn patch_pod_request(
  target target: Target,
  namespace namespace: String,
  pod pod: String,
  token token: String,
  document document: String,
) -> Request(String) {
  base_request(target:, token:)
  |> request.set_method(http.Patch)
  |> request.set_path("/api/v1/namespaces/" <> namespace <> "/pods/" <> pod)
  |> request.set_header("content-type", "application/json-patch+json")
  |> request.set_body(document)
}

/// `POST /api/v1/namespaces/{namespace}/events`: one Warning on the pod,
/// named from the prefix `<pod>.` (ConflictEvent).
pub fn create_event_request(
  target target: Target,
  namespace namespace: String,
  token token: String,
  event event: Event,
) -> Request(String) {
  let body =
    json.object([
      #(
        "metadata",
        json.object([#("generateName", json.string(event.pod_name <> "."))]),
      ),
      #(
        "involvedObject",
        json.object([
          #("apiVersion", json.string("v1")),
          #("kind", json.string("Pod")),
          #("namespace", json.string(namespace)),
          #("name", json.string(event.pod_name)),
          #("uid", json.string(event.pod_uid)),
        ]),
      ),
      #("reason", json.string(event.reason)),
      #("message", json.string(event.message)),
      #("type", json.string("Warning")),
      #("source", json.object([#("component", json.string("knarr"))])),
      #("count", json.int(1)),
      #("firstTimestamp", json.string(event.at)),
      #("lastTimestamp", json.string(event.at)),
    ])
  base_request(target:, token:)
  |> request.set_method(http.Post)
  |> request.set_path("/api/v1/namespaces/" <> namespace <> "/events")
  |> request.set_header("content-type", "application/json")
  |> request.set_body(json.to_string(body))
}

/// An IPv6 host is bracketed, so the URL the adapter renders is well formed
/// (ServiceAddress).
fn base_request(target target: Target, token token: String) -> Request(String) {
  let host = case string.contains(target.host, ":") {
    True -> "[" <> target.host <> "]"
    False -> target.host
  }
  request.new()
  |> request.set_scheme(http.Https)
  |> request.set_host(host)
  |> request.set_port(target.port)
  |> request.set_header("accept", "application/json")
  |> request.set_header("authorization", "Bearer " <> token)
}

/// Reads one page of pods. Only a 200 carries one.
pub fn decode_pod_page(
  response: Response(String),
) -> Result(Page(Pod), ClientError(e)) {
  decode_page(response, pod_decoder())
}

/// Reads one page of ReplicaSets. Only a 200 carries one.
pub fn decode_replica_set_page(
  response: Response(String),
) -> Result(Page(ReplicaSet), ClientError(e)) {
  decode_page(response, {
    use #(name, uid, owner) <- decode.field("metadata", {
      use name <- decode.field("name", decode.string)
      use uid <- decode.field("uid", decode.string)
      use owner <- decode.then(owner_decoder())
      decode.success(#(name, uid, owner))
    })
    decode.success(ReplicaSet(name:, uid:, owner:))
  })
}

/// Reads one page of Deployments. Only a 200 carries one.
pub fn decode_deployment_page(
  response: Response(String),
) -> Result(Page(Deployment), ClientError(e)) {
  decode_page(response, {
    use deployment <- decode.field("metadata", {
      use name <- decode.field("name", decode.string)
      use uid <- decode.field("uid", decode.string)
      use labels <- decode.then(string_map("labels"))
      use annotations <- decode.then(string_map("annotations"))
      decode.success(Deployment(
        name:,
        uid:,
        labels: option.unwrap(labels, dict.new()),
        annotations: option.unwrap(annotations, dict.new()),
      ))
    })
    decode.success(deployment)
  })
}

/// Reads the pod a patch reply returns. Only a 200 carries one; a 422 is a
/// precondition failure.
pub fn decode_patched_pod(
  response: Response(String),
) -> Result(Pod, ClientError(e)) {
  decode_success(
    response:,
    success: 200,
    operation: PatchOperation,
    decoder: pod_decoder(),
  )
}

/// A create reply. Only a 201 is success.
pub fn decode_created_event(
  response: Response(String),
) -> Result(Nil, ClientError(e)) {
  decode_success(
    response:,
    success: 201,
    operation: CreateOperation,
    decoder: decode.success(Nil),
  )
}

/// Classifies a refused response by its status alone (Failures) and reads
/// its Retry-After (RetryAfter).
pub fn failure(
  response response: Response(String),
  operation operation: Operation,
) -> Failure {
  let reason = case response.status, operation {
    403, _ -> Forbidden
    404, _ -> NotFound
    409, _ -> Conflict
    422, PatchOperation -> PreconditionFailed
    429, _ -> Throttled
    _, _ -> Other
  }
  let retry_after =
    response.get_header(response, "retry-after")
    |> option.from_result
    |> option.then(seconds)
  Failure(reason:, status: response.status, retry_after:, body: response.body)
}

/// Whether a failure is the 422 a failed `test` in a patch returns, which
/// ownership's Precondition and Rejected branch on.
pub fn precondition_failed(failure: Failure) -> Bool {
  failure.reason == PreconditionFailed
}

/// A non-negative decimal integer and nothing else; an HTTP-date is `None`.
fn seconds(value: String) -> Option(Int) {
  let digits = string.to_graphemes(value)
  case
    digits != []
    && list.all(digits, fn(digit) { string.contains("0123456789", digit) })
  {
    True -> int.parse(value) |> option.from_result
    False -> None
  }
}

fn decode_page(
  response: Response(String),
  item: decode.Decoder(a),
) -> Result(Page(a), ClientError(e)) {
  decode_success(response:, success: 200, operation: ListOperation, decoder: {
    use items <- decode.field("items", decode.list(item))
    use continue <- decode.optional_field(
      "metadata",
      None,
      decode.optional_field(
        "continue",
        None,
        decode.optional(decode.string),
        decode.success,
      ),
    )
    let continue = case continue {
      Some("") -> None
      continue -> continue
    }
    decode.success(Page(items:, continue:))
  })
}

fn decode_success(
  response response: Response(String),
  success success: Int,
  operation operation: Operation,
  decoder decoder: decode.Decoder(a),
) -> Result(a, ClientError(e)) {
  use <- bool.guard(
    response.status != success,
    Error(Refused(failure(response:, operation:))),
  )
  json.parse(response.body, decoder) |> result.map_error(UndecodableBody)
}

fn pod_decoder() -> decode.Decoder(Pod) {
  use #(name, uid, annotations, deletion_timestamp, owner) <- decode.field(
    "metadata",
    {
      use name <- decode.field("name", decode.string)
      use uid <- decode.field("uid", decode.string)
      use annotations <- decode.then(string_map("annotations"))
      use deletion_timestamp <- decode.optional_field(
        "deletionTimestamp",
        None,
        decode.optional(decode.string),
      )
      use owner <- decode.then(owner_decoder())
      decode.success(#(name, uid, annotations, deletion_timestamp, owner))
    },
  )
  use #(pod_ip, ready) <- decode.optional_field("status", #(None, False), {
    use pod_ip <- decode.optional_field(
      "podIP",
      None,
      decode.optional(decode.string),
    )
    use conditions <- decode.optional_field(
      "conditions",
      [],
      decode.list({
        use kind <- decode.field("type", decode.string)
        use status <- decode.field("status", decode.string)
        decode.success(#(kind, status))
      }),
    )
    decode.success(#(pod_ip, list.contains(conditions, #("Ready", "True"))))
  })
  decode.success(Pod(
    name:,
    uid:,
    annotations:,
    deletion_timestamp:,
    pod_ip:,
    ready:,
    owner:,
  ))
}

/// A map of strings under `name`: `None` when the field is absent or null,
/// `Some` of the map, possibly empty, otherwise.
fn string_map(name: String) -> decode.Decoder(Option(Dict(String, String))) {
  decode.optional_field(
    name,
    None,
    decode.optional(decode.dict(decode.string, decode.string)),
    decode.success,
  )
}

/// The first ownerReference whose `controller` flag is true.
fn owner_decoder() -> decode.Decoder(Option(Owner)) {
  use references <- decode.optional_field(
    "ownerReferences",
    [],
    decode.list({
      use kind <- decode.field("kind", decode.string)
      use name <- decode.field("name", decode.string)
      use uid <- decode.field("uid", decode.string)
      use controller <- decode.optional_field("controller", False, decode.bool)
      decode.success(#(Owner(kind:, name:, uid:), controller))
    }),
  )
  list.find(references, fn(reference) { reference.1 })
  |> result.map(fn(reference) { reference.0 })
  |> option.from_result
  |> decode.success
}

/// Lists the pods in `namespace`, every page (Pagination). The only I/O is
/// the calls to `send`.
pub fn list_pods(
  target target: Target,
  namespace namespace: String,
  token token: String,
  send send: fn(Request(String)) -> Result(Response(String), e),
) -> Result(List(Pod), ClientError(e)) {
  list_all(
    fn(continue) { list_pods_request(target:, namespace:, token:, continue:) },
    decode_pod_page,
    send,
  )
}

/// Lists the ReplicaSets in `namespace`, every page.
pub fn list_replica_sets(
  target target: Target,
  namespace namespace: String,
  token token: String,
  send send: fn(Request(String)) -> Result(Response(String), e),
) -> Result(List(ReplicaSet), ClientError(e)) {
  list_all(
    fn(continue) {
      list_replica_sets_request(target:, namespace:, token:, continue:)
    },
    decode_replica_set_page,
    send,
  )
}

/// Lists the Deployments in `namespace`, every page.
pub fn list_deployments(
  target target: Target,
  namespace namespace: String,
  token token: String,
  send send: fn(Request(String)) -> Result(Response(String), e),
) -> Result(List(Deployment), ClientError(e)) {
  list_all(
    fn(continue) {
      list_deployments_request(target:, namespace:, token:, continue:)
    },
    decode_deployment_page,
    send,
  )
}

/// Follows continue tokens until a page carries none. A failure on any page
/// fails the whole LIST, and the pages already read are dropped.
fn list_all(
  build: fn(Option(String)) -> Request(String),
  decode_page: fn(Response(String)) -> Result(Page(a), ClientError(e)),
  send: fn(Request(String)) -> Result(Response(String), e),
) -> Result(List(a), ClientError(e)) {
  list_pages(build, decode_page, send, None, [])
}

fn list_pages(
  build: fn(Option(String)) -> Request(String),
  decode_page: fn(Response(String)) -> Result(Page(a), ClientError(e)),
  send: fn(Request(String)) -> Result(Response(String), e),
  continue: Option(String),
  pages: List(List(a)),
) -> Result(List(a), ClientError(e)) {
  use response <- result.try(
    build(continue) |> send |> result.map_error(SendFailed),
  )
  use page <- result.try(decode_page(response))
  let pages = [page.items, ..pages]
  case page.continue {
    None -> Ok(pages |> list.reverse |> list.flatten)
    continue -> list_pages(build, decode_page, send, continue, pages)
  }
}

/// Sends `document` as a JSON Patch of `pod` and returns the pod the
/// apiserver sends back, the newest view. The only I/O is the call to `send`.
pub fn patch_pod(
  target target: Target,
  namespace namespace: String,
  pod pod: String,
  token token: String,
  document document: String,
  send send: fn(Request(String)) -> Result(Response(String), e),
) -> Result(Pod, ClientError(e)) {
  use response <- result.try(
    patch_pod_request(target:, namespace:, pod:, token:, document:)
    |> send
    |> result.map_error(SendFailed),
  )
  decode_patched_pod(response)
}

/// Creates `event`, one attempt and no retry. The only I/O is the call to
/// `send`.
pub fn create_event(
  target target: Target,
  namespace namespace: String,
  token token: String,
  event event: Event,
  send send: fn(Request(String)) -> Result(Response(String), e),
) -> Result(Nil, ClientError(e)) {
  use response <- result.try(
    create_event_request(target:, namespace:, token:, event:)
    |> send
    |> result.map_error(SendFailed),
  )
  decode_created_event(response)
}
