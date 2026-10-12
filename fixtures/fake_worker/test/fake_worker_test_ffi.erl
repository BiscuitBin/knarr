-module(fake_worker_test_ffi).
-export([get/2, put/3, delete/2, start_on_free_port/1, stop_tree/1, now_ms/0,
  kill_registered/1, crash_once/1]).

%% Plain HTTP over loopback with httpc, and connection: close, so no pooled
%% connection outlives a listener the test closes. A refused connection and a
%% timeout come back as the transport outcomes worker_contract.allium names.
get(Url, Timeout) ->
  request(get, {binary_to_list(Url), [{"connection", "close"}]}, Timeout).

put(Url, Body, Timeout) ->
  request(put, {binary_to_list(Url), [{"connection", "close"}], "application/json", Body}, Timeout).

delete(Url, Timeout) ->
  request(delete, {binary_to_list(Url), [{"connection", "close"}]}, Timeout).

request(Method, Request, Timeout) ->
  {ok, _} = application:ensure_all_started(inets),
  Options = [{timeout, Timeout}, {connect_timeout, Timeout}],
  case httpc:request(Method, Request, Options, [{body_format, binary}]) of
    {ok, {{_, Status, _}, _Headers, Body}} -> {ok, {Status, Body}};
    {error, timeout} -> {error, timed_out};
    {error, {failed_connect, Details}} ->
      case lists:keyfind(inet, 1, Details) of
        {inet, _, econnrefused} -> {error, refused};
        _ -> {error, {other, format(Details)}}
      end;
    {error, Reason} -> {error, {other, format(Reason)}}
  end.

format(Term) -> unicode:characters_to_binary(io_lib:format("~p", [Term])).

%% Another process can take a released port before Start binds it, so retry,
%% as test/runtime_test_ffi.erl does for knarr's listener.
start_on_free_port(Start) ->
  Previous = process_flag(trap_exit, true),
  try start_on_free_port(Start, 5, undefined)
  after process_flag(trap_exit, Previous)
  end.

start_on_free_port(_Start, 0, Last) -> error({start_failed, Last});
start_on_free_port(Start, Attempts, _Last) ->
  Port = free_port(),
  case Start(Port) of
    {ok, Running} -> {Port, Running};
    {error, Reason} ->
      receive {'EXIT', _, _} -> ok after 100 -> ok end,
      start_on_free_port(Start, Attempts - 1, Reason)
  end.

free_port() ->
  {ok, Socket} = gen_tcp:listen(0, [{ip, {127,0,0,1}}]),
  {ok, {_, Port}} = inet:sockname(Socket),
  gen_tcp:close(Socket),
  Port.

%% A tree started by a test is linked to it; stop it without taking the test
%% process down too.
stop_tree(Root) ->
  unlink(Root),
  gen_server:stop(Root, shutdown, 5000),
  nil.

now_ms() -> erlang:monotonic_time(millisecond).

%% Kill the process registered under a name with this prefix, as a crash would,
%% and wait until it is gone.
kill_registered(Prefix) ->
  [Pid] = [whereis(Name) || Name <- registered(),
    lists:prefix(binary_to_list(Prefix), atom_to_list(Name))],
  Monitor = monitor(process, Pid),
  exit(Pid, kill),
  receive {'DOWN', Monitor, process, Pid, _} -> nil after 2000 -> error(not_killed) end.

%% Exit the calling process the first time a key is seen, as a crash would, and
%% return nil every time after: the key outlives the crashed process.
crash_once(Key) ->
  case persistent_term:get({?MODULE, Key}, false) of
    false ->
      persistent_term:put({?MODULE, Key}, true),
      exit(simulated_crash);
    true -> nil
  end.
