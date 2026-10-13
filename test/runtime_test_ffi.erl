-module(runtime_test_ffi).
-export([recover/2, application_runs_the_poller_profile/0, occupied_port/1, start_on_free_port/1]).

recover({runtime, Root, State}, SamePort) ->
  unlink(Root),
  try
    {ok, _} = application:ensure_all_started(inets),
    Port = atomics:get(State, 2),
    serves(Port),
    Child = listener(Root),
    Monitor = monitor(process, Child),
    exit(Child, kill),
    receive {'DOWN', Monitor, process, Child, killed} -> ok after 2000 -> error(no_crash) end,
    await(fun() ->
      NewChild = listener(Root),
      true = is_pid(NewChild) andalso NewChild =/= Child,
      NewPort = atomics:get(State, 2),
      true = (not SamePort) orelse NewPort =:= Port,
      serves(NewPort),
      true
    end, 100)
  after
    gen_server:stop(Root, shutdown, 5000)
  end.

%% The listener is the root's first child, id 0.
listener(Root) ->
  {0, Child, supervisor, _} = lists:keyfind(0, 1, supervisor:which_children(Root)),
  Child.

%% The application's root runs the poller's httpc profile as child id 1,
%% under the name poller_http_ffi sends through.
application_runs_the_poller_profile() ->
  {ok, Root} = application:get_supervisor(knarr),
  {1, Profile, worker, _} = lists:keyfind(1, 1, supervisor:which_children(Root)),
  is_pid(Profile) andalso Profile =:= whereis(knarr_poller_httpc).

serves(Port) ->
  loopback_listener(Port),
  {200, <<"ok\n">>} = get(Port, "/healthz"),
  {200, <<"ok\n">>} = get(Port, "/readyz"),
  {200, Metrics} = get(Port, "/metrics"),
  true = binary:match(Metrics, <<"knarr_startups_total 1\n">>) =/= nomatch,
  true = binary:match(Metrics, <<"erlang_vm_">>) =/= nomatch,
  ok.

loopback_listener(Port) ->
  true = Port > 0,
  %% Accepted keep-alive sockets share the port but have a peer; the listener has none.
  [{127,0,0,1}] = [Address || Socket <- erlang:ports(),
    {ok, {Address, SocketPort}} <- [try inet:sockname(Socket) catch _:_ -> error end], SocketPort =:= Port,
    {error, _} <- [try inet:peername(Socket) catch _:_ -> closed end]].

get(Port, Path) ->
  Url = "http://127.0.0.1:" ++ integer_to_list(Port) ++ Path,
  {ok, {{_, Code, _}, _, Body}} = httpc:request(get, {Url, []}, [{timeout, 1000}], [{body_format, binary}]),
  {Code, Body}.

await(_Check, 0) -> error(recovery_timeout);
await(Check, Attempts) ->
  try Check() catch _:_ -> timer:sleep(20), await(Check, Attempts - 1) end.

occupied_port(Start) ->
  Previous = process_flag(trap_exit, true),
  {ok, Socket} = gen_tcp:listen(0, [{ip, {127,0,0,1}}]),
  {ok, {_, Port}} = inet:sockname(Socket),
  try
    case Start(Port) of
      {error, _} -> true;
      {ok, {started, Pid, _}} -> unlink(Pid), gen_server:stop(Pid), false
    end
  after
    gen_tcp:close(Socket),
    receive {'EXIT', _, _} -> ok after 100 -> ok end,
    process_flag(trap_exit, Previous)
  end.

%% Another process can take a released port before Start binds it, so retry.
start_on_free_port(Start) ->
  Previous = process_flag(trap_exit, true),
  try start_on_free_port(Start, 5, undefined)
  after process_flag(trap_exit, Previous)
  end.

start_on_free_port(_Start, 0, Last) -> error({start_failed, Last});
start_on_free_port(Start, Attempts, _Last) ->
  case Start(free_port()) of
    {ok, {started, _, Runtime}} -> Runtime;
    {error, Reason} ->
      receive {'EXIT', _, _} -> ok after 100 -> ok end,
      start_on_free_port(Start, Attempts - 1, Reason)
  end.

free_port() ->
  {ok, Socket} = gen_tcp:listen(0, [{ip, {127,0,0,1}}]),
  {ok, {_, Port}} = inet:sockname(Socket),
  gen_tcp:close(Socket),
  Port.
