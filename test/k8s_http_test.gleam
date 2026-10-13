//// The TLS transport against a loopback responder whose CA and server
//// certificates are built in memory (`public_key:pkix_test_data/1`), so no key
//// is committed. The server certificate carries an IP subjectAltName for
//// 127.0.0.1, and the client connects to the string "127.0.0.1", the form
//// KUBERNETES_SERVICE_HOST takes. A second listener serves a certificate
//// from the same CA whose only subjectAltName is a DNS name, so the hostname
//// check is what refuses it; a third chain is an unrelated CA. The responder
//// answers `/sni` with the server_name it received, so a test can watch what
//// the OTP pin sends for an IP host.

import gleam/erlang/process.{type Pid}
import gleam/http
import gleam/http/request
import gleam/http/response
import gleeunit/should
import knarr/k8s_http.{Tls}

/// A loopback TLS responder: its port, the port serving a same-CA certificate
/// without the IP subjectAltName, the file holding its CA, the file holding
/// an unrelated CA, and the count of requests that reached `/unavailable`.
pub type Responder {
  Responder(
    port: Int,
    wrong_host_port: Int,
    ca_file: String,
    other_ca_file: String,
    acceptor: Pid,
    wrong_host_acceptor: Pid,
    hits: Hits,
  )
}

/// The responder's request counter, an Erlang atomics reference.
pub type Hits

@external(erlang, "k8s_http_test_ffi", "start_responder")
fn start_responder() -> Responder

@external(erlang, "k8s_http_test_ffi", "start_ipv6_responder")
fn start_ipv6_responder() -> Responder

@external(erlang, "k8s_http_test_ffi", "stop_responder")
fn stop_responder(responder: Responder) -> Nil

@external(erlang, "k8s_http_test_ffi", "hits")
fn hits(responder: Responder) -> Int

@external(erlang, "k8s_http_test_ffi", "closed_port")
fn closed_port() -> Int

fn get(port: Int) -> request.Request(String) {
  request.new()
  |> request.set_scheme(http.Https)
  |> request.set_host("127.0.0.1")
  |> request.set_port(port)
  |> request.set_path("/api/v1/namespaces/default/pods")
  |> request.set_header("accept", "application/json")
}

pub fn send_completes_a_verified_handshake_with_the_right_ca_test() -> Nil {
  let responder = start_responder()
  let response =
    get(responder.port) |> k8s_http.send(Tls(responder.ca_file)) |> should.be_ok
  stop_responder(responder)

  assert response.status == 200
  assert response.body == "{\"kind\":\"PodList\",\"items\":[]}"
  assert response.get_header(response, "content-type") == Ok("application/json")
}

pub fn send_completes_a_verified_handshake_with_an_ipv6_host_test() -> Nil {
  // KUBERNETES_SERVICE_HOST may be an IPv6 literal; the client brackets it
  // in the URL (ServiceAddress) and the peer's iPAddress SAN is ::1.
  let responder = start_ipv6_responder()
  let response =
    get(responder.port)
    |> request.set_host("[::1]")
    |> k8s_http.send(Tls(responder.ca_file))
    |> should.be_ok
  stop_responder(responder)

  assert response.status == 200
  assert response.body == "{\"kind\":\"PodList\",\"items\":[]}"
}

pub fn send_refuses_an_ipv6_peer_whose_certificate_names_another_ip_test() -> Nil {
  // Same CA, but the only subjectAltName is 127.0.0.1: the hostname check
  // still runs for an IPv6 host.
  let responder = start_ipv6_responder()
  let result =
    get(responder.wrong_host_port)
    |> request.set_host("[::1]")
    |> k8s_http.send(Tls(responder.ca_file))
  stop_responder(responder)

  assert result == Error(k8s_http.TlsAlert("bad_certificate"))
}

pub fn send_refuses_a_wrong_ca_with_no_fallback_test() -> Nil {
  let responder = start_responder()
  let result =
    get(responder.port) |> k8s_http.send(Tls(responder.other_ca_file))
  stop_responder(responder)

  assert result == Error(k8s_http.TlsAlert("unknown_ca"))
}

pub fn send_refuses_a_same_ca_certificate_without_the_ip_san_test() -> Nil {
  // The certificate chains to the configured CA, so only the hostname check
  // can refuse it: its single subjectAltName is a DNS name, not 127.0.0.1.
  let responder = start_responder()
  let result =
    get(responder.wrong_host_port) |> k8s_http.send(Tls(responder.ca_file))
  stop_responder(responder)

  assert result == Error(k8s_http.TlsAlert("bad_certificate"))
}

pub fn send_reports_a_closed_port_test() -> Nil {
  let responder = start_responder()
  let result = get(closed_port()) |> k8s_http.send(Tls(responder.ca_file))
  stop_responder(responder)

  assert result == Error(k8s_http.ConnectFailed("econnrefused"))
}

pub fn send_sends_the_ip_literal_as_sni_on_this_pin_test() -> Nil {
  // OTP 29 sends a string IP host as the server_name, although RFC 6066 §3
  // does not permit an IP literal in HostName. Decision 0013 keeps the
  // default, because disabling SNI also disables the hostname check on this
  // pin; if this fails, the pin has moved and 0013's SNI row reopens.
  let responder = start_responder()
  let response =
    get(responder.port)
    |> request.set_path("/sni")
    |> k8s_http.send(Tls(responder.ca_file))
    |> should.be_ok
  stop_responder(responder)

  assert response.body == "127.0.0.1"
}

pub fn send_passes_content_type_as_httpc_own_argument_test() -> Nil {
  // The responder echoes the request head it received in its body, so the
  // test can count content-type lines: httpc takes the content type as its
  // own argument, and a PATCH must not carry the header twice.
  let responder = start_responder()
  let response =
    get(responder.port)
    |> request.set_method(http.Patch)
    |> request.set_path("/echo")
    |> request.set_header("content-type", "application/json-patch+json")
    |> request.set_body("{}")
    |> k8s_http.send(Tls(responder.ca_file))
    |> should.be_ok
  stop_responder(responder)

  assert response.status == 200
  assert count_lines(response.body, "content-type: application/json-patch+json")
    == 1
  assert count_lines(response.body, "accept: application/json") == 1
}

@external(erlang, "k8s_http_test_ffi", "count_lines")
fn count_lines(text: String, line: String) -> Int

pub fn send_returns_a_503_with_retry_after_without_retrying_test() -> Nil {
  // httpc resends any request once after a 503 whose Retry-After it can
  // read, unless autoretry is 0. A create is one attempt (ConflictEvent), and
  // the 503 and its Retry-After are the caller's to read (Failures). The
  // responder answers a second request with 200, so a retry shows here.
  let responder = start_responder()
  let response =
    get(responder.port)
    |> request.set_method(http.Post)
    |> request.set_path("/unavailable")
    |> request.set_header("content-type", "application/json")
    |> request.set_body("{}")
    |> k8s_http.send(Tls(responder.ca_file))
    |> should.be_ok
  let hits = hits(responder)
  stop_responder(responder)

  assert response.status == 503
  assert response.get_header(response, "retry-after") == Ok("0")
  assert hits == 1
}

pub fn send_reports_a_method_httpc_does_not_take_as_a_value_test() -> Nil {
  let responder = start_responder()
  let result =
    get(responder.port)
    |> request.set_method(http.Other("PROPFIND"))
    |> k8s_http.send(Tls(responder.ca_file))
  stop_responder(responder)

  assert result
    == Error(k8s_http.Other("{unsupported_method,<<\"PROPFIND\">>}"))
}

pub fn send_refuses_a_body_without_a_content_type_as_a_value_test() -> Nil {
  let responder = start_responder()
  let result =
    get(responder.port)
    |> request.set_method(http.Post)
    |> request.set_body("{}")
    |> k8s_http.send(Tls(responder.ca_file))
  stop_responder(responder)

  assert result == Error(k8s_http.Other("body without content-type"))
}
