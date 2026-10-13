-module(poller_http_ffi).
-export([request/5, start_profile/0, version/0]).

-define(PROFILE, knarr_poller_httpc).
%% How much later than the caller's deadline httpc's own timers fire.
-define(BACKSTOP_MS, 1000).

%% One poll, held to one deadline. httpc's own timeout starts only once the
%% profile's manager has admitted the request, and that admission is a
%% gen_server call with no bound, so the call runs in a helper process and
%% the caller waits Timeout for it from the start. This is the only
%% deadline: on expiry the helper is killed, which also releases the alias
%% httpc answers to, so a late answer reaches no one. The helper is linked
%% to the caller, so a caller killed mid-poll takes it along rather than
%% leaving it waiting for admission; the caller unlinks before it kills the
%% helper, and flushes the link's exit in case it traps exits. A crash in
%% the helper (an error; httpc's exits are caught) crashes the caller too,
%% as a method other than GET does before any helper starts. A request
%% still waiting for admission when its helper dies stays in the manager's
%% queue: httpc has no request id to cancel before admission, so the
%% manager admits and sends it once it resumes, and the answer goes to the
%% dead alias. The handler ends at its backstop timer.
request(Method, Url, Headers, Ipv6, Timeout) ->
  Get = method(Method),
  Caller = self(),
  {Helper, Ref} = spawn_opt(fun() ->
    Caller ! {self(), call(Get, Url, Headers, Ipv6, Timeout)}
  end, [link, monitor]),
  receive
    {Helper, Result} ->
      release(Helper, Ref),
      Result;
    {'DOWN', Ref, process, Helper, _} ->
      release(Helper, Ref),
      {error, unreachable}
  after Timeout ->
    unlink(Helper),
    exit(Helper, kill),
    release(Helper, Ref),
    receive {Helper, _} -> ok after 0 -> ok end,
    {error, timed_out}
  end.

%% Once unlink/1 returns no exit from the link arrives, but one may already
%% be queued for a caller that traps exits.
release(Helper, Ref) ->
  unlink(Helper),
  demonitor(Ref, [flush]),
  receive {'EXIT', Helper, _} -> ok after 0 -> ok end.

%% The profile is not registered between a crash and its restart, and a
%% manager that exits while admitting the request exits the call; both are
%% unreachable.
call(Method, Url, Headers, Ipv6, Timeout) ->
  case whereis(?PROFILE) of
    undefined -> {error, unreachable};
    Profile -> call(Profile, Method, Url, Headers, Ipv6, Timeout)
  end.

%% One synchronous httpc call through the poller's profile. httpc's
%% timeouts are a backstop, BACKSTOP_MS past the caller's deadline, so the
%% caller has answered and killed this helper before either fires. Set to
%% the deadline itself, httpc's wait in httpc:handle_answer/5, which starts
%% only on admission, raced the caller's by a fraction of a millisecond,
%% and a starved scheduler let it win. The backstop then only stops the
%% handler: httpc sends its cancel to the default profile, not this one
%% (handle_answer/5 calls cancel_request/1), so the handler runs until its
%% own request timer fires and closes the connection.
%% {ssl, []} stands in for httpc's default ssl options, which load the OS CA
%% bundle on every request, http included, and crash where there is none.
%% autoretry 0 returns a 503 with Retry-After as it is, where httpc
%% would otherwise retry it through a registered manager name a stand-alone
%% profile does not have, and the poll would time out. The Host header of an
%% IPv6 poll keeps its brackets. The error terms are shaped as k8s_http_ffi
%% documents: a refused connection is {failed_connect, [{to_address, _},
%% {inet, _, econnrefused}]}, and a connect that times out, as a
%% NetworkPolicy drop does, carries timeout in the same place.
call(Profile, Method, Url, Headers, Ipv6, Timeout) ->
  HttpOptions = [{autoredirect, false}, {autoretry, 0}, {ssl, []},
    {timeout, Timeout + ?BACKSTOP_MS}, {connect_timeout, Timeout + ?BACKSTOP_MS}],
  Options = [{body_format, binary}, {ipv6_host_with_brackets, Ipv6},
    {socket_opts, [{ipfamily, family(Ipv6)}]}],
  Request = {unicode:characters_to_list(Url),
    [{unicode:characters_to_list(K), unicode:characters_to_list(V)} || {K, V} <- Headers]},
  try httpc:request(Method, Request, HttpOptions, Options, Profile) of
    {ok, {{_, Status, _}, ResponseHeaders, Body}} ->
      {ok, {Status,
            [{unicode:characters_to_binary(K), unicode:characters_to_binary(V)} || {K, V} <- ResponseHeaders],
            iolist_to_binary(Body)}};
    {error, Reason} -> {error, transport(Reason)}
  catch
    exit:_ -> {error, unreachable}
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
