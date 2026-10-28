//// Safe recording schema. No constructor can hold the original label or a
//// backend response. The application still owns classification and projection.
//// This module and screen are shared with the historical artifact; live is not.

import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/result
import lustre/element
import protected_example/screen
import retrace/wire
import retrace_frontend/replay

pub const contract = "protected-label-v1"

// Mutable development identity only. Preserve a unique live/frame pairing for
// production using the advanced example's immutable artifact recipe.
pub const build = "protected-label-v1-dev"

pub type Presence {
  Absent
  Present
}

pub type Observation =
  screen.State(Presence)

pub fn display(presence: Presence) -> String {
  case presence {
    Absent -> ""
    Present -> "Protected content"
  }
}

pub fn encode(state: Observation) -> String {
  json.object([
    #("version", json.int(1)),
    #("present", json.bool(state.label == Present)),
    #(
      "validation",
      json.string(case state.validation {
        screen.Unchecked -> "unchecked"
        screen.Invalid -> "invalid"
        screen.Valid -> "valid"
      }),
    ),
    #(
      "progress",
      json.string(case state.progress {
        screen.Idle -> "idle"
        screen.Loading -> "loading"
        screen.Succeeded -> "succeeded"
        screen.Unavailable -> "unavailable"
      }),
    ),
    #("locked", json.bool(state.locked)),
    #("expanded", json.bool(state.expanded)),
  ])
  |> json.to_string
}

pub fn decode_observation(input: String) -> Result(Observation, String) {
  let decoder = {
    use fields <- decode.then(decode.dict(decode.string, decode.dynamic))
    use version <- decode.field("version", decode.int)
    use present <- decode.field("present", decode.bool)
    use validation <- decode.field("validation", decode.string)
    use progress <- decode.field("progress", decode.string)
    use locked <- decode.field("locked", decode.bool)
    use expanded <- decode.field("expanded", decode.bool)
    let validation = case validation {
      "unchecked" -> Ok(screen.Unchecked)
      "invalid" -> Ok(screen.Invalid)
      "valid" -> Ok(screen.Valid)
      _ -> Error(Nil)
    }
    let progress = case progress {
      "idle" -> Ok(screen.Idle)
      "loading" -> Ok(screen.Loading)
      "succeeded" -> Ok(screen.Succeeded)
      "unavailable" -> Ok(screen.Unavailable)
      _ -> Error(Nil)
    }
    case version, dict.size(fields), validation, progress {
      1, 6, Ok(validation), Ok(progress) -> {
        let state =
          screen.State(
            case present {
              True -> Present
              False -> Absent
            },
            validation,
            progress,
            locked,
            expanded,
          )
        case check(state) {
          Ok(state) -> decode.success(state)
          Error(_) ->
            decode.failure(initial(), "consistent protected decisions")
        }
      }
      _, _, _, _ -> decode.failure(initial(), "valid protected observation")
    }
  }
  json.parse(input, decoder)
  |> result.map_error(fn(_) { "Invalid protected observation" })
}

/// Validate observation consistency, never the displayed placeholder as input.
/// Constructed values and decoded values follow the same application rules.
pub fn check(state: Observation) -> Result(Observation, String) {
  case state.validation, state.progress, state.label {
    screen.Valid, _, Present -> Ok(state)
    screen.Unchecked, screen.Idle, _ | screen.Invalid, screen.Idle, _ ->
      Ok(state)
    _, _, _ -> Error("Inconsistent protected decisions")
  }
}

pub fn initial() -> Observation {
  screen.State(Absent, screen.Unchecked, screen.Idle, False, False)
}

pub fn encode_event(after: Observation) -> wire.Event {
  wire.Event("observed", encode(after))
}

pub fn decode_event(event: wire.Event) -> Result(Observation, String) {
  case event.kind {
    "observed" -> decode_observation(event.payload)
    _ -> Error("Unknown protected event")
  }
}

// Adopt recorded decisions. Never interpret display(presence) as business input.
pub fn adopt(
  _before: Observation,
  after: Observation,
) -> Result(Observation, String) {
  check(after)
}

pub fn replay_module() -> replay.ReplayModule(Observation, Observation, String) {
  replay.ReplayModule(
    contract: contract,
    decode_model: decode_observation,
    decode_event: decode_event,
    reduce: adopt,
    equal: fn(a, b) { a == b },
    view: fn(state) {
      screen.view(state, display)
      |> element.map(fn(_) { state })
    },
    viewport: fn(_) { replay.Viewport(900, 600) },
    label: fn(_) { "Protected observation" },
  )
}
