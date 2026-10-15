-module(retrace_server_ffi).
-export([digest/1, compress/1, decompress/1, directory_put/3, directory_get/2, directory_remove/2, read_concurrent_chunks/3]).
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

directory_remove(Root, Key) ->
    case path(Root, Key) of
        {ok, Path} -> case file:delete(Path) of
            ok -> {ok, nil};
            {error, enoent} -> {ok, nil};
            _ -> {error, unavailable}
        end;
        Error -> Error
    end.


%% The coordinator belongs to this one synchronous call. It monitors the caller
%% and links every read worker so even an uncatchable coordinator exit terminates
%% its outstanding work. No borrowed database, store or transport is stopped.
read_concurrent_chunks(Chunks, Limit, Read) ->
    Caller = self(), Tag = make_ref(),
    {Coordinator, Monitor} = spawn_monitor(fun() ->
        process_flag(trap_exit, true),
        CallerMonitor = monitor(process, Caller),
        put(read_workers, []),
        Result = try
            Indexed = lists:zip(lists:seq(1, length(Chunks)), Chunks),
            collect_reads(Indexed, #{}, #{}, Limit, Read, CallerMonitor)
        after
            stop_read_workers(get(read_workers)),
            demonitor(CallerMonitor, [flush])
        end,
        Caller ! {Tag, Result}
    end),
    receive
        {Tag, Result} ->
            receive {'DOWN', Monitor, process, Coordinator, _} -> Result end;
        {'DOWN', Monitor, process, Coordinator, _} -> {error, {storage, unavailable}}
    end.

collect_reads(Pending, Active, Results, Limit, Read, CallerMonitor)
  when map_size(Active) < Limit, Pending =/= [] ->
    [{Index, Chunk} | Rest] = Pending,
    Coordinator = self(),
    Worker = spawn_link(fun() ->
        Result = try Read(Chunk) catch _:_ -> {error, {storage, unavailable}} end,
        Coordinator ! {read_result, self(), Result}
    end),
    put(read_workers, [Worker | get(read_workers)]),
    collect_reads(Rest, Active#{Worker => Index}, Results, Limit, Read, CallerMonitor);
collect_reads([], Active, Results, _, _, _) when map_size(Active) =:= 0 ->
    {ok, [maps:get(Index, Results) || Index <- lists:seq(1, map_size(Results))]};
collect_reads(Pending, Active, Results, Limit, Read, CallerMonitor) ->
    receive
        {'DOWN', CallerMonitor, process, _, _} -> exit(normal);
        {read_result, Worker, {ok, Batch}} when is_map_key(Worker, Active) ->
            Index = maps:get(Worker, Active),
            collect_reads(Pending, maps:remove(Worker, Active), Results#{Index => Batch}, Limit, Read, CallerMonitor);
        {read_result, Worker, {error, _} = Error} when is_map_key(Worker, Active) -> Error;
        {'EXIT', Worker, _} when is_map_key(Worker, Active) -> {error, {storage, unavailable}};
        {'EXIT', _, _} -> collect_reads(Pending, Active, Results, Limit, Read, CallerMonitor)
    end.

stop_read_workers(Workers) ->
    Monitored = [{Pid, monitor(process, Pid)} || Pid <- Workers],
    lists:foreach(fun({Pid, _}) -> exit(Pid, kill) end, Monitored),
    lists:foreach(fun({Pid, Monitor}) ->
        receive {'DOWN', Monitor, process, Pid, _} -> ok end
    end, Monitored).
