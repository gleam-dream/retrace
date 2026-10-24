//// Application-owned state and replay schema. Presentation is recorded explicitly.

import gleam/dynamic/decode
import gleam/json
import gleam/result
import retrace/wire

pub const contract = "membership-screen-v2"

pub type Viewport {
  Viewport(width: Int, height: Int, top: Int, bottom: Int)
}

pub type Model {
  Model(
    points: Int,
    compact: Bool,
    device: String,
    details: Bool,
    viewport: Viewport,
  )
}

pub type Message {
  Increment
  ToggleCompact
  NoChange
  RequestDevice
  DeviceReceived(String)
  ShowDetails
  ShowCard
  Resized(Viewport)
}

pub fn initial() -> Model {
  Model(0, False, "Not requested", False, Viewport(390, 844, 0, 0))
}

pub fn reduce(model: Model, message: Message) -> Result(Model, String) {
  Ok(case message {
    Increment -> Model(..model, points: model.points + 1)
    ToggleCompact -> Model(..model, compact: !model.compact)
    NoChange -> model
    RequestDevice -> Model(..model, device: "Requesting device information")
    DeviceReceived(value) -> Model(..model, device: value)
    ShowDetails -> Model(..model, details: True)
    ShowCard -> Model(..model, details: False)
    Resized(viewport) -> Model(..model, viewport: viewport)
  })
}

pub fn viewport_json(viewport: Viewport) -> json.Json {
  json.object([
    #("width", json.int(viewport.width)),
    #("height", json.int(viewport.height)),
    #("top", json.int(viewport.top)),
    #("bottom", json.int(viewport.bottom)),
  ])
}

fn viewport_decoder() -> decode.Decoder(Viewport) {
  use width <- decode.field("width", decode.int)
  use height <- decode.field("height", decode.int)
  use top <- decode.field("top", decode.int)
  use bottom <- decode.field("bottom", decode.int)
  case
    width > 0
    && width <= 8192
    && height > 0
    && height <= 8192
    && top >= 0
    && bottom >= 0
    && top + bottom < height
  {
    True -> decode.success(Viewport(width, height, top, bottom))
    False -> decode.failure(Viewport(390, 844, 0, 0), "valid viewport")
  }
}

pub fn decode_viewport(input: String) -> Result(Viewport, String) {
  json.parse(input, viewport_decoder())
  |> result.map_error(fn(_) { "Invalid viewport" })
}

pub fn encode_model(model: Model) -> String {
  json.object([
    #("points", json.int(model.points)),
    #("compact", json.bool(model.compact)),
    #("device", json.string(model.device)),
    #("details", json.bool(model.details)),
    #("viewport", viewport_json(model.viewport)),
  ])
  |> json.to_string
}

pub fn decode_model(input: String) -> Result(Model, String) {
  let decoder = {
    use points <- decode.field("points", decode.int)
    use compact <- decode.field("compact", decode.bool)
    use device <- decode.field("device", decode.string)
    use details <- decode.field("details", decode.bool)
    use viewport <- decode.field("viewport", viewport_decoder())
    case points >= 0 {
      True -> decode.success(Model(points, compact, device, details, viewport))
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
    ShowDetails -> wire.Event("ShowDetails", "")
    ShowCard -> wire.Event("ShowCard", "")
    Resized(viewport) ->
      wire.Event("Resized", viewport_json(viewport) |> json.to_string)
  }
}

pub fn decode_message(event: wire.Event) -> Result(Message, String) {
  case event.kind {
    "Increment" -> Ok(Increment)
    "ToggleCompact" -> Ok(ToggleCompact)
    "NoChange" -> Ok(NoChange)
    "RequestDevice" -> Ok(RequestDevice)
    "DeviceReceived" -> Ok(DeviceReceived(event.payload))
    "ShowDetails" -> Ok(ShowDetails)
    "ShowCard" -> Ok(ShowCard)
    "Resized" -> decode_viewport(event.payload) |> result.map(Resized)
    _ -> Error("Unknown membership event")
  }
}
