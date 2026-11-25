import gleam/option.{None, Some}
import gleam/string
import lustre
import lustre/attribute
import lustre/effect
import lustre/element
import lustre/element/html
import retrace/wire
import retrace_frontend/capture
import retrace_frontend/client
import retrace_inventory/domain

type Model {
  Model(stock: domain.Stock, capture: capture.State, notice: String)
}

type Message {
  Change(domain.Command)
  Recording(capture.Message)
  Stop
}

fn init(_: Nil) -> #(Model, effect.Effect(Message)) {
  // snips-start: capture-start
  // The collector chooses the session id when it opens the session.
  let metadata =
    wire.Metadata("Warehouse", domain.build, domain.contract, "web")
  let assert Ok(#(recording, connect)) =
    capture.start(
      metadata,
      client.Config("http://127.0.0.1:4417", "basic-outbox", 100, 1_048_576),
      client.browser_storage(),
      client.http_transport("http://127.0.0.1:4417"),
    )
  // snips-end: capture-start
  #(
    Model(domain.initial(), recording, "Opening local storage"),
    effect.map(connect, Recording),
  )
}

fn update(model: Model, message: Message) -> #(Model, effect.Effect(Message)) {
  case message {
    Recording(message) -> {
      let recording = capture.update(model.capture, message)
      let info = capture.info(recording)
      let notice = case info.failure {
        Some(reason) -> reason
        None -> info.delivery.detail
      }
      #(Model(..model, capture: recording, notice: notice), effect.none())
    }
    Stop -> #(model, capture.stop(model.capture) |> effect.map(Recording))
    Change(command) ->
      case domain.reduce(model.stock, command) {
        Error(reason) -> #(
          Model(..model, notice: string.inspect(reason)),
          effect.none(),
        )
        Ok(stock) -> {
          // snips-start: capture-observe
          let #(recording, save) =
            capture.observe(
              model.capture,
              model.stock,
              command,
              domain.encode,
              domain.encode_command,
            )
          // snips-end: capture-observe
          let notice = case capture.info(recording).failure {
            Some(reason) -> reason
            None -> model.notice
          }
          #(Model(stock, recording, notice), effect.map(save, Recording))
        }
      }
  }
}

fn view(model: Model) -> element.Element(Message) {
  html.div([], [
    domain.view(model.stock) |> element.map(Change),
    html.footer([], [
      html.p(
        [
          attribute.role("status"),
          attribute.attribute("aria-label", "Recording delivery"),
        ],
        [html.text(model.notice)],
      ),
      html.a(
        [
          attribute.href(
            "/viewer.html?user=Warehouse&session=" <> session_id(model.capture),
          ),
        ],
        [
          html.text("Inspect this recording"),
        ],
      ),
    ]),
  ])
}

fn session_id(recording: capture.State) -> String {
  case capture.info(recording).session {
    Some(session) -> session.id
    None -> ""
  }
}

pub fn main() -> fn() -> Nil {
  let assert Ok(runtime) =
    lustre.application(init, update, view) |> lustre.start("#app", Nil)
  fn() { lustre.send(runtime, lustre.dispatch(Stop)) }
}
