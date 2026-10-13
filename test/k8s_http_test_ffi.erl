-module(k8s_http_test_ffi).
-export([start_responder/0, start_ipv6_responder/0, stop_responder/1, hits/1, closed_port/0, count_lines/2]).
-include_lib("public_key/include/public_key.hrl").

%% A loopback TLS responder. Its CA and leaves come from
%% public_key:pkix_test_data/1, in memory; only the CA PEMs are written, under
%% build/, so the client can be given a cacertfile. The main leaf carries an
%% iPAddress subjectAltName for 127.0.0.1, which the https hostname check
%% matches a string IP host against. A second listener serves a leaf signed
%% by the same CA key whose only subjectAltName is a DNS name, so the CA
%% check passes and the hostname check is the one that refuses it. A third
%% chain is an unrelated CA. Each connection serves one request; serve/1 says
%% what each path answers, /sni among them. A counter records the requests
%% that reach /unavailable, so a test can see whether httpc sent one again.
start_responder() ->
  {ok, _} = application:ensure_all_started(ssl),
  {ok, _} = application:ensure_all_started(inets),
  Dir = filename:join(["build", "k8s_http_test", integer_to_list(erlang:unique_integer([positive]))]),
  ok = filelib:ensure_path(Dir),
  RootKey = public_key:generate_key({rsa, 2048, 65537}),
  Server = chain(RootKey, {iPAddress, <<127, 0, 0, 1>>}),
  WrongHost = chain(RootKey, {dNSName, "kubernetes.default.svc"}),
  Other = chain(public_key:generate_key({rsa, 2048, 65537}), {iPAddress, <<127, 0, 0, 1>>}),
  CaFile = write_ca(Dir, "ca.pem", Server),
  OtherCaFile = write_ca(Dir, "other-ca.pem", Other),
  Hits = atomics:new(1, []),
  {Port, Acceptor} = listen(Server, loopback, Hits),
  {WrongHostPort, WrongHostAcceptor} = listen(WrongHost, loopback, Hits),
  {responder, Port, WrongHostPort, unicode:characters_to_binary(CaFile),
    unicode:characters_to_binary(OtherCaFile), Acceptor, WrongHostAcceptor, Hits}.

%% The same responder on ::1. The main leaf's iPAddress subjectAltName is
%% ::1; the wrong-host leaf, from the same CA, names only 127.0.0.1, so the
%% hostname check is what refuses it when the client asks for ::1.
start_ipv6_responder() ->
  {ok, _} = application:ensure_all_started(ssl),
  {ok, _} = application:ensure_all_started(inets),
  Dir = filename:join(["build", "k8s_http_test", integer_to_list(erlang:unique_integer([positive]))]),
  ok = filelib:ensure_path(Dir),
  RootKey = public_key:generate_key({rsa, 2048, 65537}),
  Server = chain(RootKey, {iPAddress, <<0:120, 1>>}),
  WrongHost = chain(RootKey, {iPAddress, <<127, 0, 0, 1>>}),
  Other = chain(public_key:generate_key({rsa, 2048, 65537}), {iPAddress, <<0:120, 1>>}),
  CaFile = write_ca(Dir, "ca.pem", Server),
  OtherCaFile = write_ca(Dir, "other-ca.pem", Other),
  Hits = atomics:new(1, []),
  {Port, Acceptor} = listen(Server, ipv6_loopback, Hits),
  {WrongHostPort, WrongHostAcceptor} = listen(WrongHost, ipv6_loopback, Hits),
  {responder, Port, WrongHostPort, unicode:characters_to_binary(CaFile),
    unicode:characters_to_binary(OtherCaFile), Acceptor, WrongHostAcceptor, Hits}.

stop_responder({responder, _, _, _, _, Acceptor, WrongHostAcceptor, _}) ->
  exit(Acceptor, kill),
  exit(WrongHostAcceptor, kill),
  nil.

hits({responder, _, _, _, _, _, _, Hits}) -> atomics:get(Hits, 1).

%% One CA key can sign several chains: pkix_test_data/1 takes the root key as
%% a value, so two chains built from the same RootKey share a CA.
chain(RootKey, San) ->
  Extension = #'Extension'{extnID = ?'id-ce-subjectAltName',
    extnValue = [San], critical = false},
  public_key:pkix_test_data(#{root => [{key, RootKey}], intermediates => [],
    peer => [{key, {rsa, 2048, 65537}}, {extensions, [Extension]}]}).

listen(Conf, Address, Hits) ->
  Ip = case Address of
    loopback -> [{ip, {127, 0, 0, 1}}];
    ipv6_loopback -> [inet6, {ip, {0, 0, 0, 0, 0, 0, 0, 1}}]
  end,
  {ok, Listen} = ssl:listen(0, Ip ++ [{reuseaddr, true}, {active, false}, binary,
                                {cert, proplists:get_value(cert, Conf)},
                                {key, proplists:get_value(key, Conf)}]),
  {ok, {_, Port}} = ssl:sockname(Listen),
  {Port, spawn(fun() -> accept(Listen, Hits) end)}.

%% On OTP 29, pkix_test_data/1 returns the root twice in cacerts when
%% intermediates is [] (evidence/14/tls.txt: "cacerts entries: 2, distinct:
%% 1"). lists:usort writes it once, which stays right if a later pin stops
%% repeating it.
write_ca(Dir, Name, Conf) ->
  CaCerts = lists:usort(proplists:get_value(cacerts, Conf)),
  Path = filename:join(Dir, Name),
  ok = file:write_file(Path, public_key:pem_encode([{'Certificate', C, not_encrypted} || C <- CaCerts])),
  Path.

accept(Listen, Hits) ->
  case ssl:transport_accept(Listen) of
    {ok, Transport} -> spawn(fun() -> serve(Transport, Hits) end), accept(Listen, Hits);
    {error, _} -> ok
  end.

%% One request per connection. /echo answers with the request head it
%% received, one lower-cased "name: value" line per header; /sni answers with
%% the server_name the client sent, or none when it sent none; /unavailable
%% answers its first request with a 503 carrying "retry-after: 0" and any
%% later one with an empty pod list; any other path answers an empty pod
%% list.
serve(Transport, Hits) ->
  case ssl:handshake(Transport, 5000) of
    {ok, Socket} ->
      ok = ssl:setopts(Socket, [{packet, http_bin}]),
      case read_head(Socket, undefined, []) of
        {ok, Path, Head} ->
          PodList = <<"{\"kind\":\"PodList\",\"items\":[]}">>,
          {Status, Headers, Body} = case Path of
            <<"/echo">> -> {<<"200 OK">>, [], Head};
            <<"/sni">> -> {<<"200 OK">>, [], sni(Socket)};
            <<"/unavailable">> -> unavailable(Hits, PodList);
            _ -> {<<"200 OK">>, [], PodList}
          end,
          ok = ssl:send(Socket, [<<"HTTP/1.1 ">>, Status, <<"\r\ncontent-type: application/json\r\n">>,
            [[Header, <<"\r\n">>] || Header <- Headers], <<"content-length: ">>,
            integer_to_binary(byte_size(Body)), <<"\r\nconnection: close\r\n\r\n">>, Body]);
        error -> ok
      end,
      ssl:close(Socket);
    {error, _} -> ok
  end.

read_head(Socket, Path, Lines) ->
  case ssl:recv(Socket, 0, 2000) of
    {ok, {http_request, _, {abs_path, RequestPath}, _}} -> read_head(Socket, RequestPath, Lines);
    {ok, {http_header, _, Name, _, Value}} ->
      Line = <<(string:lowercase(name(Name)))/binary, ": ", Value/binary>>,
      read_head(Socket, Path, [Line | Lines]);
    {ok, http_eoh} -> {ok, Path, iolist_to_binary(lists:join(<<"\n">>, lists:reverse(Lines)))};
    _ -> error
  end.

name(Name) when is_atom(Name) -> atom_to_binary(Name);
name(Name) -> Name.

%% Any answer other than a name or its absence is rendered, so a failing
%% test shows what the pin returned instead of reading as no SNI.
sni(Socket) ->
  case ssl:connection_information(Socket, [sni_hostname]) of
    {ok, [{sni_hostname, Host}]} when is_list(Host) -> unicode:characters_to_binary(Host);
    {ok, [{sni_hostname, undefined}]} -> <<"none">>;
    {ok, []} -> <<"none">>;
    Other -> unicode:characters_to_binary(io_lib:format("~0p", [Other]))
  end.

%% httpc retries a request once after a 503 whose Retry-After it can read,
%% unless autoretry is 0. "0" makes that retry immediate, and its 200 tells
%% the test it happened.
unavailable(Hits, PodList) ->
  case atomics:add_get(Hits, 1, 1) of
    1 -> {<<"503 Service Unavailable">>, [<<"retry-after: 0">>], <<"{}">>};
    _ -> {<<"200 OK">>, [], PodList}
  end.

closed_port() ->
  {ok, Socket} = gen_tcp:listen(0, [{ip, {127, 0, 0, 1}}]),
  {ok, {_, Port}} = inet:sockname(Socket),
  gen_tcp:close(Socket),
  Port.

count_lines(Text, Line) ->
  length([L || L <- string:split(Text, <<"\n">>, all), L =:= Line]).
