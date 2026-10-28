//// One application view for live values and protected observations.
//// These are example application decisions, not Retrace vocabulary.

import lustre/attribute as a
import lustre/element.{type Element}
import lustre/element/html as h
import lustre/event

pub type Validation {
  Unchecked
  Invalid
  Valid
}

pub type Progress {
  Idle
  Loading
  Succeeded
  Unavailable
}

pub type State(field) {
  State(
    label: field,
    validation: Validation,
    progress: Progress,
    locked: Bool,
    expanded: Bool,
  )
}

pub type Action {
  Edit(String)
  Submit
  ToggleLock
  ToggleDetails
}

pub fn view(
  state: State(field),
  display: fn(field) -> String,
) -> Element(Action) {
  h.main([a.class("inventory")], [
    h.h1([], [h.text("Protected label check")]),
    h.label([], [
      h.span([], [h.text("Private label")]),
      h.input([
        a.value(display(state.label)),
        a.disabled(state.locked || state.progress == Loading),
        a.aria_invalid(case state.validation {
          Invalid -> "true"
          Unchecked | Valid -> "false"
        }),
        event.on_input(Edit),
      ]),
    ]),
    h.p([a.role("status"), a.aria_label("Validation")], [
      h.text(case state.validation {
        Unchecked -> "Not checked"
        Invalid -> "Use at least 3 characters"
        Valid -> "Valid label"
      }),
    ]),
    h.p([a.role("status"), a.aria_label("Outcome")], [
      h.text(case state.progress {
        Idle -> "Ready"
        Loading -> "Checking…"
        Succeeded -> "Check confirmed"
        Unavailable -> "Check unavailable"
      }),
    ]),
    h.nav([a.aria_label("Label actions")], [
      h.button(
        [
          a.disabled(state.locked || state.progress == Loading),
          event.on_click(Submit),
        ],
        [h.text("Check label")],
      ),
      h.button([event.on_click(ToggleLock)], [
        h.text(case state.locked {
          True -> "Unlock"
          False -> "Lock"
        }),
      ]),
      h.button(
        [
          a.aria_expanded(state.expanded),
          event.on_click(ToggleDetails),
        ],
        [h.text("Details")],
      ),
    ]),
    case state.expanded {
      True -> h.p([], [h.text("A label needs at least 3 characters.")])
      False -> h.text("")
    },
  ])
}
