-module(reconciler_test_ffi).
-export([children/1, await_new_children/2, stop_actor/1, stop_root/1, write_file/2, delete_file/1,
  table_new/0, table_put/3, table_get/2, table_append/3, table_list/2,
  capture_logs/1, release_logs/0, log/2]).

%% The pids of a supervisor's children, in child id order.
children(Supervisor) ->
  [Pid || {_, Pid, _, _} <- lists:reverse(supervisor:which_children(Supervisor)), is_pid(Pid)].

%% Waits until the supervisor's children are all new: as many as before and
%% no pid in common with Previous, which is what a one-for-all restart leaves.
await_new_children(Supervisor, Previous) -> await_new_children(Supervisor, Previous, 100).

await_new_children(_Supervisor, _Previous, 0) -> error(no_restart);
await_new_children(Supervisor, Previous, Attempts) ->
  Current = children(Supervisor),
  case length(Current) =:= length(Previous) andalso Current -- Previous =:= Current of
    true -> Current;
    false -> timer:sleep(20), await_new_children(Supervisor, Previous, Attempts - 1)
  end.

%% A bare actor is stopped with the signal its supervisor would send: an
%% exit, which it does not trap. gleam_otp 1.3.0's actor does not handle
%% the terminate system message, so gen_server:stop would block, or time out,
%% and leave it running (docs/reference/testing.md). The stop waits for the
%% actor to be down, so a test that starts another on the same files next
%% does not race it. The root is an OTP supervisor and takes gen_server:stop.
stop_actor(Pid) ->
  unlink(Pid),
  Monitor = monitor(process, Pid),
  exit(Pid, shutdown),
  receive {'DOWN', Monitor, process, Pid, _} -> ok after 5000 -> error(no_stop) end,
  nil.

stop_root(Pid) ->
  unlink(Pid),
  gen_server:stop(Pid, shutdown, 5000),
  nil.

%% Test fixtures under build/. The directory is created on the way.
write_file(Path, Content) ->
  ok = filelib:ensure_dir(Path),
  ok = file:write_file(Path, Content),
  nil.

delete_file(Path) ->
  ok = filelib:ensure_dir(Path),
  case file:delete(Path) of
    ok -> nil;
    {error, enoent} -> nil
  end.

%% A scripted cluster: a public ETS table of strings the fakes read and the
%% test writes between cycles, so a closure can change its answers.
table_new() -> ets:new(reconciler_test, [public, set]).

table_put(Table, Key, Value) ->
  true = ets:insert(Table, {Key, Value}),
  nil.

table_get(Table, Key) ->
  case ets:lookup(Table, Key) of
    [{_, Value}] -> {ok, Value};
    [] -> {error, nil}
  end.

%% Appends are made by concurrent poll workers, so each is its own row,
%% keyed by the list's key and a monotonic integer, never a read-modify-write
%% of one row that two workers could race on.
table_append(Table, Key, Value) ->
  true = ets:insert(Table, {{Key, erlang:unique_integer([monotonic])}, Value}),
  nil.

table_list(Table, Key) ->
  [Value || {_, Value} <- lists:sort(ets:match_object(Table, {{Key, '_'}, '_'}))].

%% Captures every line the formatter renders into the table under "logs",
%% through a handler of this module, so a test can count the lines a cycle
%% wrote. The handler is one per VM; release_logs removes it.
capture_logs(Table) ->
  _ = logger:remove_handler(knarr_test_capture),
  ok = logger:add_handler(knarr_test_capture, ?MODULE, #{config => Table, level => all}),
  nil.

release_logs() ->
  _ = logger:remove_handler(knarr_test_capture),
  nil.

log(Event, #{config := Table}) ->
  Line = observability_ffi:format(Event, #{}),
  table_append(Table, <<"logs">>, iolist_to_binary(Line)),
  ok.
