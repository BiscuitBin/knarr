-module(observability_ffi).
-export([install/1, log/3, format/2, drop_progress/2]).

%% knarr logs through OTP logger as one JSON object per line (observability
%% Logs Format): this module is the formatter on the default handler, and
%% every line knarr writes goes through log/3 as a report the formatter
%% renders with knarr@observability:render. The primary level is
%% config.log_level, so OTP's own reports at that level and above flow
%% through the same formatter; each is rendered with its label as the msg and
%% a depth-limited, truncated picture of the report, so no whole term, and
%% nothing a term might carry, reaches a line in full (Logs NeverLogged).
install(Level) ->
  ok = logger:set_primary_config(level, Level),
  ok = logger:update_handler_config(default, formatter, {?MODULE, #{}}),
  ok = case logger:add_handler_filter(default, knarr_progress, {fun drop_progress/2, []}) of
    ok -> ok;
    {error, {already_exist, knarr_progress}} -> ok
  end,
  nil.

%% OTP's progress reports, one per child a supervisor starts, say nothing an
%% operator acts on and would outnumber every other line at level info, so
%% the default handler drops them; crash and error reports still flow.
drop_progress(#{msg := {report, #{label := {_, progress}}}}, _) -> stop;
drop_progress(_Event, _) -> ignore.

log(Level, Msg, Fields) ->
  logger:log(Level, #{knarr_msg => Msg, knarr_fields => Fields}),
  nil.

%% A formatter that raises makes logger print the whole event as text, so
%% whatever an event holds, the line is a JSON object (Logs Format): one that
%% cannot be rendered becomes a fixed error line.
format(Event, Config) ->
  try
    render(Event, Config)
  catch
    _:_ -> unformattable(Event)
  end.

render(#{level := Level, msg := Msg, meta := Meta}, _Config) ->
  {Text, Fields} = message(Msg),
  'knarr@observability':render({log_line, time(Meta), level(Level), Text, Fields}).

unformattable(Event) ->
  try
    Meta = maps:get(meta, Event, #{}),
    'knarr@observability':render({log_line, time(Meta), error, <<"unformattable">>, []})
  catch
    _:_ -> <<"{\"level\":\"error\",\"msg\":\"unformattable\"}\n">>
  end.

time(#{time := Microseconds}) when is_integer(Microseconds) -> Microseconds div 1000;
time(_) -> erlang:system_time(millisecond).

message({report, #{knarr_msg := Msg, knarr_fields := Fields}}) ->
  {Msg, Fields};
message({report, #{label := Label} = Report}) ->
  {limited(Label), [{field, <<"report">>, json(limited(maps:without([label], Report)))}]};
message({report, Report}) ->
  {<<"report">>, [{field, <<"report">>, json(limited(Report))}]};
message({string, String}) ->
  {text(String), []};
message({Format, Args}) ->
  Text = try io_lib:format(Format, Args) catch _:_ -> "unprintable" end,
  {text(Text), []}.

%% A bounded picture of a term: depth 8, at most 400 characters.
limited(Term) ->
  text(io_lib:format("~0P", [Term, 8])).

%% Chardata as a binary of at most 400 characters, cut by character so the
%% cut never splits one; anything that is not chardata is "unprintable".
text(Chardata) ->
  try unicode:characters_to_binary(Chardata) of
    Binary when is_binary(Binary) ->
      case string:length(Binary) =< 400 of
        true -> Binary;
        false -> <<(string:slice(Binary, 0, 400))/binary, "...">>
      end;
    _ -> <<"unprintable">>
  catch
    _:_ -> <<"unprintable">>
  end.

json(Binary) -> iolist_to_binary(json:encode(Binary)).

level(debug) -> debug;
level(info) -> info;
level(notice) -> info;
level(warning) -> warning;
level(_) -> error.
