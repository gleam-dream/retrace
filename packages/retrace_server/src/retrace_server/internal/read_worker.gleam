//// Request-scoped archive reads. Process links own worker lifetime; typed
//// subjects and selectors keep scheduling and ordered results in Gleam.

import exception
import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/result

type Reply(value, error) {
  Finished(Result(List(value), error))
  CoordinatorDown(process.Down)
}

type Message(value, error) {
  Completed(process.Pid, Result(value, error))
  WorkerExited(process.ExitMessage)
  CallerDown(process.Down)
}

@internal
pub fn run(
  values: List(input),
  concurrency: Int,
  read: fn(input) -> Result(value, error),
  unavailable: error,
) -> Result(List(value), error) {
  let caller = process.self()
  let replies = process.new_subject()
  let coordinator =
    process.spawn_unlinked(fn() {
      coordinate(caller, replies, values, concurrency, read, unavailable)
    })
  let monitor = process.monitor(coordinator)
  use <- exception.defer(fn() { process.demonitor_process(monitor) })
  let down =
    process.new_selector()
    |> process.select_specific_monitor(monitor, CoordinatorDown)
  case
    down
    |> process.select(replies)
    |> process.selector_receive_forever
  {
    Finished(result) -> {
      // Completion is sent only after every worker cleanup has run. Also wait
      // for the coordinator so this call retains no process or monitor.
      let _ = process.selector_receive_forever(down)
      result
    }
    CoordinatorDown(_) -> Error(unavailable)
  }
}

fn coordinate(
  caller: process.Pid,
  replies: process.Subject(Reply(value, error)),
  values: List(input),
  concurrency: Int,
  read: fn(input) -> Result(value, error),
  unavailable: error,
) -> Nil {
  process.trap_exits(True)
  let monitor = process.monitor(caller)
  use <- exception.defer(fn() { process.demonitor_process(monitor) })
  let messages = process.new_subject()
  let selector =
    process.new_selector()
    |> process.select(messages)
    |> process.select_specific_monitor(monitor, CallerDown)
    |> process.select_trapped_exits(WorkerExited)
  let result =
    exception.rescue(fn() {
      collect(
        list.index_map(values, fn(value, index) { #(index, value) }),
        dict.new(),
        dict.new(),
        int.clamp(concurrency, min: 1, max: 16),
        read,
        unavailable,
        messages,
        selector,
      )
    })
    |> result.unwrap(Error(unavailable))
  process.send(replies, Finished(result))
}

fn collect(
  pending: List(#(Int, input)),
  active: Dict(process.Pid, Int),
  results: Dict(Int, value),
  limit: Int,
  read: fn(input) -> Result(value, error),
  unavailable: error,
  messages: process.Subject(Message(value, error)),
  selector: process.Selector(Message(value, error)),
) -> Result(List(value), error) {
  let active_count = dict.size(active)
  case pending, active_count < limit {
    [#(index, value), ..rest], True -> {
      let worker =
        process.spawn(fn() {
          // Adapters can be foreign code. Convert their exceptions without
          // exposing payloads in a proc_lib crash report.
          let result =
            exception.rescue(fn() { read(value) })
            |> result.unwrap(Error(unavailable))
          process.send(messages, Completed(process.self(), result))
        })
      // Each bounded invocation retains a cleanup frame for every worker it
      // starts. This also unwinds on a coordinator exception, without a process
      // dictionary or a custom Erlang receive loop.
      use <- exception.defer(fn() { stop(worker) })
      collect(
        rest,
        dict.insert(active, worker, index),
        results,
        limit,
        read,
        unavailable,
        messages,
        selector,
      )
    }
    [], _ if active_count == 0 -> {
      results
      |> dict.to_list
      |> list.sort(fn(a, b) { int.compare(a.0, b.0) })
      |> list.map(fn(pair) { pair.1 })
      |> Ok
    }
    _, _ -> {
      case process.selector_receive_forever(selector) {
        CallerDown(_) -> Error(unavailable)
        Completed(worker, result) -> {
          case dict.get(active, worker), result {
            Ok(index), Ok(value) ->
              collect(
                pending,
                dict.delete(active, worker),
                dict.insert(results, index, value),
                limit,
                read,
                unavailable,
                messages,
                selector,
              )
            Ok(_), Error(error) -> Error(error)
            Error(Nil), _ ->
              collect(
                pending,
                active,
                results,
                limit,
                read,
                unavailable,
                messages,
                selector,
              )
          }
        }
        WorkerExited(process.ExitMessage(worker, _)) -> {
          case dict.has_key(active, worker) {
            True -> Error(unavailable)
            False ->
              collect(
                pending,
                active,
                results,
                limit,
                read,
                unavailable,
                messages,
                selector,
              )
          }
        }
      }
    }
  }
}

fn stop(worker: process.Pid) -> Nil {
  let monitor = process.monitor(worker)
  process.kill(worker)
  let _ =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive_forever
  process.demonitor_process(monitor)
}
