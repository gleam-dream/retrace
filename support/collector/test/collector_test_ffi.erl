-module(collector_test_ffi).
-export([exchange/2]).

%% Sends raw request bytes in pieces and reads one HTTP/1.1 response, so a
%% test controls framing that ordinary HTTP clients choose for themselves.
exchange(Port, Pieces) ->
    case gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 5000) of
        {error, Reason} -> {error, Reason};
        {ok, Socket} ->
            lists:foreach(fun(Piece) -> _ = gen_tcp:send(Socket, Piece) end, Pieces),
            Result = receive_response(Socket, <<>>),
            gen_tcp:close(Socket),
            Result
    end.

receive_response(Socket, Acc) ->
    case complete(Acc) of
        true -> {ok, Acc};
        false ->
            case gen_tcp:recv(Socket, 0, 5000) of
                {ok, Data} -> receive_response(Socket, <<Acc/binary, Data/binary>>);
                {error, _} when Acc =/= <<>> -> {ok, Acc};
                {error, Reason} -> {error, Reason}
            end
    end.

%% 1xx, 204 and 304 responses carry no body, and mist sends them without
%% Content-Length on a kept-alive connection, so the headers complete them.
complete(Acc) ->
    case binary:split(Acc, <<"\r\n\r\n">>) of
        [<<"HTTP/1.1 ", Code:3/binary, _/binary>> = Head, Body] ->
            case Code of
                <<"1", _/binary>> -> true;
                <<"204">> -> true;
                <<"304">> -> true;
                _ ->
                    Lower = string:lowercase(Head),
                    case re:run(Lower, <<"content-length: *([0-9]+)">>, [{capture, all_but_first, binary}]) of
                        {match, [Length]} -> byte_size(Body) >= binary_to_integer(Length);
                        nomatch -> false
                    end
            end;
        _ -> false
    end.
