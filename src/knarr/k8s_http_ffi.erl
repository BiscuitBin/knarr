-module(k8s_http_ffi).
-export([request/6]).

%% One httpc call with explicit ssl options. The error terms are shaped from
%% what httpc returns (evidence/14/tls.txt): a handshake failure arrives as
%% {failed_connect, [{to_address, _}, {inet, _, {tls_alert, {Alert, _}}}]}
%% and a refused connection as {inet, _, econnrefused}. Nothing returned here
%% carries the request or its headers.
%%
%% httpc's default profile connects over inet only, so an IPv6 literal host
%% (the bracketed form ServiceAddress gives) goes through a profile of its
%% own whose ipfamily is inet6. That profile is started under inets' own
%% supervisor on first use; an IPv4 host never touches it. Request options
%% cannot carry the family: {socket_opts, [inet6]} still resolves with inet.
%%
%% autoretry is 0. httpc's default, infinity, sends any request again once
%% after a 503 whose Retry-After it can read, after that delay: a create
%% would be two attempts (ConflictEvent), and the caller would see the
%% retry's answer, or a timeout past ten seconds, instead of the 503 and its
%% Retry-After (Failures).
request(Method, Url, Headers, ContentType, Body, CaFile) ->
  Ssl = [{verify, verify_peer},
    {cacertfile, unicode:characters_to_list(CaFile)},
    {customize_hostname_check, [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}],
  Options = [{ssl, Ssl}, {timeout, 10000}, {connect_timeout, 5000}, {autoretry, 0}],
  UrlList = unicode:characters_to_list(Url),
  HeaderList = [{unicode:characters_to_list(K), unicode:characters_to_list(V)} || {K, V} <- Headers],
  Request = case {ContentType, Body} of
    {<<>>, <<>>} -> {UrlList, HeaderList};
    {<<>>, _} -> {error, {other, <<"body without content-type">>}};
    _ -> {UrlList, HeaderList, unicode:characters_to_list(ContentType), Body}
  end,
  case request(method(Method), Request, Options, profile(UrlList)) of
    {ok, {{_, Status, _}, ResponseHeaders, ResponseBody}} ->
      {ok, {Status,
            [{unicode:characters_to_binary(K), unicode:characters_to_binary(V)} || {K, V} <- ResponseHeaders],
            ResponseBody}};
    {error, {failed_connect, Reasons}} -> {error, failed_connect(Reasons)};
    {error, timeout} -> {error, timeout};
    {error, {other, _} = Known} -> {error, Known};
    {error, Reason} -> {error, {other, describe(Reason)}}
  end.

request({error, Reason}, _Request, _Options, _Profile) -> {error, Reason};
request(_Method, {error, Reason}, _Options, _Profile) -> {error, Reason};
request(_Method, _Request, _Options, {error, Reason}) -> {error, Reason};
request(Method, Request, Options, Profile) ->
  httpc:request(Method, Request, Options, [{body_format, binary}], Profile).

%% The default profile, or the inet6 one when the URL's host is an IPv6
%% literal. uri_string strips the brackets from the host it returns.
profile(Url) ->
  Host = case uri_string:parse(Url) of
    #{host := H} -> H;
    _ -> ""
  end,
  case inet:parse_ipv6strict_address(Host) of
    {ok, _} -> inet6_profile();
    {error, _} -> default
  end.

inet6_profile() ->
  case inets:start(httpc, [{profile, knarr_inet6}]) of
    {ok, _} -> set_inet6();
    {error, {already_started, _}} -> set_inet6();
    {error, Reason} -> {error, {other, describe(Reason)}}
  end.

%% Set on every use, so a request racing the one that started the profile
%% still gets inet6; a failure is a value, like every other here.
set_inet6() ->
  case httpc:set_options([{ipfamily, inet6}], knarr_inet6) of
    ok -> knarr_inet6;
    {error, Reason} -> {error, {other, describe(Reason)}}
  end.

method(<<"GET">>) -> get;
method(<<"PATCH">>) -> patch;
method(<<"POST">>) -> post;
method(<<"PUT">>) -> put;
method(<<"DELETE">>) -> delete;
method(<<"HEAD">>) -> head;
method(<<"OPTIONS">>) -> options;
method(Other) -> {error, {unsupported_method, Other}}.

%% The family tag is inet or inet6; the shape is the same.
failed_connect([{_Family, _, {tls_alert, {Alert, _}}} | _]) ->
  {tls_alert, atom_to_binary(Alert)};
failed_connect([{_Family, _, timeout} | _]) -> timeout;
failed_connect([{_Family, _, Reason} | _]) when is_atom(Reason) ->
  {connect_failed, atom_to_binary(Reason)};
failed_connect([{_Family, [_ | _], Reason} | _]) ->
  {connect_failed, describe(Reason)};
failed_connect([_ | Rest]) -> failed_connect(Rest);
failed_connect([]) -> {connect_failed, <<"unknown">>}.

%% A bounded rendering of a term that is not one of the shapes above.
describe(Term) ->
  Text = unicode:characters_to_binary(io_lib:format("~0p", [Term])),
  case byte_size(Text) > 200 of
    true -> <<(binary:part(Text, 0, 200))/binary, "...">>;
    false -> Text
  end.
