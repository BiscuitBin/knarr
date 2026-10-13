//// Spike S1's probe (ticket 14): a supervised loop that, every tick, reads
//// the projected token from disk, lists the pods in its own namespace and
//// sets the `knarr.io/s1-probe` annotation on its own pod with a JSON Patch,
//// through the k8s_client contract. It is the scaffolding that proved
//// VerifiedTls, TokenReload and Verbs on a cluster, and ticket 31 removes it
//// when the reconciler takes over. Every outcome is a logged value; nothing here
//// panics on a `Result`.

import gleam/erlang/process.{type Subject}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import gleam/otp/supervision
import gleam/string
import knarr/k8s_client.{type Pod, type Target, Target}
import knarr/k8s_http.{type SendError, Tls}
import knarr/token

/// The annotation the probe writes, and the only thing it writes.
const annotation_key = "knarr.io/s1-probe"

pub type Config {
  Config(
    target: Target,
    namespace_file: String,
    token_file: String,
    pod_name: String,
    interval_ms: Int,
    /// How requests reach the apiserver. Production passes `k8s_http.send`
    /// with the service-account CA; a test passes a closure.
    send: fn(Request(String)) -> Result(Response(String), SendError),
  )
}

/// A config by position, for the application callback in Erlang. It is the
/// one place a field order is spelled out in Erlang.
pub fn config(
  host host: String,
  port port: Int,
  namespace_file namespace_file: String,
  token_file token_file: String,
  ca_file ca_file: String,
  pod_name pod_name: String,
  interval_ms interval_ms: Int,
) -> Config {
  Config(
    target: Target(host:, port:),
    namespace_file:,
    token_file:,
    pod_name:,
    interval_ms:,
    send: k8s_http.send(_, Tls(ca_file)),
  )
}

pub type Message {
  Tick
}

type State {
  State(config: Config, self: Subject(Message), token_sha256: Option(String))
}

/// The probe under its own supervisor: three restarts a minute before the
/// root sees one failure, so a crashing probe cannot take the listener down
/// with it inside the root's two-in-five-seconds tolerance.
pub fn supervised(
  config: Config,
) -> supervision.ChildSpecification(supervisor.Supervisor) {
  supervisor.new(supervisor.OneForOne)
  |> supervisor.restart_tolerance(intensity: 3, period: 60)
  |> supervisor.add(
    supervision.worker(fn() { start(config) })
    |> supervision.timeout(ms: 15_000),
  )
  |> supervisor.supervised
}

/// Starts the probe. Its initialiser does no I/O: it only schedules the
/// first tick.
pub fn start(config: Config) -> actor.StartResult(Subject(Message)) {
  actor.new_with_initialiser(1000, fn(self) {
    process.send_after(self, config.interval_ms, Tick)
    actor.initialised(State(config:, self:, token_sha256: None))
    |> actor.returning(self)
    |> Ok
  })
  |> actor.on_message(on_message)
  |> actor.start
}

fn on_message(state: State, message: Message) -> actor.Next(State, Message) {
  let Tick = message
  let state = tick(state)
  process.send_after(state.self, state.config.interval_ms, Tick)
  actor.continue(state)
}

fn tick(state: State) -> State {
  let config = state.config
  case read_file(config.token_file) {
    Error(ReadFailed(reason)) -> {
      log("token_read_failed", [#("reason", reason)])
      state
    }
    Ok(token) -> {
      let token = string.trim(token)
      let sha256 = sha256_hex12(token)
      let state = case state.token_sha256 == Some(sha256) {
        True -> state
        False -> {
          log("token_changed", [
            #("token_sha256", sha256),
            #("jwt_exp", jwt_exp(token)),
          ])
          State(..state, token_sha256: Some(sha256))
        }
      }
      case read_file(config.namespace_file) {
        Error(ReadFailed(reason)) ->
          log("namespace_read_failed", [#("reason", reason)])
        Ok(namespace) ->
          cycle(config:, namespace: string.trim(namespace), token:)
      }
      state
    }
  }
}

/// One LIST, then one PATCH of this pod if the list shows it live.
fn cycle(
  config config: Config,
  namespace namespace: String,
  token token: String,
) -> Nil {
  case
    k8s_client.list_pods(
      target: config.target,
      namespace:,
      token:,
      send: config.send,
    )
  {
    Error(error) -> log("list_pods_failed", [#("error", describe(error))])
    Ok(pods) -> {
      log("list_pods", [#("count", int.to_string(list.length(pods)))])
      let value = int.to_string(unix_seconds())
      case probe_patch(pods:, pod_name: config.pod_name, value:) {
        None -> log("patch_skipped", [#("pod", config.pod_name)])
        Some(document) -> patch(config:, namespace:, token:, document:, value:)
      }
    }
  }
}

fn patch(
  config config: Config,
  namespace namespace: String,
  token token: String,
  document document: String,
  value value: String,
) -> Nil {
  case
    k8s_client.patch_pod(
      target: config.target,
      namespace:,
      pod: config.pod_name,
      token:,
      document:,
      send: config.send,
    )
  {
    Error(error) ->
      log("patch_annotation_failed", [#("error", describe(error))])
    Ok(_) ->
      log("patch_annotation", [#("pod", config.pod_name), #("value", value)])
  }
}

/// The JSON Patch that sets the probe's annotation on `pod_name`, or `None`
/// when the most recent list does not show the pod or shows it terminating
/// (NoPatchWhileTerminating). The patch first tests that
/// /metadata/deletionTimestamp is still null, so a deletion in the window
/// after the list fails it with 422. A test under a missing parent fails, so
/// when the pod has no annotations map the patch tests the map for null and
/// adds it whole, as ownership's WriteMode does.
pub fn probe_patch(
  pods pods: List(Pod),
  pod_name pod_name: String,
  value value: String,
) -> Option(String) {
  case list.find(pods, fn(pod) { pod.name == pod_name }) {
    Ok(k8s_client.Pod(deletion_timestamp: None, annotations:, ..)) -> {
      let live = test_null("/metadata/deletionTimestamp")
      let operations = case annotations {
        Some(_) -> [
          live,
          add(
            "/metadata/annotations/" <> pointer(annotation_key),
            json.string(value),
          ),
        ]
        None -> [
          live,
          test_null("/metadata/annotations"),
          add(
            "/metadata/annotations",
            json.object([#(annotation_key, json.string(value))]),
          ),
        ]
      }
      Some(json.to_string(json.preprocessed_array(operations)))
    }
    _ -> None
  }
}

fn test_null(path: String) -> json.Json {
  json.object([
    #("op", json.string("test")),
    #("path", json.string(path)),
    #("value", json.null()),
  ])
}

fn add(path: String, value: json.Json) -> json.Json {
  json.object([
    #("op", json.string("add")),
    #("path", json.string(path)),
    #("value", value),
  ])
}

/// A key as a JSON Pointer segment: ~ as ~0, then / as ~1.
fn pointer(key: String) -> String {
  key |> string.replace("~", "~0") |> string.replace("/", "~1")
}

fn jwt_exp(token: String) -> String {
  case token.jwt_expiry(token) {
    Ok(exp) -> int.to_string(exp)
    Error(token.NotThreeSegments) -> "not_a_jwt"
    Error(token.NotBase64Url) -> "claims_not_base64url"
    Error(token.NotJsonClaims) -> "claims_not_json"
    Error(token.NoExpClaim) -> "no_exp_claim"
    Error(token.ExpNotAnInteger) -> "exp_not_an_integer"
  }
}

/// A bounded rendering of a client error. A refusal keeps its reason, its
/// Retry-After and the start of the apiserver's body; no error value carries
/// the token.
fn describe(error: k8s_client.ClientError(SendError)) -> String {
  case error {
    k8s_client.Refused(failure) ->
      "status "
      <> int.to_string(failure.status)
      <> " "
      <> reason(failure.reason)
      <> retry_after(failure.retry_after)
    k8s_client.UndecodableBody(_) -> "undecodable_body"
    k8s_client.SendFailed(k8s_http.TlsAlert(alert)) -> "tls_alert " <> alert
    k8s_client.SendFailed(k8s_http.ConnectFailed(reason)) ->
      "connect_failed " <> reason
    k8s_client.SendFailed(k8s_http.Timeout) -> "timeout"
    k8s_client.SendFailed(k8s_http.Other(reason)) -> "other " <> reason
  }
}

fn reason(reason: k8s_client.Reason) -> String {
  case reason {
    k8s_client.Forbidden -> "forbidden"
    k8s_client.NotFound -> "not_found"
    k8s_client.Conflict -> "conflict"
    k8s_client.PreconditionFailed -> "precondition_failed"
    k8s_client.Throttled -> "throttled"
    k8s_client.Other -> "other"
  }
}

fn retry_after(seconds: Option(Int)) -> String {
  case seconds {
    Some(seconds) -> " retry_after=" <> int.to_string(seconds)
    None -> ""
  }
}

fn log(event: String, fields: List(#(String, String))) -> Nil {
  let line =
    list.map(fields, fn(field) { field.0 <> "=" <> field.1 })
    |> string.join(" ")
  log_notice("s1_probe event=" <> event <> " " <> line)
}

/// Why a file could not be read: the POSIX reason, such as `enoent`.
type ReadError {
  ReadFailed(reason: String)
}

@external(erlang, "s1_probe_ffi", "read_file")
fn read_file(path: String) -> Result(String, ReadError)

@external(erlang, "s1_probe_ffi", "sha256_hex12")
fn sha256_hex12(data: String) -> String

@external(erlang, "s1_probe_ffi", "unix_seconds")
fn unix_seconds() -> Int

@external(erlang, "s1_probe_ffi", "log_notice")
fn log_notice(line: String) -> Nil
