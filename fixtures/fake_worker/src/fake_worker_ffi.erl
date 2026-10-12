%% The fake worker's Erlang calls: the environment, the clock, the bound
%% ports, stopping and restarting the status listener, delivering a kill
%% record over httpc, stopping the VM, and the SIGTERM handler.
%%
%% The SIGTERM handler replaces OTP's default one on erl_signal_server, which
%% would call init:stop() at once. This module is that gen_event handler: on
%% sigterm it calls the Gleam function main passed in, which tells the state
%% actor to drain. If that call fails (the actor is restarting), it falls back
%% to init:stop(), so SIGTERM never goes unanswered. Every other signal is
%% handled as OTP's erl_signal_handler handles it.
-module(fake_worker_ffi).
-behaviour(gen_event).

-export([
  getenv/1, hostname/0, now_ms/0, new_ports/0, set_port/3, get_port/2,
  set_child_running/3, deliver/3, stop_vm/0, halt/1, install_sigterm/1,
  await_shutdown/1, format/1
]).
-export([
  init/1, handle_event/2, handle_call/2, handle_info/2, terminate/2,
  code_change/3
]).

getenv(Name) ->
  case os:getenv(unicode:characters_to_list(Name)) of
    false -> {error, nil};
    Value -> {ok, unicode:characters_to_binary(Value)}
  end.

hostname() ->
  {ok, Name} = inet:gethostname(),
  unicode:characters_to_binary(Name).

now_ms() -> erlang:monotonic_time(millisecond).

%% Slot 1 holds the status listener's bound port, slot 2 the control's.
new_ports() -> atomics:new(2, []).

set_port(Ports, Slot, Port) ->
  atomics:put(Ports, Slot, Port),
  nil.

get_port(Ports, Slot) -> atomics:get(Ports, Slot).

%% terminate_child closes the listener's socket before it returns, and
%% restart_child binds it again; glisten sets SO_REUSEADDR, so the same port
%% comes back.
set_child_running(Supervisor, Id, Running) ->
  try
    case Running of
      true -> supervisor:restart_child(Supervisor, Id);
      false -> supervisor:terminate_child(Supervisor, Id)
    end
  of
    Result -> child_result(Result)
  catch
    exit:Reason -> {error, {listener_error, format(Reason)}}
  end.

child_result(ok) -> {ok, nil};
child_result({ok, _}) -> {ok, nil};
child_result({ok, _, _}) -> {ok, nil};
child_result({error, running}) -> {ok, nil};
child_result(Other) -> {error, {listener_error, format(Other)}}.

%% The sink URL is plain http://. Without an ssl option, OTP 29's httpc builds
%% its default TLS options for every request, loading the OS CA store, and the
%% runtime image has none: the request crashes with no_cacerts_found. An empty
%% ssl option skips that. Any other exception is a failed attempt too, so the
%% sink retries instead of crashing.
deliver(Url, Body, Timeout) ->
  Request = {unicode:characters_to_list(Url), [], "application/json", Body},
  Options = [{timeout, Timeout}, {connect_timeout, Timeout}, {ssl, []}],
  try httpc:request(put, Request, Options, [{body_format, binary}]) of
    {ok, {{_, Status, _}, _, _}} when Status >= 200, Status < 300 -> {ok, nil};
    {ok, {{_, Status, _}, _, _}} ->
      {error, {delivery_error, <<"status ", (integer_to_binary(Status))/binary>>}};
    {error, Reason} -> {error, {delivery_error, format(Reason)}}
  catch
    Class:Reason -> {error, {delivery_error, format({Class, Reason})}}
  end.

stop_vm() ->
  init:stop(),
  nil.

halt(Code) -> erlang:halt(Code).

install_sigterm(Notify) ->
  case gen_event:swap_handler(erl_signal_server, {erl_signal_handler, []}, {?MODULE, Notify}) of
    ok -> {ok, nil};
    {error, Reason} -> {error, {signal_error, format(Reason)}}
  end.

%% Like knarr's application_ffi:await_shutdown/0: a tree that stops while the
%% VM is not stopping is a failure, so the VM exits unsuccessfully.
await_shutdown(Root) ->
  unlink(Root),
  Monitor = monitor(process, Root),
  receive
    {'DOWN', Monitor, process, Root, Reason} ->
      case init:get_status() of
        {stopping, _} -> receive after infinity -> nil end;
        _ ->
          io:format(standard_error, "fake_worker: the supervision tree stopped: ~p~n", [Reason]),
          erlang:halt(1)
      end
  end.

format(Term) -> unicode:characters_to_binary(io_lib:format("~p", [Term])).

%% gen_event callbacks. swap_handler passes {Arguments, OldHandlerResult}.
init({Notify, _}) -> {ok, Notify}.

handle_event(sigterm, Notify) ->
  try Notify() catch _:_ -> init:stop() end,
  {ok, Notify};
handle_event(Signal, Notify) ->
  _ = erl_signal_handler:handle_event(Signal, undefined),
  {ok, Notify}.

handle_call(_Request, Notify) -> {ok, ok, Notify}.

handle_info(_Info, Notify) -> {ok, Notify}.

terminate(_Arguments, _Notify) -> ok.

code_change(_OldVersion, Notify, _Extra) -> {ok, Notify}.
