-module(application_ffi).
-behaviour(application).
-export([start/2, stop/1, await_shutdown/0, values/0]).

%% The install-wide values and their defaults (config Installed): each is
%% OTP application configuration, `-knarr <key> <value>` in ERL_FLAGS, read
%% once here and checked by config.installed. A value outside its range or
%% not of its type fails the start, which exits the VM unsuccessfully naming
%% the key (knarr Readiness).
start(_Type, _Args) ->
  case 'knarr@config':installed(values()) of
    {error, {installed_error, Key, Reason}} ->
      {error, {invalid_config, Key, Reason}};
    {ok, Installed} ->
      observability_ffi:install(level(Installed)),
      metrics_ffi:startup(),
      observability_ffi:log(info, <<"started">>,
        [{field, <<"version">>, iolist_to_binary(json:encode(metrics_ffi:version()))}]),
      Port = application:get_env(knarr, port, 8080),
      Bind = unicode:characters_to_binary(application:get_env(knarr, bind, "0.0.0.0")),
      case 'knarr@runtime':start(Port, Bind, true, discovery(Installed)) of
        {ok, {started, Pid, _Runtime}} -> {ok, Pid};
        {error, Reason} -> {error, Reason}
      end
  end.

values() ->
  [
    {<<"status_port">>, application:get_env(knarr, status_port, 8080)},
    {<<"status_path">>, text(application:get_env(knarr, status_path, "/knarr/v1/status"))},
    {<<"max_body_bytes">>, application:get_env(knarr, max_body_bytes, 4096)},
    {<<"thresholds">>, application:get_env(knarr, thresholds, [300, 900, 1800, 3600])},
    {<<"threshold_margin">>, application:get_env(knarr, threshold_margin, 60)},
    {<<"unknown_polls">>, application:get_env(knarr, unknown_polls, 3)},
    {<<"absent_after">>, application:get_env(knarr, absent_after, 300)},
    {<<"poll_interval">>, application:get_env(knarr, poll_interval, 30)},
    {<<"poll_timeout">>, application:get_env(knarr, poll_timeout, 5)},
    {<<"patch_interval">>, application:get_env(knarr, patch_interval, 60)},
    {<<"list_interval">>, application:get_env(knarr, list_interval, 60)},
    {<<"poll_concurrency">>, application:get_env(knarr, poll_concurrency, 64)},
    {<<"poll_jitter_percent">>, application:get_env(knarr, poll_jitter_percent, 10)},
    {<<"patch_rate_per_second">>, application:get_env(knarr, patch_rate_per_second, 5)},
    {<<"patch_burst">>, application:get_env(knarr, patch_burst, 10)},
    {<<"backoff_initial">>, application:get_env(knarr, backoff_initial, 1)},
    {<<"backoff_cap">>, application:get_env(knarr, backoff_cap, 60)},
    {<<"log_level">>, text(application:get_env(knarr, log_level, info))}
  ].

%% A string value arrives as a charlist from ERL_FLAGS (`'"/x"'`) or as an
%% atom (`-knarr log_level warning`); either reads as text. Anything else is
%% left as it is, for config.installed to refuse by type.
text(Value) when is_atom(Value) -> atom_to_binary(Value, utf8);
text(Value) when is_list(Value) ->
  case unicode:characters_to_binary(Value) of
    Binary when is_binary(Binary) -> Binary;
    _ -> Value
  end;
text(Value) -> Value.

%% The log level is the last field of the Installed record, an atom the Gleam
%% Level enum shares with logger.
level(
  {installed, _Defaults, _MaxBody, _Unknown, _Absent, _List, _Concurrency,
    _Jitter, _Rate, _Burst, _BackoffInitial, _BackoffCap, Level}
) -> Level.

%% Discovery is off unless `-knarr discovery true` (knarr NoPodEffects). On,
%% it reads the in-cluster environment the pod carries; a missing variable
%% fails the start, and so the VM, visibly.
discovery(Installed) ->
  case application:get_env(knarr, discovery, false) of
    true ->
      Mount = "/var/run/secrets/kubernetes.io/serviceaccount/",
      {some, 'knarr@reconciler':config(
        required("KUBERNETES_SERVICE_HOST"),
        binary_to_integer(required("KUBERNETES_SERVICE_PORT")),
        optional("KNARR_NAMESPACE_FILE", Mount ++ "namespace"),
        optional("KNARR_TOKEN_FILE", Mount ++ "token"),
        optional("KNARR_CA_FILE", Mount ++ "ca.crt"),
        Installed)};
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
