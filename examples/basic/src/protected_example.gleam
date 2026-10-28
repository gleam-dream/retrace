import gleam/list
import gleam/option.{None, Some}
import lustre
import lustre/attribute as a
import lustre/effect
import lustre/element
import lustre/element/html as h
import protected_example/live
import protected_example/observation
import protected_example/screen
import retrace_frontend/capture
import retrace_frontend/client

type Model {
  Model(application: live.Model, recording: capture.State)
}

type Message {
  Application(live.Message)
  Recording(capture.Message)
  Stop
}

fn init(_: Nil) -> #(Model, effect.Effect(Message)) {
  let session =
    capture.session(
      "Protected demo",
      observation.build,
      observation.contract,
      "web",
    )
  let assert Ok(#(recording, connect)) =
    capture.start(
      session,
      client.Config("http://127.0.0.1:4417", "protected-outbox", 100, 1_048_576),
      client.browser_storage(),
      client.http_transport("http://127.0.0.1:4417"),
    )
  #(Model(live.initial(), recording), effect.map(connect, Recording))
}

fn update(model: Model, message: Message) -> #(Model, effect.Effect(Message)) {
  case message {
    Recording(message) -> #(
      Model(..model, recording: capture.update(model.recording, message)),
      effect.none(),
    )
    Stop -> #(model, capture.stop(model.recording) |> effect.map(Recording))
    Application(message) -> {
      let #(after, commands) = live.update(model.application, message)
      // The only recording boundary. Encoders cannot receive the live model or
      // message. A failed projection stops capture; the live update proceeds.
      // snips-start: protected-capture
      let #(recording, save) =
        capture.observe_projected(
          model.recording,
          live.transition(model.application, after),
          observation.encode,
          observation.encode_event,
        )
      // snips-end: protected-capture
      #(
        Model(after, recording),
        effect.batch([
          effect.map(save, Recording),
          ..list.map(commands, interpret)
        ]),
      )
    }
  }
}

// This live-only interpreter fetches a static result to demonstrate an external
// decision. It sends no label and persists no private draft or recording sidecar.
fn interpret(command: live.Command) -> effect.Effect(Message) {
  case command {
    live.CheckLabel ->
      effect.from(fn(dispatch) {
        check_label(fn(reply) { dispatch(Application(live.Checked(reply))) })
      })
  }
}

fn view(model: Model) -> element.Element(Message) {
  let info = capture.info(model.recording)
  h.div([], [
    screen.view(model.application, fn(value) { value })
      |> element.map(fn(action) { Application(live.Act(action)) }),
    h.footer([], [
      h.p([], [
        h.text(
          "Enter x and check: invalid. Replay shows Protected content with the same invalid decision.",
        ),
      ]),
      h.p([a.role("status"), a.aria_label("Recording delivery")], [
        h.text(case info.failure {
          Some(reason) -> reason
          None -> info.delivery.detail
        }),
      ]),
      h.a(
        [
          a.href(
            "/protected-viewer.html?user=Protected%20demo&session="
            <> info.session.id,
          ),
        ],
        [h.text("Inspect protected recording")],
      ),
    ]),
  ])
}

pub fn main() -> fn() -> Nil {
  let assert Ok(runtime) =
    lustre.application(init, update, view) |> lustre.start("#app", Nil)
  fn() { lustre.send(runtime, lustre.dispatch(Stop)) }
}

@external(javascript, "./protected_live_ffi.mjs", "checkLabel")
fn check_label(reply: fn(Result(Nil, Nil)) -> Nil) -> Nil
