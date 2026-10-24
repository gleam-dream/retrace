-module(quiescence_checks_ffi).
%% Test adapter for a provider that may finish an accepted PUT after the caller
%% saw a failure. Mutable shared state cannot be held in typed Gleam values.
-export([provider/0, pend/3, publish_pending/1, publish/3, get/2, remove/2, objects/1, puts/1]).
provider() -> ets:new(provider, [public, set]).
pend(P, Key, Bytes) ->
    ets:insert(P, {{pending, erlang:unique_integer([monotonic])}, Key, Bytes}),
    count(P),
    nil.
publish(P, Key, Bytes) -> count(P), ets:insert(P, {{object, Key}, Bytes}), nil.
publish_pending(P) ->
    Pending = ets:select(P, [{{{pending, '$1'}, '$2', '$3'}, [], [{{'$1', '$2', '$3'}}]}]),
    lists:foreach(fun({N, Key, Bytes}) ->
        ets:insert(P, {{object, Key}, Bytes}), ets:delete(P, {pending, N}) end, lists:sort(Pending)),
    length(Pending).
get(P, Key) -> case ets:lookup(P, {object, Key}) of [{_, Bytes}] -> {ok, Bytes}; [] -> {error, missing} end.
remove(P, Key) -> ets:delete(P, {object, Key}), {ok, nil}.
objects(P) -> lists:sort(ets:select(P, [{{{object, '$1'}, '_'}, [], ['$1']}])).
puts(P) -> case ets:lookup(P, puts) of [{_, N}] -> N; [] -> 0 end.
count(P) -> ets:update_counter(P, puts, 1, {puts, 0}).
