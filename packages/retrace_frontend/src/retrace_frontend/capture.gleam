//// Optional capture coordination. Observe only application-approved transitions.
//// Map the returned effects/messages into your application. They are not events
//// to record. Stop the owned client when the application unmounts.

import gleam/option.{type Option, None, Some}
import gleam/result
import lustre/effect.{type Effect}
import retrace
import retrace/wire
import retrace_frontend/client

pub opaque type State {
  State(info: Info, phase: Phase, clock: fn() -> Int)
}

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
  Saved(Result(Nil, String))
}

/// Start capture for a new session. The connection effect starts the client and
/// asks the collector to open a session for `metadata`; the collector chooses
/// the session id and issues the write token every batch must carry. Recording
/// begins with the first transition observed after the session is open; the
/// session's first checkpoint is the state before that transition.
pub fn start(
  metadata: wire.Metadata,
  config: client.Config,
  storage: client.Storage,
  transport: client.Transport,
) -> Result(#(State, Effect(Message)), wire.Error) {
  start_with_clock(metadata, config, storage, transport, monotonic_clock())
}

/// The clock returns elapsed milliseconds since this session began.
pub fn start_with_clock(
  metadata: wire.Metadata,
  config: client.Config,
  storage: client.Storage,
  transport: client.Transport,
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
    Saved(Ok(_)), _ ->
      State(..state, info: Info(..state.info, saved: state.info.saved + 1))
    Saved(Error(reason)), _ -> failed(state, reason)
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
      let checkpoint = retrace.checkpoint(recorder, encode_model(before))
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
            client.enqueue(
              runtime,
              wire.Upload(
                grant.token,
                wire.Batch(grant.session, checkpoint, [entry]),
              ),
              fn(saved) { dispatch(Saved(saved)) },
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

/// Run before discarding the application state. Persisted batches remain queued.
pub fn stop(state: State) -> Effect(Message) {
  effect.from(fn(_) {
    case state.phase {
      Opening(runtime) | Recording(runtime, ..) -> client.stop(runtime)
      Connecting -> Nil
    }
  })
}

@external(javascript, "../capture_ffi.mjs", "monotonicClock")
fn monotonic_clock() -> fn() -> Int
