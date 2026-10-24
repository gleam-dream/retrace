import retrace_example/domain
import retrace_example/screen
import retrace_frontend/replay

pub fn module() -> replay.ReplayModule(domain.Model, domain.Message, String) {
  replay.ReplayModule(
    contract: domain.contract,
    decode_model: domain.decode_model,
    decode_event: domain.decode_message,
    reduce: domain.reduce,
    equal: fn(a, b) { a == b },
    view: screen.view,
    viewport: fn(model) {
      replay.Viewport(model.viewport.width, model.viewport.height)
    },
    label: fn(event) {
      case event.kind {
        "Increment" -> "Added a point"
        "ToggleCompact" -> "Changed card layout"
        "NoChange" -> "Recorded unchanged state"
        "RequestDevice" -> "Requested device information"
        "DeviceReceived" -> "Received device information"
        "ShowDetails" -> "Opened card details"
        "ShowCard" -> "Returned to card"
        "Resized" -> "Viewport changed"
        _ -> event.kind
      }
    },
  )
}
