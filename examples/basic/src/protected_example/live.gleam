//// The live application owns private values, business validation and commands.
//// Historical entrypoints must never import this module.

import gleam/result
import gleam/string
import protected_example/observation
import protected_example/screen

pub type Model =
  screen.State(String)

pub type Message {
  Act(screen.Action)
  Checked(Result(Nil, Nil))
}

pub type Command {
  CheckLabel
}

pub fn initial() -> Model {
  screen.State("", screen.Unchecked, screen.Idle, False, False)
}

pub fn validate(value: String) -> screen.Validation {
  case string.length(string.trim(value)) >= 3 {
    True -> screen.Valid
    False -> screen.Invalid
  }
}

pub fn update(model: Model, message: Message) -> #(Model, List(Command)) {
  case message {
    Act(screen.ToggleLock) -> #(
      screen.State(..model, locked: !model.locked),
      [],
    )
    Act(screen.ToggleDetails) -> #(
      screen.State(..model, expanded: !model.expanded),
      [],
    )
    Act(_) if model.locked || model.progress == screen.Loading -> #(model, [])
    Act(screen.Edit(value)) -> #(
      screen.State(
        ..model,
        label: value,
        validation: screen.Unchecked,
        progress: screen.Idle,
      ),
      [],
    )
    Act(screen.Submit) -> {
      let validation = validate(model.label)
      case validation {
        screen.Valid -> #(
          screen.State(
            ..model,
            validation: validation,
            progress: screen.Loading,
          ),
          [CheckLabel],
        )
        screen.Invalid | screen.Unchecked -> #(
          screen.State(..model, validation: validation, progress: screen.Idle),
          [],
        )
      }
    }
    Checked(reply) if model.progress == screen.Loading -> #(
      screen.State(..model, progress: case reply {
        Ok(_) -> screen.Succeeded
        Error(_) -> screen.Unavailable
      }),
      [],
    )
    Checked(_) -> #(model, [])
  }
}

pub fn project(model: Model) -> Result(observation.Observation, Nil) {
  let safe =
    screen.State(
      case string.trim(model.label) == "" {
        True -> observation.Absent
        False -> observation.Present
      },
      model.validation,
      model.progress,
      model.locked,
      model.expanded,
    )
  // Reuse the observation invariant check at this application boundary.
  observation.check(safe)
  |> result.map_error(fn(_) { Nil })
}

pub fn transition(
  before: Model,
  after: Model,
) -> Result(#(observation.Observation, observation.Observation), Nil) {
  use before <- result.try(project(before))
  use after <- result.try(project(after))
  Ok(#(before, after))
}
