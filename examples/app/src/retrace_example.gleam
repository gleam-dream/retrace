import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import retrace
import retrace/wire
import retrace_client
import retrace_example/api
import retrace_example/domain
import retrace_example/viewer
import timetravel

type Screen {
  LiveApp
  Sessions
}

type Model {
  Model(
    screen: Screen,
    live: domain.Model,
    session: wire.Session,
    recorder: retrace.Recorder,
    client: Option(retrace_client.Client),
    captured: Int,
    saved: Int,
    capture_enabled: Bool,
    delivery: retrace_client.Status,
    filter: String,
    sessions: List(api.Summary),
    selected: String,
    inspector: Option(viewer.Inspector),
    loading: Bool,
    notice: String,
    playing: Bool,
    generation: Int,
  )
}

type Message {
  ClientReady(retrace_client.Client)
  Delivery(retrace_client.Status)
  Saved(Result(Nil, String))
  App(domain.Message)
  Navigate(Screen)
  Search(String)
  Refresh
  SessionsLoaded(String, Bool, String)
  Select(String)
  RecordingLoaded(String, Bool, String)
  Inspect(timetravel.Message(wire.Event))
  Play
  Tick(Int)
  Retry
}

fn init(_: Nil) -> #(Model, Effect(Message)) {
  let session =
    wire.Session(
      api.session_id(),
      api.user_ref(),
      domain.build,
      domain.contract,
      api.platform(),
    )
  let assert Ok(#(recorder, _)) =
    retrace.start(wire.origin(session), domain.initial())
  #(
    Model(
      LiveApp,
      domain.initial(),
      session,
      recorder,
      None,
      0,
      0,
      True,
      retrace_client.Status(0, 0, "Opening local recording storage"),
      "",
      [],
      "",
      None,
      False,
      "",
      False,
      0,
    ),
    effect.from(fn(dispatch) {
      let client =
        retrace_client.start(
          retrace_client.Config(
            api.endpoint(),
            "retrace-example",
            2000,
            8_388_608,
          ),
          fn(status) { dispatch(Delivery(status)) },
        )
      dispatch(ClientReady(client))
    }),
  )
}

fn refresh(model: Model) -> #(Model, Effect(Message)) {
  #(
    Model(..model, loading: True, notice: "Loading sessions"),
    effect.from(fn(dispatch) {
      api.fetch_sessions(model.filter, fn(ok, body) {
        dispatch(SessionsLoaded(model.filter, ok, body))
      })
    }),
  )
}

fn update(model: Model, message: Message) -> #(Model, Effect(Message)) {
  case message {
    ClientReady(client) -> #(
      Model(..model, client: Some(client)),
      effect.none(),
    )
    Delivery(status) -> #(Model(..model, delivery: status), effect.none())
    Saved(Ok(_)) -> #(Model(..model, saved: model.saved + 1), effect.none())
    Saved(Error(reason)) -> #(
      Model(
        ..model,
        capture_enabled: False,
        notice: reason <> ". Reload to begin a new recording.",
      ),
      effect.none(),
    )
    App(message) -> {
      let assert Ok(live) = domain.reduce(model.live, message)
      let command = case message {
        domain.RequestDevice ->
          effect.from(fn(dispatch) {
            api.device(fn(value) { dispatch(App(domain.DeviceReceived(value))) })
          })
        domain.Increment
        | domain.ToggleCompact
        | domain.NoChange
        | domain.DeviceReceived(_) -> effect.none()
      }
      case model.client, model.capture_enabled {
        Some(client), True -> {
          let checkpoint =
            retrace.checkpoint(model.recorder, domain.encode_model(model.live))
          case
            retrace.record(
              model.recorder,
              domain.encode_message(message),
              elapsed_ms: api.elapsed(),
            )
          {
            Error(_) -> #(
              Model(
                ..model,
                live: live,
                capture_enabled: False,
                notice: "Capture stopped: invalid recording time. Reload to start a new session.",
              ),
              command,
            )
            Ok(#(recorder, entry)) -> {
              let batch = wire.Batch(model.session, checkpoint, [entry])
              #(
                Model(
                  ..model,
                  live: live,
                  recorder: recorder,
                  captured: model.captured + 1,
                ),
                effect.batch([
                  effect.from(fn(dispatch) {
                    retrace_client.enqueue(client, batch, fn(result) {
                      dispatch(Saved(result))
                    })
                  }),
                  command,
                ]),
              )
            }
          }
        }
        _, _ -> #(Model(..model, live: live), command)
      }
    }
    Navigate(LiveApp) -> #(
      Model(
        ..model,
        screen: LiveApp,
        playing: False,
        generation: model.generation + 1,
      ),
      effect.none(),
    )
    Navigate(Sessions) -> refresh(Model(..model, screen: Sessions))
    Search(value) -> #(Model(..model, filter: value), effect.none())
    Refresh -> refresh(model)
    SessionsLoaded(filter, ok, body) ->
      case filter == model.filter {
        False -> #(model, effect.none())
        True ->
          case ok {
            False -> #(
              Model(..model, loading: False, notice: body),
              effect.none(),
            )
            True ->
              case api.summaries(body) {
                Error(reason) -> #(
                  Model(..model, loading: False, notice: reason),
                  effect.none(),
                )
                Ok(sessions) -> #(
                  Model(
                    ..model,
                    sessions: sessions,
                    loading: False,
                    notice: case sessions {
                      [] ->
                        "No sessions found. Record an interaction, then refresh."
                      _ -> "Select a session to replay"
                    },
                  ),
                  effect.none(),
                )
              }
          }
      }
    Select(id) -> #(
      Model(
        ..model,
        selected: id,
        inspector: None,
        loading: True,
        notice: "Loading recorded batches",
        playing: False,
        generation: model.generation + 1,
      ),
      effect.from(fn(dispatch) {
        api.fetch_recording(id, fn(ok, body) {
          dispatch(RecordingLoaded(id, ok, body))
        })
      }),
    )
    RecordingLoaded(id, ok, body) ->
      case id == model.selected {
        False -> #(model, effect.none())
        True -> {
          let loaded = case ok {
            False -> Error(body)
            True -> api.batches(body) |> result.try(viewer.load)
          }
          case loaded {
            Error(reason) -> #(
              Model(..model, loading: False, notice: reason),
              effect.none(),
            )
            Ok(inspector) -> #(
              Model(
                ..model,
                inspector: Some(inspector),
                loading: False,
                notice: "Loaded from durable storage. Playback runs no application effects.",
              ),
              effect.none(),
            )
          }
        }
      }
    Inspect(message) ->
      case model.inspector {
        None -> #(model, effect.none())
        Some(inspector) -> {
          let #(inspector, command) =
            timetravel.update(
              model: inspector,
              message: message,
              with: viewer.inert,
            )
          #(
            Model(
              ..model,
              inspector: Some(inspector),
              playing: False,
              generation: model.generation + 1,
            ),
            effect.map(command, Inspect),
          )
        }
      }
    Play ->
      case model.inspector {
        None -> #(model, effect.none())
        Some(inspector) -> {
          let #(selected, latest) = timetravel.position(inspector)
          let #(inspector, _) = case selected == latest {
            True ->
              timetravel.update(
                model: inspector,
                message: timetravel.GoTo(0),
                with: viewer.inert,
              )
            False -> #(inspector, effect.none())
          }
          let generation = model.generation + 1
          let playing = !model.playing
          #(
            Model(
              ..model,
              inspector: Some(inspector),
              playing: playing,
              generation: generation,
            ),
            case playing {
              True -> tick(generation)
              False -> effect.none()
            },
          )
        }
      }
    Tick(generation) ->
      case model.playing && generation == model.generation, model.inspector {
        True, Some(inspector) -> {
          let #(inspector, _) =
            timetravel.update(
              model: inspector,
              message: timetravel.Forward,
              with: viewer.inert,
            )
          let #(selected, latest) = timetravel.position(inspector)
          #(
            Model(
              ..model,
              inspector: Some(inspector),
              playing: selected < latest,
            ),
            case selected < latest {
              True -> tick(generation)
              False -> effect.none()
            },
          )
        }
        _, _ -> #(model, effect.none())
      }
    Retry -> #(
      model,
      effect.from(fn(_) {
        case model.client {
          Some(client) -> retrace_client.retry(client)
          None -> Nil
        }
      }),
    )
  }
}

fn tick(generation: Int) -> Effect(Message) {
  effect.from(fn(dispatch) { delay(fn() { dispatch(Tick(generation)) }) })
}

fn button(label: String, message: Message) -> Element(Message) {
  html.button([event.on_click(message)], [html.text(label)])
}

fn fact(label: String, value: String) -> Element(message) {
  html.div([attribute.class("fact")], [
    html.span([], [html.text(label)]),
    html.strong([], [html.text(value)]),
  ])
}

fn membership(card: domain.Model) -> Element(message) {
  html.div(
    [
      attribute.class("membership"),
      attribute.classes([#("compact", card.compact)]),
    ],
    [
      html.div([], [
        html.h2([], [html.text("Studio membership")]),
        html.p([], [html.text("Example loyalty card")]),
      ]),
      html.div([attribute.class("balance")], [
        html.strong([attribute.attribute("data-points", "")], [
          html.text(int.to_string(card.points)),
        ]),
        html.span([], [html.text("points")]),
      ]),
      html.div([attribute.class("card-footer")], [
        html.span([], [html.text("Member preview")]),
        html.span([], [html.text("RETRACE")]),
      ]),
    ],
  )
}

fn live_view(model: Model) -> Element(Message) {
  html.section([attribute.class("live-layout")], [
    html.div([attribute.class("phone")], [
      html.h1([], [html.text("Membership")]),
      html.p([attribute.class("subtitle")], [
        html.text("Every interaction can become a replay."),
      ]),
      membership(model.live),
      html.div([attribute.class("actions")], [
        button("Add a point", App(domain.Increment)),
        button("Change card layout", App(domain.ToggleCompact)),
        button("Read device information", App(domain.RequestDevice)),
        button("Record an unchanged state", App(domain.NoChange)),
      ]),
      html.p(
        [
          attribute.class("device-result"),
          attribute.attribute("aria-label", "Device result"),
        ],
        [html.text(model.live.device)],
      ),
    ]),
    html.aside([attribute.class("capture")], [
      html.h2([], [html.text("This recording")]),
      fact("User", model.session.user_ref),
      fact("Platform", model.session.platform),
      fact("Observed transitions", int.to_string(model.captured)),
      fact("Saved locally", int.to_string(model.saved)),
      fact("Queued batches", int.to_string(model.delivery.queued)),
      fact("Uploaded this run", int.to_string(model.delivery.acknowledged)),
      html.p([attribute.class("session-id")], [html.text(model.session.id)]),
      html.p(
        [attribute.attribute("role", "status"), attribute.class("delivery")],
        [html.text(model.delivery.detail)],
      ),
      button("Retry upload", Retry),
      button("Browse sessions", Navigate(Sessions)),
      html.p([attribute.class("hint")], [
        html.text(
          "The app remains live while you inspect a stored session. Only the membership state and selected events are recorded.",
        ),
      ]),
    ]),
  ])
}

fn replay_view(player: viewer.Player) -> Element(wire.Event) {
  let card = retrace.model(player)
  html.div([attribute.class("replay-card")], [
    fact("Recorded sequence", int.to_string(retrace.position(player))),
    membership(card),
    html.p([attribute.attribute("aria-label", "Recorded device result")], [
      html.text(card.device),
    ]),
  ])
}

fn sessions_view(model: Model) -> Element(Message) {
  html.section([], [
    html.h1([], [html.text("Sessions")]),
    html.p([attribute.class("subtitle")], [
      html.text("Find an interaction. Reconstruct what happened."),
    ]),
    html.form([attribute.class("search"), event.on_submit(fn(_) { Refresh })], [
      html.label([attribute.for("user-search")], [html.text("User reference")]),
      html.input([
        attribute.id("user-search"),
        attribute.value(model.filter),
        attribute.placeholder("All users"),
        event.on_input(Search),
      ]),
      html.button(
        [attribute.type_("submit"), attribute.disabled(model.loading)],
        [html.text("Refresh sessions")],
      ),
    ]),
    html.div([attribute.class("session-layout")], [
      html.div(
        [
          attribute.class("session-list"),
          attribute.attribute("aria-label", "Stored sessions"),
        ],
        list.map(model.sessions, fn(summary) {
          html.button(
            [
              attribute.class("session-row"),
              attribute.attribute(
                "aria-pressed",
                case summary.session.id == model.selected {
                  True -> "true"
                  False -> "false"
                },
              ),
              event.on_click(Select(summary.session.id)),
            ],
            [
              html.strong([], [
                html.text(
                  summary.session.user_ref <> " · " <> summary.session.platform,
                ),
              ]),
              html.span([], [
                html.text(
                  int.to_string(summary.sequence)
                  <> " events · "
                  <> int.to_string(summary.archived)
                  <> " archived",
                ),
              ]),
              html.small([], [html.text(summary.session.id)]),
            ],
          )
        }),
      ),
      html.div([attribute.class("viewer")], case model.inspector {
        None -> [
          html.div([attribute.class("empty")], [
            html.h2([], [html.text("Choose a recording")]),
            html.p([], [
              html.text(
                "The viewer reconstructs the membership app from saved events. It never calls the native device command.",
              ),
            ]),
          ]),
        ]
        Some(inspector) -> [
          html.div([attribute.class("playback")], [
            button("First", Inspect(timetravel.GoTo(0))),
            button("Previous", Inspect(timetravel.Back)),
            button(
              case model.playing {
                True -> "Pause"
                False -> "Play steps"
              },
              Play,
            ),
            button("Next", Inspect(timetravel.Forward)),
            button("Latest", Inspect(timetravel.ReturnToPresent)),
          ]),
          timetravel.view_with_formatters(
            model: inspector,
            app: replay_view,
            formatters: timetravel.Formatters(
              fn(event: wire.Event) { event.kind },
              fn(event) { event.payload },
              fn(player) { domain.encode_model(retrace.model(player)) },
            ),
          )
            |> element.map(Inspect),
          html.p([attribute.class("hint")], [
            html.text(
              "Step playback · newest 200 transitions retained in the inspector",
            ),
          ]),
        ]
      }),
    ]),
  ])
}

fn view(model: Model) -> Element(Message) {
  html.div([attribute.class("shell")], [
    html.nav(
      [
        attribute.class("navigation"),
        attribute.attribute("aria-label", "Main navigation"),
      ],
      [
        html.a([attribute.href("/"), attribute.class("brand")], [
          html.text("retrace"),
        ]),
        html.p([], [html.text("Session replay example")]),
        html.button(
          [
            attribute.attribute("aria-current", case model.screen {
              LiveApp -> "page"
              Sessions -> "false"
            }),
            event.on_click(Navigate(LiveApp)),
          ],
          [html.text("Live application")],
        ),
        html.button(
          [
            attribute.attribute("aria-current", case model.screen {
              Sessions -> "page"
              LiveApp -> "false"
            }),
            event.on_click(Navigate(Sessions)),
          ],
          [html.text("Sessions")],
        ),
        html.div([attribute.class("local-note")], [
          html.text("Local development"),
          html.small([], [html.text("Lustre + Tauri / Web")]),
        ]),
      ],
    ),
    html.main([], [
      case model.screen {
        LiveApp -> live_view(model)
        Sessions -> sessions_view(model)
      },
      html.p(
        [attribute.class("notice"), attribute.attribute("role", "status")],
        [html.text(model.notice)],
      ),
    ]),
  ])
}

pub fn main() -> Nil {
  let assert Ok(_) =
    lustre.application(init, update, view) |> lustre.start("#app", Nil)
  Nil
}

@external(javascript, "./example_ffi.mjs", "delay")
fn delay(callback: fn() -> Nil) -> Nil
