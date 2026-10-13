-module(poller_http_ffi).
-export([request/5, start_profile/0, version/0]).

-define(PROFILE, knarr_poller_httpc).

%% One asynchronous httpc call through the poller's profile. httpc's own
%% timeouts cover connect and the response; the receive bounds the whole
%% call strictly, and on expiry cancels the request and drops an answer that
%% raced the cancel. The error terms are shaped as k8s_http_ffi documents: a
%% refused connection is {failed_connect, [{to_address, _}, {inet, _,
%% econnrefused}]}, and a connect that times out, as a NetworkPolicy drop
%% does, carries timeout in the same place.
request(Method, Url, Headers, Ipv6, Timeout) ->
  Profile = profile(),
  HttpOptions = [{autoredirect, false}, {timeout, Timeout}, {connect_timeout, Timeout}],
  Options = [{sync, false}, {body_format, binary},
    {socket_opts, [{ipfamily, family(Ipv6)}]}],
  Request = {unicode:characters_to_list(Url),
    [{unicode:characters_to_list(K), unicode:characters_to_list(V)} || {K, V} <- Headers]},
  case httpc:request(method(Method), Request, HttpOptions, Options, Profile) of
    {ok, Id} ->
      receive
        {http, {Id, {error, Reason}}} -> {error, transport(Reason)};
        {http, {Id, {{_, Status, _}, ResponseHeaders, Body}}} ->
          {ok, {Status,
                [{unicode:characters_to_binary(K), unicode:characters_to_binary(V)} || {K, V} <- ResponseHeaders],
                iolist_to_binary(Body)}}
      after Timeout ->
        ok = httpc:cancel_request(Id, Profile),
        receive {http, {Id, _}} -> ok after 0 -> ok end,
        {error, timed_out}
      end;
    {error, Reason} -> {error, transport(Reason)}
  end.

%% The registered profile. Without it a poll is a programming error.
profile() ->
  case whereis(?PROFILE) of
    Pid when is_pid(Pid) -> Pid;
    undefined -> erlang:error({no_profile, ?PROFILE})
  end.

method(<<"GET">>) -> get.

%% The family is set per request, so httpc connects over exactly it: the
%% profile default is inet alone, a bare inet6 in socket_opts loses to it,
%% and inet6fb4 would try an IPv4 literal over inet6 first, a resolver
%% lookup of the address. A request with socket_opts also gets a connection of its own
%% that httpc closes after the response (httpc_manager:handle_request/2), so
%% no poll reuses a connection an earlier one left open.
family(true) -> inet6;
family(false) -> inet.

transport({failed_connect, Reasons}) -> failed_connect(Reasons);
transport(timeout) -> timed_out;
transport(_) -> unreachable.

%% The family tag is inet or inet6; the shape is the same.
failed_connect([{_Family, _, econnrefused} | _]) -> refused;
failed_connect([{_Family, _, timeout} | _]) -> timed_out;
failed_connect([{_Family, _, _} | _]) -> unreachable;
failed_connect([_ | Rest]) -> failed_connect(Rest);
failed_connect([]) -> unreachable.

%% A stand-alone httpc manager, linked to the calling supervisor and so
%% apart from the inets-managed default profile k8s_http uses. A stand-alone
%% profile is addressed by pid only, hence the registered name.
start_profile() ->
  case inets:start(httpc, [{profile, knarr_poller}], stand_alone) of
    {ok, Pid} ->
      try register(?PROFILE, Pid) of
        true -> {ok, {started, Pid, nil}}
      catch
        error:badarg ->
          unlink(Pid),
          exit(Pid, kill),
          {error, {init_failed, <<"knarr_poller_httpc is already registered">>}}
      end;
    {error, Reason} ->
      {error, {init_failed, unicode:characters_to_binary(io_lib:format("~0p", [Reason]))}}
  end.

version() ->
  case application:load(knarr) of
    ok -> ok;
    {error, {already_loaded, knarr}} -> ok
  end,
  {ok, Vsn} = application:get_key(knarr, vsn),
  unicode:characters_to_binary(Vsn).
