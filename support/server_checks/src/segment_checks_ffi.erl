-module(segment_checks_ffi).
-export([counter/0, increment/1, count/1, keys/2, gzip_bomb/0]).
counter() -> atomics:new(1, []).
increment(Counter) -> atomics:add_get(Counter, 1, 1).
count(Counter) -> atomics:get(Counter, 1).
keys(Root, Id) ->
    Prefix = filename:join([Root, <<"sessions">>, Id]),
    Files = filelib:fold_files(binary_to_list(Prefix), ".*", true,
        fun(Path, Acc) -> [unicode:characters_to_binary(Path) | Acc] end, []),
    lists:sort([binary:part(Path, byte_size(Root)+1, byte_size(Path)-byte_size(Root)-1) || Path <- Files]).
gzip_bomb() -> zlib:gzip(binary:copy(<<"x">>, 33554433)).
