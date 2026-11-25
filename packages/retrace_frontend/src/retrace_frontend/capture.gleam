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
  State(
    info: Info,
    recorder: retrace.Recorder,
    client: Option(client.Client),
    clock: fn() -> Int,
    batching: Option(Batching),
  )
}

/// When to close the open batch: `window_ms` after its first observation, at
/// `max_entries` observations, or before an observation that would take the
/// encoded model and events past `max_bytes`.
pub type Batching {
  Batching(window_ms: Int, max_entries: Int, max_bytes: Int)
}

/// Mutable holder of the open batch, owned by one client runtime.
type Buffer

pub type Info {
  Info(
    session: wire.Session,
    captured: Int,
    saved: Int,
    delivery: client.Status,
    failure: Option(String),
  )
}

pub opaque type Message {
  Connected(client.Client)
  Delivery(client.Status)
  Saved(saved: Result(Nil, String), entries: Int)
}

/// Start a new identity; every application instance needs a distinct session.
pub fn session(
  user_ref: String,
  build: String,
  contract: String,
  platform: String,
) -> wire.Session {
  wire.Session(random_id(), user_ref, build, contract, platform)
}

pub fn start(
  session: wire.Session,
  config: client.Config,
  storage: client.Storage,
  transport: client.Transport,
) -> Result(#(State, Effect(Message)), retrace.Error(Nil)) {
  start_with_clock(session, config, storage, transport, monotonic_clock())
}

/// The clock returns elapsed milliseconds since this session began.
pub fn start_with_clock(
  session: wire.Session,
  config: client.Config,
  storage: client.Storage,
  transport: client.Transport,
  clock: fn() -> Int,
) -> Result(#(State, Effect(Message)), retrace.Error(Nil)) {
  use #(recorder, _) <- result.try(retrace.start(wire.origin(session), Nil))
  Ok(#(
    State(
      Info(
        session,
        0,
        0,
        client.Status(0, 0, "Opening local recording storage"),
        None,
      ),
      recorder,
      None,
      clock,
      None,
    ),
    effect.from(fn(dispatch) {
      let runtime =
        client.start_with(config, storage, transport, fn(status) {
          dispatch(Delivery(status))
        })
      dispatch(Connected(runtime))
    }),
  ))
}

/// Group observations into batches instead of saving one batch for each.
/// Apply this to the state returned by start, before the first observation.
///
/// A batch carries one checkpoint, the model before its first observation, so
/// the model is encoded and uploaded once per batch. Replay ranges start at
/// batch boundaries. Observations in the open batch are held in memory: they
/// are counted as captured but not as saved, and are lost if the page ends
/// before `flush`, `stop` or a limit closes the batch.
///
/// The limits are clamped to what one wire batch can hold: 1 to 128 entries and
/// at most half of the encoded size limit, which leaves room for JSON escaping.
pub fn with_batching(state: State, batching: Batching) -> State {
  State(
    ..state,
    batching: Some(Batching(
      window_ms: int.max(batching.window_ms, 0),
      max_entries: int.clamp(batching.max_entries, 1, wire.max_entries),
      max_bytes: int.clamp(batching.max_bytes, 1, wire.max_bytes / 2),
    )),
  )
}

pub fn info(state: State) -> Info {
  state.info
}

pub fn update(state: State, message: Message) -> State {
  case message {
    Connected(runtime) -> State(..state, client: Some(runtime))
    Delivery(status) ->
      State(..state, info: Info(..state.info, delivery: status))
    Saved(Ok(_), entries) ->
      State(
        ..state,
        info: Info(..state.info, saved: state.info.saved + entries),
      )
    Saved(Error(reason), _) -> failed(state, reason)
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
pub fn observe(
  state: State,
  before: model,
  message: message,
  encode_model: fn(model) -> String,
  encode_message: fn(message) -> wire.Event,
) -> #(State, Effect(Message)) {
  case state.info.failure, state.client {
    Some(_), _ -> #(state, effect.none())
    None, None -> #(
      failed(state, "Capture observed before connection. Start a new session."),
      effect.none(),
    )
    None, Some(runtime) -> {
      // Encoded only when a batch needs a checkpoint: once per batch.
      let checkpoint = fn() {
        retrace.checkpoint(state.recorder, encode_model(before))
      }
      let save = fn(checkpoint, entries, dispatch) {
        client.enqueue(
          runtime,
          wire.Batch(state.info.session, checkpoint, entries),
          fn(saved) { dispatch(Saved(saved, list.length(entries))) },
        )
      }
      case
        retrace.record(state.recorder, encode_message(message), state.clock())
      {
        Error(_) -> #(
          failed(state, "Invalid recording time. Start a new session."),
          effect.none(),
        )
        Ok(#(recorder, entry)) -> #(
          State(
            ..state,
            recorder: recorder,
            info: Info(..state.info, captured: state.info.captured + 1),
          ),
          effect.from(fn(dispatch) {
            case state.batching {
              None -> save(checkpoint(), [entry], dispatch)
              Some(batching) ->
                buffer_add(
                  buffer(runtime),
                  entry,
                  entry_bytes(entry),
                  fn() {
                    let checkpoint = checkpoint()
                    #(checkpoint, string.byte_size(checkpoint.model))
                  },
                  batching.window_ms,
                  batching.max_entries,
                  batching.max_bytes,
                  fn(checkpoint, entries) {
                    save(checkpoint, entries, dispatch)
                  },
                )
            }
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
    case state.client {
      Some(runtime) -> client.retry(runtime)
      None -> Nil
    }
  })
}

/// Save the open batch now instead of waiting for its window or limits. Use it
/// before the page may end, for example when it becomes hidden. Does nothing
/// without batching or with nothing buffered.
pub fn flush(state: State) -> Effect(Message) {
  effect.from(fn(_) {
    case state.client {
      Some(runtime) -> buffer_flush(buffer(runtime))
      None -> Nil
    }
  })
}

/// Run before discarding the application state. The open batch is saved
/// first. Persisted batches remain queued.
pub fn stop(state: State) -> Effect(Message) {
  effect.from(fn(_) {
    case state.client {
      Some(runtime) -> {
        buffer_flush(buffer(runtime))
        client.stop(runtime)
      }
      None -> Nil
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

@external(javascript, "../capture_ffi.mjs", "randomId")
fn random_id() -> String

@external(javascript, "../capture_ffi.mjs", "monotonicClock")
fn monotonic_clock() -> fn() -> Int
