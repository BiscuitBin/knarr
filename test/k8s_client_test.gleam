//// Tests for the k8s_client contract's builders, decoders and joins. The
//// builders and decoders are pure, so their tests pass values in and read
//// values out; the joins go through closure fakes.

import birdie
import gleam/dict
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import http_picture
import knarr/k8s_client.{
  Conflict, CreateOperation, Deployment, Event, Failure, Forbidden,
  ListOperation, NotFound, Other, Owner, Page, PatchOperation, Pod,
  PreconditionFailed, Refused, ReplicaSet, Target, Throttled,
}
import qcheck

const target = Target(host: "10.96.0.1", port: 443)

// A kind apiserver's pod list, cut down: two pods, one terminating, one with
// no annotations map at all, and more fields than the decoder reads.
const pod_list_body =
  "{
  \"kind\": \"PodList\",
  \"apiVersion\": \"v1\",
  \"metadata\": {\"resourceVersion\": \"1234\"},
  \"items\": [
    {
      \"metadata\": {
        \"name\": \"knarr-7d4b9c-abcde\",
        \"namespace\": \"default\",
        \"uid\": \"6f1c\",
        \"annotations\": {\"knarr.io/s1-probe\": \"1760000000\"},
        \"labels\": {\"app.kubernetes.io/name\": \"knarr\"},
        \"ownerReferences\": [
          {\"apiVersion\": \"apps/v1\", \"kind\": \"ReplicaSet\", \"name\": \"knarr-7d4b9c\", \"uid\": \"rs-1\", \"controller\": true, \"blockOwnerDeletion\": true}
        ]
      },
      \"spec\": {\"nodeName\": \"kind-control-plane\"},
      \"status\": {
        \"phase\": \"Running\",
        \"podIP\": \"10.244.0.7\",
        \"conditions\": [
          {\"type\": \"Initialized\", \"status\": \"True\"},
          {\"type\": \"Ready\", \"status\": \"True\"}
        ]
      }
    },
    {
      \"metadata\": {
        \"name\": \"knarr-7d4b9c-zzzzz\",
        \"namespace\": \"default\",
        \"uid\": \"7a2d\",
        \"deletionTimestamp\": \"2026-10-09T05:00:00Z\"
      },
      \"status\": {\"phase\": \"Running\"}
    }
  ]
}"

const patched_pod_body =
  "{
  \"kind\": \"Pod\",
  \"apiVersion\": \"v1\",
  \"metadata\": {
    \"name\": \"knarr-7d4b9c-abcde\",
    \"uid\": \"6f1c\",
    \"annotations\": {\"knarr.io/s1-probe\": \"1760000060\"}
  }
}"

const replica_set_list_body =
  "{
  \"kind\": \"ReplicaSetList\",
  \"apiVersion\": \"apps/v1\",
  \"metadata\": {\"resourceVersion\": \"88\"},
  \"items\": [
    {
      \"metadata\": {
        \"name\": \"worker-5f6c\",
        \"uid\": \"rs-1\",
        \"ownerReferences\": [
          {\"apiVersion\": \"apps/v1\", \"kind\": \"Deployment\", \"name\": \"worker\", \"uid\": \"dep-1\", \"controller\": true}
        ]
      },
      \"spec\": {\"replicas\": 3}
    },
    {
      \"metadata\": {
        \"name\": \"orphan-1a2b\",
        \"uid\": \"rs-2\",
        \"ownerReferences\": [
          {\"apiVersion\": \"v1\", \"kind\": \"ConfigMap\", \"name\": \"not-a-controller\", \"uid\": \"cm-1\"}
        ]
      }
    }
  ]
}"

const deployment_list_body =
  "{
  \"kind\": \"DeploymentList\",
  \"apiVersion\": \"apps/v1\",
  \"metadata\": {\"resourceVersion\": \"99\"},
  \"items\": [
    {
      \"metadata\": {
        \"name\": \"worker\",
        \"uid\": \"dep-1\",
        \"labels\": {\"app\": \"worker\"},
        \"annotations\": {\"knarr.io/enabled\": \"true\"}
      },
      \"spec\": {\"replicas\": 3}
    },
    {
      \"metadata\": {\"name\": \"bare\", \"uid\": \"dep-2\"}
    }
  ]
}"

const forbidden_body =
  "{\"kind\":\"Status\",\"status\":\"Failure\",\"message\":\"pods is forbidden\",\"reason\":\"Forbidden\",\"code\":403}"

const event =
  Event(
    pod_name: "knarr-7d4b9c-abcde",
    pod_uid: "6f1c",
    reason: "AnnotationYielded",
    message: "controller.kubernetes.io/pod-deletion-cost: knarr applied 5 and found 9; another writer owns it now and knarr will not write it again on this pod",
    at: "2026-10-12T05:00:00Z",
  )

// The probe's first write on a pod with no annotations map.
const document =
  "[{\"op\":\"test\",\"path\":\"/metadata/deletionTimestamp\",\"value\":null},{\"op\":\"test\",\"path\":\"/metadata/annotations\",\"value\":null},{\"op\":\"add\",\"path\":\"/metadata/annotations\",\"value\":{\"knarr.io/s1-probe\":\"1760000060\"}}]"

fn ok(status: Int, body: String) -> response.Response(String) {
  response.new(status) |> response.set_body(body)
}

fn page_body(items: List(String), continue: String) -> String {
  "{\"metadata\":{\"continue\":\""
  <> continue
  <> "\"},\"items\":["
  <> string.join(items, ",")
  <> "]}"
}

fn pod_item(name: String) -> String {
  "{\"metadata\":{\"name\":\"" <> name <> "\",\"uid\":\"u-" <> name <> "\"}}"
}

// Builders.

pub fn list_pods_request_gets_the_first_page_of_namespace_pods_test() -> Nil {
  let request =
    k8s_client.list_pods_request(
      target:,
      namespace: "default",
      token: "test-token",
      continue: None,
    )

  assert request.method == http.Get
  assert request.scheme == http.Https
  assert request.host == "10.96.0.1"
  assert request.port == Some(443)
  assert request.path == "/api/v1/namespaces/default/pods"
  assert request.query == Some("limit=500")
  assert request.body == ""
  assert request.headers
    == [
      #("accept", "application/json"),
      #("authorization", "Bearer test-token"),
    ]
}

pub fn list_requests_percent_encode_the_continue_token_test() -> Nil {
  let continue = Some("eyJ2Ijo+/x=")
  let pods =
    k8s_client.list_pods_request(
      target:,
      namespace: "default",
      token: "t",
      continue:,
    )
  let replica_sets =
    k8s_client.list_replica_sets_request(
      target:,
      namespace: "default",
      token: "t",
      continue:,
    )
  let deployments =
    k8s_client.list_deployments_request(
      target:,
      namespace: "default",
      token: "t",
      continue:,
    )

  let query = Some("limit=500&continue=eyJ2Ijo%2B%2Fx%3D")
  assert pods.query == query
  assert replica_sets.query == query
  assert deployments.query == query
}

pub fn list_replica_sets_request_gets_the_apps_group_test() -> Nil {
  let request =
    k8s_client.list_replica_sets_request(
      target:,
      namespace: "workers",
      token: "test-token",
      continue: None,
    )

  assert request.method == http.Get
  assert request.path == "/apis/apps/v1/namespaces/workers/replicasets"
  assert request.query == Some("limit=500")
}

pub fn list_deployments_request_gets_the_apps_group_test() -> Nil {
  let request =
    k8s_client.list_deployments_request(
      target:,
      namespace: "workers",
      token: "test-token",
      continue: None,
    )

  assert request.method == http.Get
  assert request.path == "/apis/apps/v1/namespaces/workers/deployments"
  assert request.query == Some("limit=500")
}

pub fn patch_pod_request_sends_the_document_as_a_json_patch_test() -> Nil {
  let request =
    k8s_client.patch_pod_request(
      target:,
      namespace: "default",
      pod: "knarr-7d4b9c-abcde",
      token: "test-token",
      document:,
    )

  assert request.method == http.Patch
  assert request.scheme == http.Https
  assert request.path == "/api/v1/namespaces/default/pods/knarr-7d4b9c-abcde"
  assert request.query == None
  assert request.headers
    == [
      #("accept", "application/json"),
      #("authorization", "Bearer test-token"),
      #("content-type", "application/json-patch+json"),
    ]
  assert request.body == document
}

pub fn create_event_request_posts_a_warning_on_the_pod_test() -> Nil {
  let request =
    k8s_client.create_event_request(
      target:,
      namespace: "default",
      token: "test-token",
      event:,
    )

  assert request.method == http.Post
  assert request.path == "/api/v1/namespaces/default/events"
  assert request.headers
    == [
      #("accept", "application/json"),
      #("authorization", "Bearer test-token"),
      #("content-type", "application/json"),
    ]
  assert request.body
    == json.to_string(
      json.object([
        #(
          "metadata",
          json.object([#("generateName", json.string("knarr-7d4b9c-abcde."))]),
        ),
        #(
          "involvedObject",
          json.object([
            #("apiVersion", json.string("v1")),
            #("kind", json.string("Pod")),
            #("namespace", json.string("default")),
            #("name", json.string("knarr-7d4b9c-abcde")),
            #("uid", json.string("6f1c")),
          ]),
        ),
        #("reason", json.string("AnnotationYielded")),
        #("message", json.string(event.message)),
        #("type", json.string("Warning")),
        #("source", json.object([#("component", json.string("knarr"))])),
        #("count", json.int(1)),
        #("firstTimestamp", json.string("2026-10-12T05:00:00Z")),
        #("lastTimestamp", json.string("2026-10-12T05:00:00Z")),
      ]),
    )
}

pub fn an_ipv6_host_is_bracketed_test() -> Nil {
  let request =
    k8s_client.list_pods_request(
      target: Target(host: "fd00:10:96::1", port: 443),
      namespace: "default",
      token: "t",
      continue: None,
    )

  assert request.host == "[fd00:10:96::1]"
  assert http_picture.request(request)
    |> string.starts_with(
      "GET https://[fd00:10:96::1]:443/api/v1/namespaces/default/pods?limit=500",
    )
}

// Decoders.

pub fn decode_pod_page_reads_every_field_the_client_uses_test() -> Nil {
  assert k8s_client.decode_pod_page(ok(200, pod_list_body))
    == Ok(Page(
      items: [
        Pod(
          name: "knarr-7d4b9c-abcde",
          uid: "6f1c",
          annotations: Some(
            dict.from_list([#("knarr.io/s1-probe", "1760000000")]),
          ),
          deletion_timestamp: None,
          pod_ip: Some("10.244.0.7"),
          ready: True,
          owner: Some(Owner(
            kind: "ReplicaSet",
            name: "knarr-7d4b9c",
            uid: "rs-1",
          )),
        ),
        Pod(
          name: "knarr-7d4b9c-zzzzz",
          uid: "7a2d",
          annotations: None,
          deletion_timestamp: Some("2026-10-09T05:00:00Z"),
          pod_ip: None,
          ready: False,
          owner: None,
        ),
      ],
      continue: None,
    ))
}

pub fn decode_pod_page_reads_an_empty_annotations_map_as_empty_test() -> Nil {
  // The apiserver omits an empty map, so this is the only place one arises.
  let body =
    "{\"metadata\":{},\"items\":[{\"metadata\":{\"name\":\"p\",\"uid\":\"u\",\"annotations\":{}}}]}"

  let page = k8s_client.decode_pod_page(ok(200, body)) |> should.be_ok
  assert list.map(page.items, fn(pod) { pod.annotations }) == [Some(dict.new())]
}

pub fn decode_pod_page_reads_ready_only_from_a_true_ready_condition_test() -> Nil {
  let ready = fn(conditions: String) {
    let body =
      "{\"metadata\":{},\"items\":[{\"metadata\":{\"name\":\"p\",\"uid\":\"u\"},\"status\":{\"conditions\":"
      <> conditions
      <> "}}]}"
    let page = k8s_client.decode_pod_page(ok(200, body)) |> should.be_ok
    list.map(page.items, fn(pod) { pod.ready })
  }

  assert ready("[{\"type\":\"Ready\",\"status\":\"True\"}]") == [True]
  assert ready("[{\"type\":\"Ready\",\"status\":\"False\"}]") == [False]
  assert ready("[{\"type\":\"Ready\",\"status\":\"Unknown\"}]") == [False]
  assert ready("[{\"type\":\"ContainersReady\",\"status\":\"True\"}]")
    == [False]
  assert ready("[]") == [False]
}

pub fn decode_pod_page_reads_the_continue_token_test() -> Nil {
  assert k8s_client.decode_pod_page(ok(200, page_body([pod_item("a")], "abc")))
    |> should.be_ok
    |> fn(page) { page.continue }
    == Some("abc")
  assert k8s_client.decode_pod_page(ok(200, page_body([pod_item("a")], "")))
    |> should.be_ok
    |> fn(page) { page.continue }
    == None
}

pub fn decode_replica_set_page_reads_the_controller_owner_only_test() -> Nil {
  assert k8s_client.decode_replica_set_page(ok(200, replica_set_list_body))
    == Ok(Page(
      items: [
        ReplicaSet(
          name: "worker-5f6c",
          uid: "rs-1",
          owner: Some(Owner(kind: "Deployment", name: "worker", uid: "dep-1")),
        ),
        ReplicaSet(name: "orphan-1a2b", uid: "rs-2", owner: None),
      ],
      continue: None,
    ))
}

pub fn decode_deployment_page_reads_labels_and_annotations_test() -> Nil {
  assert k8s_client.decode_deployment_page(ok(200, deployment_list_body))
    == Ok(Page(
      items: [
        Deployment(
          name: "worker",
          uid: "dep-1",
          labels: dict.from_list([#("app", "worker")]),
          annotations: dict.from_list([#("knarr.io/enabled", "true")]),
        ),
        Deployment(
          name: "bare",
          uid: "dep-2",
          labels: dict.new(),
          annotations: dict.new(),
        ),
      ],
      continue: None,
    ))
}

pub fn decode_pod_page_reports_a_truncated_body_test() -> Nil {
  assert k8s_client.decode_pod_page(ok(200, "{\"items\": ["))
    == Error(k8s_client.UndecodableBody(json.UnexpectedEndOfInput))
}

pub fn decode_patched_pod_reads_the_pod_the_apiserver_returns_test() -> Nil {
  assert k8s_client.decode_patched_pod(ok(200, patched_pod_body))
    == Ok(Pod(
      name: "knarr-7d4b9c-abcde",
      uid: "6f1c",
      annotations: Some(dict.from_list([#("knarr.io/s1-probe", "1760000060")])),
      deletion_timestamp: None,
      pod_ip: None,
      ready: False,
      owner: None,
    ))
}

pub fn decode_created_event_accepts_201_only_test() -> Nil {
  assert k8s_client.decode_created_event(ok(201, "{}")) == Ok(Nil)
  assert k8s_client.decode_created_event(ok(200, "{}"))
    == Error(
      Refused(Failure(reason: Other, status: 200, retry_after: None, body: "{}")),
    )
}

// Failures.

fn with_retry_after(status: Int, value: String) -> response.Response(String) {
  ok(status, "{}") |> response.set_header("retry-after", value)
}

pub fn failures_are_classified_by_status_alone_test() -> Nil {
  let reason = fn(status, operation) {
    k8s_client.failure(response: ok(status, forbidden_body), operation:).reason
  }

  assert reason(403, ListOperation) == Forbidden
  assert reason(404, PatchOperation) == NotFound
  assert reason(409, PatchOperation) == Conflict
  assert reason(429, CreateOperation) == Throttled
  assert reason(422, PatchOperation) == PreconditionFailed
  assert reason(422, ListOperation) == Other
  assert reason(422, CreateOperation) == Other
  assert reason(400, PatchOperation) == Other
  assert reason(500, ListOperation) == Other
}

pub fn a_failure_keeps_its_status_and_body_test() -> Nil {
  assert k8s_client.failure(
      response: ok(403, forbidden_body),
      operation: ListOperation,
    )
    == Failure(
      reason: Forbidden,
      status: 403,
      retry_after: None,
      body: forbidden_body,
    )
}

pub fn retry_after_is_read_in_whole_seconds_only_test() -> Nil {
  let retry_after = fn(value) {
    k8s_client.failure(
      response: with_retry_after(429, value),
      operation: ListOperation,
    ).retry_after
  }

  assert retry_after("7") == Some(7)
  assert retry_after("0") == Some(0)
  assert retry_after("Wed, 21 Oct 2026 07:28:00 GMT") == None
  assert retry_after("-1") == None
  assert retry_after("+7") == None
  assert retry_after("1.5") == None
  assert retry_after("") == None
}

pub fn only_a_precondition_failure_is_one_test() -> Nil {
  let failure = fn(status) {
    k8s_client.failure(response: ok(status, ""), operation: PatchOperation)
  }

  assert k8s_client.precondition_failed(failure(422))
  assert !k8s_client.precondition_failed(failure(404))
  assert !k8s_client.precondition_failed(failure(409))
}

pub fn decoders_report_a_refusal_with_its_retry_after_test() -> Nil {
  let throttled = with_retry_after(429, "7")
  let refused =
    Refused(Failure(
      reason: Throttled,
      status: 429,
      retry_after: Some(7),
      body: "{}",
    ))

  assert k8s_client.decode_pod_page(throttled) == Error(refused)
  assert k8s_client.decode_replica_set_page(throttled) == Error(refused)
  assert k8s_client.decode_deployment_page(throttled) == Error(refused)
  assert k8s_client.decode_patched_pod(throttled) == Error(refused)
  assert k8s_client.decode_created_event(throttled) == Error(refused)
}

pub fn a_422_is_a_precondition_failure_from_a_patch_only_test() -> Nil {
  let response = ok(422, "{}")

  assert k8s_client.decode_patched_pod(response)
    == Error(
      Refused(Failure(
        reason: PreconditionFailed,
        status: 422,
        retry_after: None,
        body: "{}",
      )),
    )
  assert k8s_client.decode_pod_page(response)
    == Error(
      Refused(Failure(reason: Other, status: 422, retry_after: None, body: "{}")),
    )
}

// Joins.

pub fn list_pods_follows_continue_tokens_and_concatenates_pages_test() -> Nil {
  let send = fn(request: Request(String)) {
    case request.query {
      Some("limit=500") -> Ok(ok(200, page_body([pod_item("a")], "one")))
      Some("limit=500&continue=one") ->
        Ok(ok(200, page_body([pod_item("b"), pod_item("c")], "two")))
      Some("limit=500&continue=two") ->
        Ok(ok(200, page_body([pod_item("d")], "")))
      _ -> Error("unexpected continue token")
    }
  }

  let pods =
    k8s_client.list_pods(target:, namespace: "default", token: "t", send:)
    |> should.be_ok
  assert list.map(pods, fn(pod) { pod.name }) == ["a", "b", "c", "d"]
}

pub fn a_failing_page_fails_the_whole_list_test() -> Nil {
  let send = fn(request: Request(String)) {
    case request.query {
      Some("limit=500") -> Ok(ok(200, page_body([pod_item("a")], "one")))
      _ -> Ok(with_retry_after(429, "3"))
    }
  }

  assert k8s_client.list_pods(target:, namespace: "default", token: "t", send:)
    == Error(
      Refused(Failure(
        reason: Throttled,
        status: 429,
        retry_after: Some(3),
        body: "{}",
      )),
    )
}

pub fn list_replica_sets_and_deployments_page_the_same_way_test() -> Nil {
  let send = fn(body) {
    fn(request: Request(String)) {
      case request.query {
        Some("limit=500") -> Ok(ok(200, body))
        _ -> Error("a page without a continue token is the last")
      }
    }
  }

  let replica_sets =
    k8s_client.list_replica_sets(
      target:,
      namespace: "default",
      token: "t",
      send: send(replica_set_list_body),
    )
    |> should.be_ok
  let deployments =
    k8s_client.list_deployments(
      target:,
      namespace: "default",
      token: "t",
      send: send(deployment_list_body),
    )
    |> should.be_ok
  assert list.map(replica_sets, fn(replica_set) { replica_set.name })
    == ["worker-5f6c", "orphan-1a2b"]
  assert list.map(deployments, fn(deployment) { deployment.name })
    == ["worker", "bare"]
}

pub fn list_pods_keeps_the_error_send_returned_test() -> Nil {
  let send = fn(_request) { Error("connection refused") }

  assert k8s_client.list_pods(
      target:,
      namespace: "default",
      token: "test-token",
      send:,
    )
    == Error(k8s_client.SendFailed("connection refused"))
}

pub fn patch_pod_sends_the_built_request_and_decodes_the_reply_test() -> Nil {
  let send = fn(request) {
    assert request
      == k8s_client.patch_pod_request(
        target:,
        namespace: "default",
        pod: "knarr-7d4b9c-abcde",
        token: "test-token",
        document:,
      )
    Ok(ok(200, patched_pod_body))
  }

  let pod =
    k8s_client.patch_pod(
      target:,
      namespace: "default",
      pod: "knarr-7d4b9c-abcde",
      token: "test-token",
      document:,
      send:,
    )
    |> should.be_ok
  assert pod.annotations
    == Some(dict.from_list([#("knarr.io/s1-probe", "1760000060")]))
}

pub fn patch_pod_keeps_the_error_send_returned_test() -> Nil {
  let send = fn(_request) { Error("tls alert") }

  assert k8s_client.patch_pod(
      target:,
      namespace: "default",
      pod: "knarr-7d4b9c-abcde",
      token: "test-token",
      document:,
      send:,
    )
    == Error(k8s_client.SendFailed("tls alert"))
}

pub fn create_event_sends_one_request_test() -> Nil {
  let send = fn(request) {
    assert request
      == k8s_client.create_event_request(
        target:,
        namespace: "default",
        token: "test-token",
        event:,
      )
    Ok(ok(201, "{}"))
  }

  assert k8s_client.create_event(
      target:,
      namespace: "default",
      token: "test-token",
      event:,
      send:,
    )
    == Ok(Nil)
}

// A property in the gate takes a fixed seed (docs/reference/testing.md).
// Any annotation key and value a JSON Patch adds, the decoder reads back from
// the pod the apiserver returns, which carries the added map.
pub fn patched_annotation_reads_back_any_encoded_key_and_value_test() -> Nil {
  let config = qcheck.default_config() |> qcheck.with_seed(qcheck.seed(14))
  let annotations = qcheck.tuple2(qcheck.string(), qcheck.string())
  use #(key, value) <- qcheck.run(config, annotations)
  let map = json.object([#(key, json.string(value))])
  let document =
    json.to_string(
      json.preprocessed_array([
        json.object([
          #("op", json.string("add")),
          #("path", json.string("/metadata/annotations")),
          #("value", map),
        ]),
      ]),
    )
  let request =
    k8s_client.patch_pod_request(
      target:,
      namespace: "default",
      pod: "p",
      token: "test-token",
      document:,
    )
  // The apiserver returns the patched pod: its annotations are the added map.
  let added = json.to_string(map)
  assert string.contains(request.body, added)
  let body =
    "{\"metadata\":{\"name\":\"p\",\"uid\":\"u\",\"annotations\":"
    <> added
    <> "}}"

  assert k8s_client.decode_patched_pod(ok(200, body))
    == Ok(Pod(
      name: "p",
      uid: "u",
      annotations: Some(dict.from_list([#(key, value)])),
      deletion_timestamp: None,
      pod_ip: None,
      ready: False,
      owner: None,
    ))
}

// Pictures are taken inside the fakes, so each is exactly the request the
// function handed to send. The named tests above are what prove them.
pub fn snapshot_list_pods_request_test() -> Nil {
  let send = fn(request) {
    http_picture.request(request)
    |> birdie.snap(title: "pod list request sent by list_pods")
    Ok(ok(200, pod_list_body))
  }

  k8s_client.list_pods(
    target:,
    namespace: "default",
    token: "test-token",
    send:,
  )
  |> should.be_ok
  Nil
}

pub fn snapshot_list_replica_sets_request_test() -> Nil {
  let send = fn(request) {
    http_picture.request(request)
    |> birdie.snap(title: "replica set list request sent by list_replica_sets")
    Ok(ok(200, replica_set_list_body))
  }

  k8s_client.list_replica_sets(
    target:,
    namespace: "default",
    token: "test-token",
    send:,
  )
  |> should.be_ok
  Nil
}

pub fn snapshot_list_deployments_request_test() -> Nil {
  let send = fn(request) {
    http_picture.request(request)
    |> birdie.snap(title: "deployment list request sent by list_deployments")
    Ok(ok(200, deployment_list_body))
  }

  k8s_client.list_deployments(
    target:,
    namespace: "default",
    token: "test-token",
    send:,
  )
  |> should.be_ok
  Nil
}

pub fn snapshot_patch_pod_request_test() -> Nil {
  let send = fn(request) {
    http_picture.request(request)
    |> birdie.snap(title: "json patch request sent by patch_pod")
    Ok(ok(200, patched_pod_body))
  }

  k8s_client.patch_pod(
    target:,
    namespace: "default",
    pod: "knarr-7d4b9c-abcde",
    token: "test-token",
    document:,
    send:,
  )
  |> should.be_ok
  Nil
}

pub fn snapshot_create_event_request_test() -> Nil {
  let send = fn(request) {
    http_picture.request(request)
    |> birdie.snap(title: "event create request sent by create_event")
    Ok(ok(201, "{}"))
  }

  k8s_client.create_event(
    target:,
    namespace: "default",
    token: "test-token",
    event:,
    send:,
  )
  |> should.be_ok
  Nil
}
