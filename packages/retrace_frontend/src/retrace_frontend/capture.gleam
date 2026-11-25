//// Optional capture coordination. Observe only application-approved transitions.
//// Map the returned effects/messages into your application. They are not events
//// to record. Stop the owned client when the application unmounts.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import lustre/effect.{type Effect}
import retrace
import retrace/wire
import retrace_frontend/client

pub opaque type State {
  State(info: Info, phase: Phase, clock: fn() -> Int, flush_after_ms: Int)
}

/// Mutable holder of the open batch, owned by one client runtime.
type Buffer

// The client exists from connection on; the session and its recorder exist only
// once the collector has issued them.
type Phase {
  Connecting
  Opening(client: client.Client)
  Recording(
    client: client.Client,
    grant: wire.Grant,
    recorder: retrace.Recorder,
  )
}

pub type Info {
  Info(
    /// The session the collector issued; `None` until it has answered.
    session: Option(wire.Session),
    captured: Int,
    saved: Int,
    delivery: client.Status,
    failure: Option(String),
  )
}

pub opaque type Message {
  Connected(client.Client)
  Opened(Result(wire.Grant, String))
  Delivery(client.Status)
  Saved(saved: Result(Nil, String), entries: Int)
}

/// Start capture for a new session. The connection effect starts the client and
/// asks the collector to open a session for `metadata`; the collector chooses
/// the session id and issues the write token every batch must carry. Recording
/// begins with the first transition observed after the session is open; the
/// session's first checkpoint is the state before that transition.
///
/// Observations are uploaded in batches. A batch opens at an observation and
/// closes `flush_after_ms` later, at the wire format's 128 entries, before an
/// observation that would take it past half of the wire byte limit, on `flush`
/// and on `stop`. It carries one checkpoint, the state before its first
/// observation, so the model is encoded and uploaded once per batch, and replay
/// ranges start at batch boundaries. With a window of zero every observation is
/// saved at once as its own batch. Held observations count as captured and not
/// as saved. In a browser the open batch also closes when the page becomes
/// hidden or navigates away, just before the client hands its unacknowledged
/// batches over, so the last observations leave with the page.
pub fn start(
  metadata: wire.Metadata,
  config: client.Config,
  storage: client.Storage,
  transport: client.Transport,
  flush_after_ms: Int,
) -> Result(#(State, Effect(Message)), wire.Error) {
  start_with_clock(
    metadata,
    config,
    storage,
    transport,
    flush_after_ms,
    monotonic_clock(),
  )
}

/// The clock returns elapsed milliseconds since this session began.
pub fn start_with_clock(
  metadata: wire.Metadata,
  config: client.Config,
  storage: client.Storage,
  transport: client.Transport,
  flush_after_ms: Int,
  clock: fn() -> Int,
) -> Result(#(State, Effect(Message)), wire.Error) {
  use _ <- result.try(wire.validate_metadata(metadata))
  Ok(#(
    State(
      Info(
        None,
        0,
        0,
        client.Status(0, 0, "Opening local recording storage"),
        None,
      ),
      Connecting,
      clock,
      int.max(flush_after_ms, 0),
    ),
    effect.from(fn(dispatch) {
      let runtime =
        client.start_with(config, storage, transport, fn(status) {
          dispatch(Delivery(status))
        })
      dispatch(Connected(runtime))
      client.open(runtime, metadata, fn(grant) { dispatch(Opened(grant)) })
    }),
  ))
}

pub fn info(state: State) -> Info {
  state.info
}

pub fn update(state: State, message: Message) -> State {
  case message, state.phase {
    Connected(runtime), _ -> State(..state, phase: Opening(runtime))
    Opened(Ok(grant)), Opening(runtime) ->
      case retrace.start(wire.origin(grant.session), Nil) {
        Ok(#(recorder, _)) ->
          State(
            ..state,
            phase: Recording(runtime, grant, recorder),
            info: Info(..state.info, session: Some(grant.session)),
          )
        Error(_) ->
          failed(state, "Invalid recording session. Start a new session.")
      }
    Opened(Ok(_)), _ -> state
    Opened(Error(reason)), _ -> failed(state, reason)
    Delivery(status), _ ->
      State(..state, info: Info(..state.info, delivery: status))
    Saved(Ok(_), entries), _ ->
      State(
        ..state,
        info: Info(..state.info, saved: state.info.saved + entries),
      )
    Saved(Error(reason), _), _ -> failed(state, reason)
  }
}

fn failed(state: State, reason: String) -> State {
  case state.info.failure {
    Some(_) -> state
    None -> State(..state, info: Info(..state.info, failure: Some(reason)))
  }
}

/// Observe after accepting a transition, passing its state BEFORE reduction.
/// This helper never runs application effects. Record their resulting messages
/// through this same hook. A failure stops capture; your update still proceeds.
/// Before the session is open nothing is recorded, so the recording starts at a
/// checkpoint instead of leaving a gap.
pub fn observe(
  state: State,
  before: model,
  message: message,
  encode_model: fn(model) -> String,
  encode_message: fn(message) -> wire.Event,
) -> #(State, Effect(Message)) {
  case state.info.failure, state.phase {
    Some(_), _ | None, Connecting | None, Opening(_) -> #(state, effect.none())
    None, Recording(runtime, grant, recorder) -> {
      // Encoded only when a batch needs its checkpoint: once per batch.
      let checkpoint = fn() {
        let checkpoint = retrace.checkpoint(recorder, encode_model(before))
        #(checkpoint, string.byte_size(checkpoint.model))
      }
      case retrace.record(recorder, encode_message(message), state.clock()) {
        Error(_) -> #(
          failed(state, "Invalid recording time. Start a new session."),
          effect.none(),
        )
        Ok(#(recorder, entry)) -> #(
          State(
            ..state,
            phase: Recording(runtime, grant, recorder),
            info: Info(..state.info, captured: state.info.captured + 1),
          ),
          effect.from(fn(dispatch) {
            buffer_add(
              buffer(runtime),
              entry,
              entry_bytes(entry),
              checkpoint,
              state.flush_after_ms,
              wire.max_entries,
              // Half the wire limit leaves room for JSON escaping of the model.
              wire.max_bytes / 2,
              fn(checkpoint, entries) {
                client.enqueue(
                  runtime,
                  wire.Upload(
                    grant.token,
                    wire.Batch(grant.session, checkpoint, entries),
                  ),
                  fn(saved) { dispatch(Saved(saved, list.length(entries))) },
                )
              },
            )
          }),
        )
      }
    }
  }
}

/// Observe an application's fallible safe projection of an accepted transition.
/// The pair contains the safe state BEFORE the transition and its safe event.
/// Only successful projections reach the codecs. Failure stops capture without
/// recording the application's error, which may itself contain private values.
/// This does not classify data or prove the projection/codecs safe or pure.
pub fn observe_projected(
  state: State,
  projection: Result(#(model, message), error),
  encode_model: fn(model) -> String,
  encode_message: fn(message) -> wire.Event,
) -> #(State, Effect(Message)) {
  case projection {
    Ok(#(before, message)) ->
      observe(state, before, message, encode_model, encode_message)
    Error(_) -> #(
      failed(state, "Safe projection failed. Start a new session."),
      effect.none(),
    )
  }
}

pub fn retry(state: State) -> Effect(Message) {
  effect.from(fn(_) {
    case state.phase {
      Opening(runtime) | Recording(runtime, ..) -> client.retry(runtime)
      Connecting -> Nil
    }
  })
}

/// Save the open batch now instead of waiting for its window. A browser page
/// that becomes hidden or navigates away already does this before the hand-over.
/// Does nothing when no observation is held.
pub fn flush(state: State) -> Effect(Message) {
  effect.from(fn(_) {
    case state.phase {
      Recording(runtime, ..) -> buffer_flush(buffer(runtime))
      Opening(_) | Connecting -> Nil
    }
  })
}

/// Run before discarding the application state. The open batch is saved
/// first. Persisted batches remain queued.
pub fn stop(state: State) -> Effect(Message) {
  effect.from(fn(_) {
    case state.phase {
      Recording(runtime, ..) -> {
        buffer_flush(buffer(runtime))
        client.stop(runtime)
      }
      Opening(runtime) -> client.stop(runtime)
      Connecting -> Nil
    }
  })
}

// Approximate encoded size of one entry: its strings plus its JSON envelope.
fn entry_bytes(entry: retrace.Entry(wire.Event)) -> Int {
  string.byte_size(entry.event.kind)
  + string.byte_size(entry.event.payload)
  + 96
}

@external(javascript, "../capture_ffi.mjs", "buffer")
fn buffer(runtime: client.Client) -> Buffer

@external(javascript, "../capture_ffi.mjs", "bufferAdd")
fn buffer_add(
  buffer: Buffer,
  entry: retrace.Entry(wire.Event),
  bytes: Int,
  checkpoint: fn() -> #(retrace.Checkpoint(String), Int),
  window_ms: Int,
  max_entries: Int,
  max_bytes: Int,
  save: fn(retrace.Checkpoint(String), List(retrace.Entry(wire.Event))) -> Nil,
) -> Nil

@external(javascript, "../capture_ffi.mjs", "bufferFlush")
fn buffer_flush(buffer: Buffer) -> Nil

@external(javascript, "../capture_ffi.mjs", "monotonicClock")
fn monotonic_clock() -> fn() -> Int
