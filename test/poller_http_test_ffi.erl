-module(poller_http_test_ffi).
-export([start_responder/1, stop_responder/1, closed_port/0,
  restart_profile/0, timed/1, gleam_toml_version/0]).

%% A plain gen_tcp loopback responder standing in for a worker's status
%% endpoint, on 127.0.0.1 or ::1. Each connection is read as one request
%% ({packet, http_bin}) and answered by path:
%%   /status      200 with a valid status object
%%   /missing     404
%%   /redirect    302 to /status
%%   /user-agent  200 whose body is every User-Agent value received, one a line
%%   /silent      accepted and read, never answered
%%   /reset       read, then closed with an RST ({linger, {true, 0}})
%% Handlers are linked to the acceptor, so stopping it stops them all.
start_responder(Family) ->
  {Ip, Opts} = case Family of
    <<"inet">> -> {{127, 0, 0, 1}, [inet]};
    <<"inet6">> -> {{0, 0, 0, 0, 0, 0, 0, 1}, [inet6]}
  end,
  Self = self(),
  Acceptor = spawn(fun() ->
    {ok, Listen} = gen_tcp:listen(0, Opts ++ [{ip, Ip}, binary, {active, false},
      {packet, http_bin}, {reuseaddr, true}]),
    {ok, Port} = inet:port(Listen),
    Self ! {port, self(), Port},
    accept(Listen)
  end),
  receive {port, Acceptor, Port} -> {Port, Acceptor} after 2000 -> error(no_responder) end.

stop_responder({_Port, Acceptor}) ->
  exit(Acceptor, kill),
  nil.

accept(Listen) ->
  {ok, Socket} = gen_tcp:accept(Listen),
  Handler = spawn_link(fun() -> receive go -> serve(Socket) end end),
  ok = gen_tcp:controlling_process(Socket, Handler),
  Handler ! go,
  accept(Listen).

serve(Socket) ->
  {ok, {http_request, _, {abs_path, Path}, _}} = gen_tcp:recv(Socket, 0, 2000),
  Agents = user_agents(Socket, []),
  answer(Path, Agents, Socket).

user_agents(Socket, Agents) ->
  case gen_tcp:recv(Socket, 0, 2000) of
    {ok, {http_header, _, 'User-Agent', _, Value}} -> user_agents(Socket, [Value | Agents]);
    {ok, {http_header, _, _, _, _}} -> user_agents(Socket, Agents);
    {ok, http_eoh} -> lists:reverse(Agents)
  end.

answer(<<"/status">>, _, Socket) ->
  reply(Socket, <<"200 OK">>, [{<<"Content-Type">>, <<"application/json">>}],
    <<"{\"cost\":5,\"accepting\":true}">>);
answer(<<"/missing">>, _, Socket) ->
  reply(Socket, <<"404 Not Found">>, [], <<>>);
answer(<<"/redirect">>, _, Socket) ->
  reply(Socket, <<"302 Found">>, [{<<"Location">>, <<"/status">>}], <<>>);
answer(<<"/user-agent">>, Agents, Socket) ->
  reply(Socket, <<"200 OK">>, [], iolist_to_binary(lists:join(<<"\n">>, Agents)));
answer(<<"/silent">>, _, _Socket) ->
  receive after infinity -> ok end;
answer(<<"/reset">>, _, Socket) ->
  ok = inet:setopts(Socket, [{linger, {true, 0}}]),
  gen_tcp:close(Socket).

reply(Socket, Status, Headers, Body) ->
  ok = inet:setopts(Socket, [{packet, raw}]),
  Head = [[Name, <<": ">>, Value, <<"\r\n">>] || {Name, Value} <- Headers],
  ok = gen_tcp:send(Socket, [<<"HTTP/1.1 ">>, Status, <<"\r\n">>, Head,
    <<"Content-Length: ">>, integer_to_binary(byte_size(Body)), <<"\r\n">>,
    <<"Connection: close\r\n\r\n">>, Body]),
  gen_tcp:close(Socket).

%% A port nothing listens on: bound, then released.
closed_port() ->
  {ok, Socket} = gen_tcp:listen(0, [{ip, {127, 0, 0, 1}}]),
  {ok, Port} = inet:port(Socket),
  gen_tcp:close(Socket),
  Port.

%% Kills the profile and waits for its supervisor to register a new one.
restart_profile() ->
  Old = whereis(knarr_poller_httpc),
  true = is_pid(Old),
  Monitor = monitor(process, Old),
  exit(Old, kill),
  receive {'DOWN', Monitor, process, Old, killed} -> ok after 2000 -> error(no_crash) end,
  await_restart(Old, 100).

await_restart(_Old, 0) -> error(no_restart);
await_restart(Old, Attempts) ->
  case whereis(knarr_poller_httpc) of
    New when is_pid(New), New =/= Old -> true;
    _ -> timer:sleep(20), await_restart(Old, Attempts - 1)
  end.

%% Runs Fun and returns its result with the milliseconds it took.
timed(Fun) ->
  Start = erlang:monotonic_time(millisecond),
  Result = Fun(),
  {Result, erlang:monotonic_time(millisecond) - Start}.

%% The version line of gleam.toml, the source the .app vsn is generated from.
gleam_toml_version() ->
  {ok, Toml} = file:read_file("gleam.toml"),
  {match, [Version]} = re:run(Toml, <<"(?m)^version = \"([^\"]+)\"$">>,
    [{capture, all_but_first, binary}]),
  Version.
