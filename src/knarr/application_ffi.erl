-module(application_ffi).
-behaviour(application).
-export([start/2, stop/1, await_shutdown/0]).

start(_Type, _Args) ->
  metrics_ffi:startup(),
  Port = application:get_env(knarr, port, 8080),
  Bind = unicode:characters_to_binary(application:get_env(knarr, bind, "0.0.0.0")),
  case 'knarr@runtime':start(Port, Bind, true, probe()) of
    {ok, {started, Pid, _Runtime}} -> {ok, Pid};
    {error, Reason} -> {error, Reason}
  end.

%% The S1 probe (ticket 14) is off unless `-knarr s1_probe true`. On, it
%% reads the in-cluster environment the pod carries; a missing variable
%% fails the start, and so the VM, visibly.
probe() ->
  case application:get_env(knarr, s1_probe, false) of
    true ->
      Mount = "/var/run/secrets/kubernetes.io/serviceaccount/",
      {some, 'knarr@s1_probe':config(
        required("KUBERNETES_SERVICE_HOST"),
        binary_to_integer(required("KUBERNETES_SERVICE_PORT")),
        optional("KNARR_NAMESPACE_FILE", Mount ++ "namespace"),
        optional("KNARR_TOKEN_FILE", Mount ++ "token"),
        optional("KNARR_CA_FILE", Mount ++ "ca.crt"),
        required("POD_NAME"),
        30000)};
    _ -> none
  end.

required(Name) ->
  case os:getenv(Name) of
    false -> erlang:error({missing_environment_variable, Name});
    Value -> unicode:characters_to_binary(Value)
  end.

optional(Name, Default) ->
  unicode:characters_to_binary(os:getenv(Name, Default)).

stop(_State) -> ok.

await_shutdown() ->
  {ok, Root} = application:get_supervisor(knarr),
  Monitor = monitor(process, Root),
  receive
    {'DOWN', Monitor, process, Root, Reason} ->
      case init:get_status() of
        {stopping, _} -> receive after infinity -> ok end;
        _ -> exit({knarr_stopped, Reason})
      end
  end.
