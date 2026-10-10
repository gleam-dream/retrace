//// One application-owned replay contract used by both the live app and viewer.

import gleam/dynamic/decode
import gleam/json
import gleam/result
import retrace/wire

pub const contract = "membership-v1"

pub const build = "membership-v1"

pub type Model {
  Model(points: Int, compact: Bool, device: String)
}

pub type Message {
  Increment
  ToggleCompact
  NoChange
  RequestDevice
  DeviceReceived(String)
}

pub fn initial() -> Model {
  Model(0, False, "Not requested")
}

pub fn reduce(model: Model, message: Message) -> Result(Model, String) {
  Ok(case message {
    Increment -> Model(..model, points: model.points + 1)
    ToggleCompact -> Model(..model, compact: !model.compact)
    NoChange -> model
    RequestDevice -> Model(..model, device: "Requesting device information")
    DeviceReceived(value) -> Model(..model, device: value)
  })
}

pub fn encode_model(model: Model) -> String {
  json.object([
    #("points", json.int(model.points)),
    #("compact", json.bool(model.compact)),
    #("device", json.string(model.device)),
  ])
  |> json.to_string
}

pub fn decode_model(input: String) -> Result(Model, String) {
  let decoder = {
    use points <- decode.field("points", decode.int)
    use compact <- decode.field("compact", decode.bool)
    use device <- decode.field("device", decode.string)
    case points >= 0 {
      True -> decode.success(Model(points, compact, device))
      False -> decode.failure(initial(), "nonnegative points")
    }
  }
  json.parse(input, decoder)
  |> result.map_error(fn(_) { "Unsupported membership state" })
}

pub fn encode_message(message: Message) -> wire.Event {
  case message {
    Increment -> wire.Event("Increment", "")
    ToggleCompact -> wire.Event("ToggleCompact", "")
    NoChange -> wire.Event("NoChange", "")
    RequestDevice -> wire.Event("RequestDevice", "")
    DeviceReceived(value) -> wire.Event("DeviceReceived", value)
  }
}

pub fn decode_message(event: wire.Event) -> Result(Message, String) {
  case event.kind {
    "Increment" -> Ok(Increment)
    "ToggleCompact" -> Ok(ToggleCompact)
    "NoChange" -> Ok(NoChange)
    "RequestDevice" -> Ok(RequestDevice)
    "DeviceReceived" -> Ok(DeviceReceived(event.payload))
    _ -> Error("Unknown membership event")
  }
}
