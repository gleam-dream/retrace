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
  State(
    info: Info,
    recorder: retrace.Recorder,
    client: Option(client.Client),
    clock: fn() -> Int,
  )
}

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
  Saved(Result(Nil, String))
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

pub fn info(state: State) -> Info {
  state.info
}

pub fn update(state: State, message: Message) -> State {
  case message {
    Connected(runtime) -> State(..state, client: Some(runtime))
    Delivery(status) ->
      State(..state, info: Info(..state.info, delivery: status))
    Saved(Ok(_)) ->
      State(..state, info: Info(..state.info, saved: state.info.saved + 1))
    Saved(Error(reason)) -> failed(state, reason)
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
      let checkpoint = retrace.checkpoint(state.recorder, encode_model(before))
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
            client.enqueue(
              runtime,
              wire.Batch(state.info.session, checkpoint, [entry]),
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
    case state.client {
      Some(runtime) -> client.retry(runtime)
      None -> Nil
    }
  })
}

/// Run before discarding the application state. Persisted batches remain queued.
pub fn stop(state: State) -> Effect(Message) {
  effect.from(fn(_) {
    case state.client {
      Some(runtime) -> client.stop(runtime)
      None -> Nil
    }
  })
}

@external(javascript, "../capture_ffi.mjs", "randomId")
fn random_id() -> String

@external(javascript, "../capture_ffi.mjs", "monotonicClock")
fn monotonic_clock() -> fn() -> Int
