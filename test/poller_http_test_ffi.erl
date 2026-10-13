-module(poller_http_test_ffi).
-export([start_responder/1, stop_responder/1, closed_port/0,
  restart_profile_during/1, kill_profile_during_admission/1,
  helper_dies_with_caller/1,
  without_profile/1, with_profile_suspended/1, without_ca_bundle/1,
  mailbox_size/0, timed/1, gleam_toml_version/0]).

-define(PROFILE, knarr_poller_httpc).

%% A plain gen_tcp loopback responder standing in for a worker's status
%% endpoint, on 127.0.0.1 or ::1. Each connection is read as one request
%% ({packet, http_bin}) and answered by path:
%%   /status      200 with a valid status object
%%   /missing     404
%%   /redirect    302 to /status
%%   /user-agent  200 whose body is every User-Agent value received, one a line
%%   /host        200 whose body is every Host value received, one a line
%%   /unavailable 503 with Retry-After: 1
%%   /silent      accepted and read, never answered
%%   /held        read, then {held, Handler} sent to the process that started
%%                the responder, never answered
%%   /late        read, then answered with /status's reply after 400 ms
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
    accept(Listen, Self)
  end),
  receive {port, Acceptor, Port} -> {Port, Acceptor} after 2000 -> error(no_responder) end.

stop_responder({_Port, Acceptor}) ->
  exit(Acceptor, kill),
  nil.

accept(Listen, Owner) ->
  {ok, Socket} = gen_tcp:accept(Listen),
  Handler = spawn_link(fun() -> receive go -> serve(Socket, Owner) end end),
  ok = gen_tcp:controlling_process(Socket, Handler),
  Handler ! go,
  accept(Listen, Owner).

serve(Socket, Owner) ->
  {ok, {http_request, _, {abs_path, Path}, _}} = gen_tcp:recv(Socket, 0, 2000),
  Headers = headers(Socket, []),
  case Path of
    <<"/held">> ->
      Owner ! {held, self()},
      receive after infinity -> ok end;
    <<"/late">> ->
      timer:sleep(400),
      answer(<<"/status">>, Headers, Socket);
    _ -> answer(Path, Headers, Socket)
  end.

headers(Socket, Headers) ->
  case gen_tcp:recv(Socket, 0, 2000) of
    {ok, {http_header, _, Name, _, Value}} -> headers(Socket, [{Name, Value} | Headers]);
    {ok, http_eoh} -> lists:reverse(Headers)
  end.

values(Name, Headers) ->
  iolist_to_binary(lists:join(<<"\n">>, [Value || {N, Value} <- Headers, N =:= Name])).

answer(<<"/status">>, _, Socket) ->
  reply(Socket, <<"200 OK">>, [{<<"Content-Type">>, <<"application/json">>}],
    <<"{\"cost\":5,\"accepting\":true}">>);
answer(<<"/missing">>, _, Socket) ->
  reply(Socket, <<"404 Not Found">>, [], <<>>);
answer(<<"/redirect">>, _, Socket) ->
  reply(Socket, <<"302 Found">>, [{<<"Location">>, <<"/status">>}], <<>>);
answer(<<"/user-agent">>, Headers, Socket) ->
  reply(Socket, <<"200 OK">>, [], values('User-Agent', Headers));
answer(<<"/host">>, Headers, Socket) ->
  reply(Socket, <<"200 OK">>, [], values('Host', Headers));
answer(<<"/unavailable">>, _, Socket) ->
  reply(Socket, <<"503 Service Unavailable">>, [{<<"Retry-After">>, <<"1">>}], <<>>);
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

%% Starts Poll, which must poll /held, in a process of its own, kills the
%% profile once the responder has read the request, waits for the profile's
%% supervisor to register a new one, and returns what the poll returned with
%% the milliseconds it took after the kill.
restart_profile_during(Poll) ->
  Self = self(),
  Old = whereis(?PROFILE),
  true = is_pid(Old),
  {Poller, PollerMonitor} = spawn_monitor(fun() -> Self ! {polled, self(), Poll()} end),
  receive {held, _} -> ok after 2000 -> error(not_held) end,
  kill_and_collect(Old, Poller, PollerMonitor).

%% Suspends the profile so the poll's request waits in its queue, unanswered,
%% then kills the profile while the poll is still being admitted. Returns as
%% restart_profile_during does.
kill_profile_during_admission(Poll) ->
  Self = self(),
  Old = whereis(?PROFILE),
  true = is_pid(Old),
  ok = sys:suspend(Old),
  {Poller, PollerMonitor} = spawn_monitor(fun() -> Self ! {polled, self(), Poll()} end),
  true = await_queued(Old, 100),
  kill_and_collect(Old, Poller, PollerMonitor).

%% Suspends the profile so Poll's request waits for admission, runs Poll in
%% a process of its own, finds the helper that process monitors, kills the
%% process, and returns whether the helper died within 500 ms. A helper
%% still alive then is killed, and the profile is resumed after.
helper_dies_with_caller(Poll) ->
  Profile = whereis(?PROFILE),
  true = is_pid(Profile),
  ok = sys:suspend(Profile),
  try
    Caller = spawn(fun() -> Poll() end),
    true = await_queued(Profile, 100),
    {monitors, [{process, Helper}]} = process_info(Caller, monitors),
    Monitor = monitor(process, Helper),
    exit(Caller, kill),
    receive {'DOWN', Monitor, process, Helper, _} -> true
    after 500 ->
      demonitor(Monitor, [flush]),
      exit(Helper, kill),
      false
    end
  after
    sys:resume(Profile)
  end.

kill_and_collect(Old, Poller, PollerMonitor) ->
  Monitor = monitor(process, Old),
  Killed = erlang:monotonic_time(millisecond),
  exit(Old, kill),
  receive {'DOWN', Monitor, process, Old, killed} -> ok after 2000 -> error(no_crash) end,
  Result = receive
    {polled, Poller, Outcome} -> {Outcome, erlang:monotonic_time(millisecond) - Killed};
    {'DOWN', PollerMonitor, process, Poller, Reason} -> error({poller_crashed, Reason})
  after 5000 -> error(no_poll_result)
  end,
  true = await_restart(Old, 100),
  Result.

await_restart(_Old, 0) -> error(no_restart);
await_restart(Old, Attempts) ->
  case whereis(?PROFILE) of
    New when is_pid(New), New =/= Old -> true;
    _ -> timer:sleep(20), await_restart(Old, Attempts - 1)
  end.

await_queued(_Pid, 0) -> error(not_queued);
await_queued(Pid, Attempts) ->
  case process_info(Pid, message_queue_len) of
    {message_queue_len, N} when N > 0 -> true;
    _ -> timer:sleep(10), await_queued(Pid, Attempts - 1)
  end.

%% Runs Fun with the profile's name unregistered, as it is between a crash
%% and the supervisor's restart, and registers the same profile again after.
without_profile(Fun) ->
  Pid = whereis(?PROFILE),
  true = is_pid(Pid),
  true = unregister(?PROFILE),
  try Fun() after register(?PROFILE, Pid) end.

%% Runs Fun while the profile is suspended, so no request is admitted, and
%% resumes it after.
with_profile_suspended(Fun) ->
  Pid = whereis(?PROFILE),
  ok = sys:suspend(Pid),
  try Fun() after sys:resume(Pid) end.

%% Runs Fun with no OS CA bundle to load, as in an image without the
%% ca-certificates package: public_key's cache is cleared and its path points
%% at a file that does not exist. The cache and the path are VM-global, so
%% both are restored after, and the next caller loads the real bundle.
without_ca_bundle(Fun) ->
  _ = application:load(public_key),
  Previous = application:get_env(public_key, cacerts_path),
  ok = application:set_env(public_key, cacerts_path, "/nonexistent/knarr-ca.pem"),
  public_key:cacerts_clear(),
  try Fun()
  after
    case Previous of
      {ok, Value} -> application:set_env(public_key, cacerts_path, Value);
      undefined -> application:unset_env(public_key, cacerts_path)
    end,
    public_key:cacerts_clear()
  end.

%% How many messages wait in the calling process's mailbox.
mailbox_size() ->
  {message_queue_len, N} = process_info(self(), message_queue_len),
  N.

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
