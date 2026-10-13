-module(poller_http_ffi).
-export([request/5, start_profile/0, version/0]).

-define(PROFILE, knarr_poller_httpc).

%% One synchronous httpc call through the poller's profile. httpc's
%% timeouts cover connect and the response; on expiry httpc cancels the
%% request, and since a synchronous call answers to an alias it releases
%% afterwards, a late answer is dropped rather than left in the caller's
%% mailbox. autoretry 0 returns a 503 with Retry-After as it is, where httpc
%% would otherwise retry it through a registered manager name a stand-alone
%% profile does not have, and the poll would time out. The Host header of an
%% IPv6 poll keeps its brackets. The error terms are shaped as k8s_http_ffi
%% documents: a refused connection is {failed_connect, [{to_address, _},
%% {inet, _, econnrefused}]}, and a connect that times out, as a
%% NetworkPolicy drop does, carries timeout in the same place.
request(Method, Url, Headers, Ipv6, Timeout) ->
  HttpOptions = [{autoredirect, false}, {autoretry, 0}, {timeout, Timeout},
    {connect_timeout, Timeout}],
  Options = [{body_format, binary}, {ipv6_host_with_brackets, Ipv6},
    {socket_opts, [{ipfamily, family(Ipv6)}]}],
  Request = {unicode:characters_to_list(Url),
    [{unicode:characters_to_list(K), unicode:characters_to_list(V)} || {K, V} <- Headers]},
  case httpc:request(method(Method), Request, HttpOptions, Options, profile()) of
    {ok, {{_, Status, _}, ResponseHeaders, Body}} ->
      {ok, {Status,
            [{unicode:characters_to_binary(K), unicode:characters_to_binary(V)} || {K, V} <- ResponseHeaders],
            iolist_to_binary(Body)}};
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
    {error, {already_loaded, knarr}} -> ok;
    {error, Reason} -> erlang:error({knarr_app_not_loadable, Reason})
  end,
  {ok, Vsn} = application:get_key(knarr, vsn),
  unicode:characters_to_binary(Vsn).
