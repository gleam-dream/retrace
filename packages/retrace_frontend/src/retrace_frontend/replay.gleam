//// Optional replay composition. Application-native types stay inside the artifact.

import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import lustre
import lustre/attribute
import lustre/effect
import lustre/element.{type Element}
import lustre/element/html
import retrace
import retrace/wire

pub type Viewport {
  Viewport(width: Int, height: Int)
}

pub type ReplayModule(model, message, error) {
  ReplayModule(
    contract: String,
    decode_model: fn(String) -> Result(model, String),
    decode_event: fn(wire.Event) -> Result(message, String),
    reduce: fn(model, message) -> Result(model, error),
    equal: fn(model, model) -> Bool,
    view: fn(model) -> Element(message),
    viewport: fn(model) -> Viewport,
    label: fn(wire.Event) -> String,
  )
}

pub type Snapshot(model) {
  Snapshot(
    sequence: Int,
    elapsed_ms: Int,
    kind: String,
    label: String,
    model: model,
  )
}

pub type Error(error) {
  InvalidRange(String)
  InvalidReplay(retrace.Error(error))
}

/// Loads a checkpoint plus contiguous entries; no effects are executed.
/// A failed load returns no partially validated snapshots.
pub fn load(
  app: ReplayModule(model, message, error),
  batches: List(wire.Batch),
  build: String,
  max_entries: Int,
) -> Result(List(Snapshot(model)), Error(error)) {
  use first <- result.try(
    list.first(batches)
    |> result.map_error(fn(_) { InvalidRange("No recorded events") }),
  )
  case
    first.session.build == build
    && first.session.contract == app.contract
    && max_entries > 0
    && list.fold(batches, 0, fn(n, b) { n + list.length(b.entries) })
    <= max_entries
  {
    False -> Error(InvalidRange("Unsupported build, contract or range size"))
    True -> {
      use checkpoint <- result.try(decode_checkpoint(app, first))
      use player <- result.try(
        retrace.replay(checkpoint, app.contract, app.reduce)
        |> result.map_error(InvalidReplay),
      )
      use #(_, snapshots) <- result.try(
        list.try_fold(
          batches,
          #(player, [
            Snapshot(
              checkpoint.sequence,
              checkpoint.elapsed_ms,
              "Checkpoint",
              "Checkpoint",
              checkpoint.model,
            ),
          ]),
          fn(state, batch) {
            use _ <- result.try(
              wire.validate(batch)
              |> result.map_error(fn(_) { InvalidRange("Invalid envelope") }),
            )
            case batch.session == first.session {
              False ->
                Error(InvalidRange(
                  "Session metadata changed inside the recording",
                ))
              True -> {
                let #(player, snapshots) = state
                use checkpoint <- result.try(decode_checkpoint(app, batch))
                use _ <- result.try(
                  retrace.verify(player, checkpoint, app.equal)
                  |> result.map_error(InvalidReplay),
                )
                list.try_fold(
                  batch.entries,
                  #(player, snapshots),
                  fn(state, entry) {
                    let #(player, snapshots) = state
                    use message <- result.try(
                      app.decode_event(entry.event)
                      |> result.map_error(InvalidRange),
                    )
                    use next <- result.try(
                      retrace.step(
                        player,
                        retrace.Entry(
                          entry.origin,
                          entry.sequence,
                          entry.elapsed_ms,
                          message,
                        ),
                      )
                      |> result.map_error(InvalidReplay),
                    )
                    Ok(
                      #(next, [
                        Snapshot(
                          entry.sequence,
                          entry.elapsed_ms,
                          entry.event.kind,
                          app.label(entry.event),
                          retrace.model(next),
                        ),
                        ..snapshots
                      ]),
                    )
                  },
                )
              }
            }
          },
        ),
      )
      Ok(list.reverse(snapshots))
    }
  }
}

fn decode_checkpoint(
  app: ReplayModule(model, message, error),
  batch: wire.Batch,
) -> Result(retrace.Checkpoint(model), Error(error)) {
  use model <- result.try(
    app.decode_model(batch.checkpoint.model) |> result.map_error(InvalidRange),
  )
  Ok(retrace.Checkpoint(
    batch.checkpoint.origin,
    batch.checkpoint.sequence,
    batch.checkpoint.elapsed_ms,
    model,
  ))
}

pub fn describe(
  app: ReplayModule(model, message, error),
  snapshots: List(Snapshot(model)),
) -> String {
  json.array(snapshots, fn(snapshot) {
    let viewport = app.viewport(snapshot.model)
    json.object([
      #("sequence", json.int(snapshot.sequence)),
      #("elapsed", json.int(snapshot.elapsed_ms)),
      #("kind", json.string(snapshot.kind)),
      #("label", json.string(snapshot.label)),
      #(
        "viewport",
        json.object([
          #("width", json.int(viewport.width)),
          #("height", json.int(viewport.height)),
        ]),
      ),
    ])
  })
  |> json.to_string
}

type Frame(model) {
  Frame(snapshots: List(Snapshot(model)), sequence: Int, error: String)
}

type FrameMessage {
  Load(String)
  Seek(Int)
  Ignore
}

fn decode_batches(input: String) -> Result(List(wire.Batch), String) {
  use values <- result.try(
    json.parse(input, decode.list(decode.string))
    |> result.map_error(fn(_) { "Invalid range response" }),
  )
  list.try_map(values, fn(value) {
    wire.decode_batch(value)
    |> result.map_error(fn(_) { "Invalid stored recording" })
  })
}

/// Mount one trusted same-origin frame. Call the returned function to stop it.
/// The host owns element lifetime; effects and live capture never run here.
pub fn mount(
  app: ReplayModule(model, message, error),
  build: String,
  selector: String,
  max_entries: Int,
) -> Result(fn() -> Nil, lustre.Error) {
  let init = fn(_: Nil) {
    #(Frame([], 0, "Waiting for a recording"), effect.none())
  }
  let update = fn(model: Frame(model), message: FrameMessage) {
    case message {
      Load(body) -> {
        let loaded =
          decode_batches(body)
          |> result.map_error(InvalidRange)
          |> result.try(fn(batches) { load(app, batches, build, max_entries) })
        case loaded {
          Error(reason) -> {
            let detail = string.inspect(reason)
            #(
              Frame([], 0, detail),
              effect.from(fn(_) { report("error", detail) }),
            )
          }
          Ok(snapshots) -> {
            let sequence =
              list.first(snapshots)
              |> result.map(fn(s) { s.sequence })
              |> result.unwrap(0)
            #(
              Frame(snapshots, sequence, ""),
              effect.from(fn(_) { report("loaded", describe(app, snapshots)) }),
            )
          }
        }
      }
      Seek(sequence) ->
        case list.any(model.snapshots, fn(s) { s.sequence == sequence }) {
          True -> #(Frame(..model, sequence: sequence), effect.none())
          False -> #(
            Frame([], 0, "Sequence outside the loaded range"),
            effect.from(fn(_) {
              report("error", "Sequence outside the loaded range")
            }),
          )
        }
      Ignore -> #(model, effect.none())
    }
  }
  let view = fn(model: Frame(model)) {
    case list.find(model.snapshots, fn(s) { s.sequence == model.sequence }) {
      Ok(snapshot) ->
        html.div(
          [attribute.class("replay-root"), attribute.attribute("inert", "")],
          [app.view(snapshot.model) |> element.map(fn(_) { Ignore })],
        )
      Error(_) -> html.p([attribute.role("status")], [html.text(model.error)])
    }
  }
  use #(target, remove) <- result.try(prepare_target(selector))
  use runtime <- result.try(
    case lustre.application(init, update, view) |> lustre.start(target, Nil) {
      Ok(runtime) -> Ok(runtime)
      Error(reason) -> {
        remove()
        Error(reason)
      }
    },
  )
  let unlisten =
    listen(
      build,
      fn(body) { lustre.send(runtime, lustre.dispatch(Load(body))) },
      fn(sequence) { lustre.send(runtime, lustre.dispatch(Seek(sequence))) },
    )
  Ok(
    once(fn() {
      unlisten()
      lustre.send(runtime, lustre.shutdown())
      remove()
    }),
  )
}

@external(javascript, "../replay_ffi.mjs", "listen")
fn listen(
  build: String,
  load: fn(String) -> Nil,
  seek: fn(Int) -> Nil,
) -> fn() -> Nil

@external(javascript, "../replay_ffi.mjs", "report")
fn report(kind: String, body: String) -> Nil

@external(javascript, "../replay_ffi.mjs", "prepareTarget")
fn prepare_target(
  selector: String,
) -> Result(#(String, fn() -> Nil), lustre.Error)

@external(javascript, "../replay_ffi.mjs", "once")
fn once(dispose: fn() -> Nil) -> fn() -> Nil
