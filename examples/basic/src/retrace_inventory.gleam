import gleam/option.{None, Some}
import gleam/string
import lustre
import lustre/attribute
import lustre/effect
import lustre/element
import lustre/element/html
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
  let session =
    capture.session("Warehouse", domain.build, domain.contract, "web")
  let assert Ok(#(recording, connect)) =
    capture.start(
      session,
      client.Config("http://127.0.0.1:4417", "basic-outbox", 100, 1_048_576),
      client.browser_storage(),
      client.http_transport("http://127.0.0.1:4417"),
    )
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
          let #(recording, save) =
            capture.observe(
              model.capture,
              model.stock,
              command,
              domain.encode,
              domain.encode_command,
            )
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
            "/viewer.html?user=Warehouse&session="
            <> capture.info(model.capture).session.id,
          ),
        ],
        [
          html.text("Inspect this recording"),
        ],
      ),
    ]),
  ])
}

pub fn main() -> fn() -> Nil {
  let assert Ok(runtime) =
    lustre.application(init, update, view) |> lustre.start("#app", Nil)
  fn() { lustre.send(runtime, lustre.dispatch(Stop)) }
}
