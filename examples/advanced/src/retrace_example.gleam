import gleam/int
import gleam/option.{None, Some}
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import retrace_client
import retrace_client/tauri
import retrace_example/api
import retrace_example/domain
import retrace_example/local_archive
import retrace_example/screen
import retrace_lustre/capture

type Model {
  Model(live: domain.Model, capture: capture.State, unobserve: fn() -> Nil)
}

type Message {
  Observing(fn() -> Nil)
  Recording(capture.Message)
  App(domain.Message)
  Resize(domain.Viewport)
  Retry
  Stop
}

fn init(_: Nil) -> #(Model, Effect(Message)) {
  let session =
    capture.session(
      api.user_ref(),
      api.build(),
      domain.contract,
      api.platform(),
    )
  let live = domain.Model(..domain.initial(), viewport: api.viewport())
  let assert Ok(#(recording, connect)) =
    capture.start(
      session,
      retrace_client.Config(api.endpoint(), "retrace-example", 2000, 8_388_608),
      case local_archive.selected(), api.platform() {
        True, _ -> local_archive.storage()
        False, "tauri" -> tauri.storage()
        False, _ -> retrace_client.browser_storage()
      },
      case local_archive.selected() {
        True -> local_archive.transport()
        False -> retrace_client.http_transport(api.endpoint())
      },
    )
  #(
    Model(live, recording, fn() { Nil }),
    effect.batch([
      effect.map(connect, Recording),
      effect.from(fn(dispatch) {
        dispatch(
          Observing(api.observe_viewport(fn(value) { dispatch(Resize(value)) })),
        )
      }),
    ]),
  )
}

fn update(model: Model, message: Message) -> #(Model, Effect(Message)) {
  case message {
    Observing(dispose) -> #(Model(..model, unobserve: dispose), effect.none())
    Recording(message) -> #(
      Model(..model, capture: capture.update(model.capture, message)),
      effect.none(),
    )
    Resize(viewport) ->
      case viewport != model.live.viewport {
        True -> update(model, App(domain.Resized(viewport)))
        False -> #(model, effect.none())
      }
    Retry -> #(model, capture.retry(model.capture) |> effect.map(Recording))
    Stop -> #(
      model,
      effect.batch([
        capture.stop(model.capture) |> effect.map(Recording),
        effect.from(fn(_) { model.unobserve() }),
      ]),
    )
    App(message) -> {
      let assert Ok(live) = domain.reduce(model.live, message)
      let #(recording, save) =
        capture.observe(
          model.capture,
          model.live,
          message,
          domain.encode_model,
          domain.encode_message,
        )
      let command = case message {
        domain.RequestDevice ->
          effect.from(fn(dispatch) {
            api.device(fn(value) { dispatch(App(domain.DeviceReceived(value))) })
          })
        domain.Increment
        | domain.ToggleCompact
        | domain.NoChange
        | domain.DeviceReceived(_)
        | domain.ShowDetails
        | domain.ShowCard
        | domain.Resized(_) -> effect.none()
      }
      #(
        Model(..model, live: live, capture: recording),
        effect.batch([effect.map(save, Recording), command]),
      )
    }
  }
}

fn view(model: Model) -> Element(Message) {
  let recording = capture.info(model.capture)
  html.div([attribute.class("live-root")], [
    screen.view(model.live) |> element.map(App),
    case recording.failure {
      None -> element.none()
      Some(reason) ->
        html.p([attribute.class("capture-error"), attribute.role("alert")], [
          html.text(reason),
        ])
    },
    html.details([attribute.class("capture-debug")], [
      html.summary([], [html.text("Recording status")]),
      html.p([attribute.class("session-id")], [html.text(recording.session.id)]),
      html.p([attribute.class("delivery")], [
        html.text(recording.delivery.detail),
      ]),
      html.p(
        [
          attribute.attribute("data-saved", int.to_string(recording.saved)),
          attribute.attribute(
            "data-queued",
            int.to_string(recording.delivery.queued),
          ),
        ],
        [
          html.text(
            "Saved "
            <> int.to_string(recording.saved)
            <> " · queued "
            <> int.to_string(recording.delivery.queued),
          ),
        ],
      ),
      html.button([event.on_click(Retry)], [html.text("Retry upload")]),
    ]),
  ])
}

pub fn main() -> fn() -> Nil {
  let assert Ok(runtime) =
    lustre.application(init, update, view) |> lustre.start("#app", Nil)
  fn() { lustre.send(runtime, lustre.dispatch(Stop)) }
}
