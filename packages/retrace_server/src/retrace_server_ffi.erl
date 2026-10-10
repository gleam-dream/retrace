-module(retrace_server_ffi).
-export([digest/1, compress/1, decompress/1, directory_put/3, directory_get/2]).
digest(Input) -> binary:encode_hex(crypto:hash(sha256, Input)).
compress(Input) -> zlib:gzip(Input).
decompress(Input) ->
    try zlib:gunzip(Input) of
        Body when byte_size(Body) =< 1048576 -> {ok, Body};
        _ -> {error, nil}
    catch _:_ -> {error, nil} end.
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
