-module(concurrent_read_checks_ffi).
-export([probe/0, observed_get/3, peak/1, active/1, lifetime_check/1, wrong_digest/0, monotonic_ms/0]).
monotonic_ms() -> erlang:monotonic_time(millisecond).
probe() -> atomics:new(2, [{signed, true}]).
wrong_digest() -> zlib:gzip(<<"{}">>).
peak(Probe) -> atomics:get(Probe, 2).
active(Probe) -> atomics:get(Probe, 1).
observed_get(Probe, Get, Key) ->
    Current = atomics:add_get(Probe, 1, 1),
    update_peak(Probe, Current),
    try
        % Different object latencies deliberately complete out of sequence.
        timer:sleep(1 + erlang:phash2(Key, 12)),
        Get(Key)
    after atomics:sub(Probe, 1, 1) end.
update_peak(Probe, Value) ->
    Old = atomics:get(Probe, 2),
    case Old >= Value of
        true -> ok;
        false -> case atomics:compare_exchange(Probe, 2, Old, Value) of
            ok -> ok;
            _ -> update_peak(Probe, Value)
        end
    end.

lifetime_check(Run) ->
    lists:foreach(fun(Reason) -> caller_death(Run, Reason) end, [shutdown, kill]),
    lists:foreach(fun(Failure) -> callback_crash(Run, Failure) end,
        [crash, kill, throw, exit_normal, self_normal]),
    nil.
blocking_get(Owner, Tag) ->
    fun(_) ->
        Owner ! {Tag, entered, self()},
        receive
            crash -> error(injected_adapter_crash);
            kill -> exit(self(), kill);
            throw -> throw(injected_adapter_throw);
            exit_normal -> exit(normal);
            self_normal -> exit(self(), normal)
        end
    end.
entered(Tag, Count) -> entered(Tag, Count, []).
entered(_, 0, Pids) -> Pids;
entered(Tag, Count, Pids) ->
    receive {Tag, entered, Pid} -> entered(Tag, Count - 1, [Pid | Pids])
    after 3000 -> error(read_workers_not_started) end.
assert_stopped(Pids) ->
    lists:foreach(fun(Pid) ->
        Monitor = monitor(process, Pid),
        receive {'DOWN', Monitor, process, Pid, _} -> ok
        after 3000 -> error({read_worker_leaked, Pid}) end
    end, Pids).
caller_death(Run, Reason) ->
    Owner = self(), Tag = make_ref(),
    {Caller, Monitor} = spawn_monitor(fun() -> Run(blocking_get(Owner, Tag)) end),
    Pids = entered(Tag, 4),
    exit(Caller, Reason),
    receive {'DOWN', Monitor, process, Caller, _} -> ok after 3000 -> error(caller_survived) end,
    assert_stopped(Pids).
callback_crash(Run, Failure) ->
    Owner = self(), Tag = make_ref(),
    {Caller, Monitor} = spawn_monitor(fun() -> Owner ! {Tag, result, Run(blocking_get(Owner, Tag))} end),
    Pids = entered(Tag, 4),
    hd(Pids) ! Failure,
    receive {Tag, result, {error, {storage, unavailable}}} -> ok
    after 3000 -> error(adapter_crash_not_reported) end,
    assert_stopped(Pids),
    receive {'DOWN', Monitor, process, Caller, normal} -> ok after 3000 -> error(caller_survived) end.
