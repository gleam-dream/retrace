-module(retrace_server_ffi).
-export([digest/1, compress/1, decompress/1, directory_put/3, directory_get/2, directory_remove/2, decompress_bounded/2]).
digest(Input) -> binary:encode_hex(crypto:hash(sha256, Input)).
compress(Input) -> zlib:gzip(Input).
decompress(Input) -> decompress_bounded(Input, 1048576).
%% safeInflate emits bounded chunks, so a gzip bomb is rejected before its full
%% expansion is allocated. inflateEnd also refuses truncated streams.
decompress_bounded(Input, Limit) when byte_size(Input) =< Limit + 65536 ->
    Z = zlib:open(),
    try
        ok = zlib:inflateInit(Z, 31, error),
        Result = inflate_bounded(Z, Input, Limit, 0, []),
        ok = zlib:inflateEnd(Z),
        Result
    catch _:_ -> {error, nil}
    after zlib:close(Z) end;
decompress_bounded(_, _) -> {error, nil}.
inflate_bounded(Z, Input, Limit, Count, Acc) ->
    case zlib:safeInflate(Z, Input) of
        {Status, Output} when Status =:= continue; Status =:= finished ->
            Next = Count + iolist_size(Output),
            case Next =< Limit of
                false -> {error, nil};
                true when Status =:= finished -> {ok, iolist_to_binary(lists:reverse([Output | Acc]))};
                true -> inflate_bounded(Z, [], Limit, Next, [Output | Acc])
            end;
        _ -> {error, nil}
    end.
path(Root, Key) ->
    case byte_size(Key) > 0 andalso binary:match(Key, <<"..">>) =:= nomatch andalso binary:at(Key, 0) =/= $/ of
        true -> {ok, filename:join(Root, Key)};
        false -> {error, invalid_object}
    end.
directory_put(Root, Key, Body) ->
    case path(Root, Key) of
        {ok, Path} ->
            Tmp = <<Path/binary, ".", (integer_to_binary(erlang:unique_integer([positive])))/binary, ".tmp">>,
            case filelib:ensure_dir(Path) of
                ok -> case file:write_file(Tmp, Body, [raw, binary, sync]) of
                    ok -> case file:rename(Tmp, Path) of ok -> {ok, nil}; _ -> {error, unavailable} end;
                    _ -> {error, unavailable}
                end;
                _ -> {error, unavailable}
            end;
        Error -> Error
    end.
directory_get(Root, Key) ->
    case path(Root, Key) of
        {ok, Path} -> case file:read_file(Path) of
            {ok, Body} -> {ok, Body};
            {error, enoent} -> {error, missing};
            _ -> {error, unavailable}
        end;
        Error -> Error
    end.

directory_remove(Root, Key) ->
    case path(Root, Key) of
        {ok, Path} -> case file:delete(Path) of
            ok -> {ok, nil};
            {error, enoent} -> {ok, nil};
            _ -> {error, unavailable}
        end;
        Error -> Error
    end.
