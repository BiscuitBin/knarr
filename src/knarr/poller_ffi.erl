-module(poller_ffi).
-export([parse_json/1]).

%% Parses a status body as JSON, pure. Every number with a fraction or an
%% exponent is kept as its source text rather than made a float, so a member
%% decode ignores cannot fail the parse with a value no float holds (1e400),
%% and a cost so written is a binary, which the int decoder rejects. Anything
%% but whitespace after the value is an error.
parse_json(Body) ->
  try json:decode(Body, ok, #{float => fun(Text) -> Text end}) of
    {Term, ok, <<>>} -> {ok, Term};
    {_, ok, _} -> {error, nil}
  catch
    error:_ -> {error, nil}
  end.
