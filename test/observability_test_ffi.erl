-module(observability_test_ffi).
-export([line_of_string/1, line_of_integer_msg/0, line_of_long_report/0]).

%% A logger event as the default handler hands observability_ffi:format/2,
%% rendered to one binary. The msg forms are the ones OTP produces:
%% {string, Chardata}, {report, Map} and {Format, Args}.
line_of_string(Text) ->
  line({string, Text}).

%% A msg that is not chardata at all.
line_of_integer_msg() ->
  line({string, 123}).

%% A labelled report whose picture runs past 400 characters of two-byte
%% characters, so a cut by byte would land inside one.
line_of_long_report() ->
  Acute = unicode:characters_to_binary([233]),
  line({report, #{label => {knarr_test, long}, text => binary:copy(Acute, 500)}}).

line(Msg) ->
  Event = #{level => error, msg => Msg, meta => #{time => 1760000000123456}},
  unicode:characters_to_binary(observability_ffi:format(Event, #{})).
