-module(reconciler_ffi).
-export([read_file/1, sha256_hex12/1, unix_seconds/0, unix_milliseconds/0, rfc3339/1]).

read_file(Path) ->
  case file:read_file(Path) of
    {ok, Content} -> {ok, Content};
    {error, Reason} -> {error, {read_failed, atom_to_binary(Reason)}}
  end.

%% The first twelve hex characters of sha256: enough to see a change in a
%% log line, never enough to reconstruct the input.
sha256_hex12(Data) ->
  binary:part(binary:encode_hex(crypto:hash(sha256, Data), lowercase), 0, 12).

unix_seconds() -> erlang:system_time(second).

unix_milliseconds() -> erlang:system_time(millisecond).

%% RFC 3339 UTC to the second, the form ownership's Recorded marker holds.
rfc3339(Seconds) ->
  unicode:characters_to_binary(calendar:system_time_to_rfc3339(Seconds, [{offset, "Z"}])).
