//// The complete application surface, shared by the live and historical builds.

import gleam/int
import lustre/attribute as attr
import lustre/element.{type Element}
import lustre/element/html as h
import lustre/event
import retrace_example/domain as d

pub fn view(model: d.Model) -> Element(d.Message) {
  h.main(
    [
      attr.class("membership"),
      attr.style("padding-top", int.to_string(model.viewport.top) <> "px"),
      attr.style("padding-bottom", int.to_string(model.viewport.bottom) <> "px"),
    ],
    [
      h.header([attr.class("app-header")], [
        h.span([], [h.text("Membership")]),
        h.span([attr.class("member-name")], [h.text("Your everyday rewards")]),
      ]),
      h.div([attr.class("app-content")], case model.details {
        True -> [
          h.h1([], [h.text("Card details")]),
          h.p([attr.class("intro")], [h.text("Your membership, at a glance.")]),
          h.dl([attr.class("details")], [
            h.dt([], [h.text("Balance")]),
            h.dd([], [h.text(int.to_string(model.points) <> " points")]),
            h.dt([], [h.text("Membership")]),
            h.dd([], [h.text("Everyday")]),
            h.dt([], [h.text("Device information")]),
            h.dd([attr.attribute("aria-label", "Device result")], [
              h.text(model.device),
            ]),
          ]),
          action("Back to card", d.ShowCard, "primary"),
        ]
        False -> [
          h.h1([], [h.text("A little more rewarding.")]),
          h.p([attr.class("intro")], [
            h.text("Collect points. Make the everyday count."),
          ]),
          h.section(
            [
              attr.class(case model.compact {
                True -> "member-card compact"
                False -> "member-card"
              }),
              attr.attribute("aria-label", "Membership card"),
            ],
            [
              h.span([], [h.text("Everyday / Member")]),
              h.div([attr.class("balance")], [
                h.strong([attr.attribute("data-points", "")], [
                  h.text(int.to_string(model.points)),
                ]),
                h.span([], [h.text("points")]),
              ]),
            ],
          ),
          h.div([attr.class("actions")], [
            action("Add a point", d.Increment, "primary"),
            action("Change card layout", d.ToggleCompact, "secondary"),
            action("Read device information", d.RequestDevice, "secondary"),
            action("Record an unchanged state", d.NoChange, "quiet"),
          ]),
          h.p(
            [
              attr.class("device"),
              attr.attribute("aria-label", "Device result"),
              attr.attribute("aria-live", "polite"),
            ],
            [h.text(model.device)],
          ),
        ]
      }),
      h.nav(
        [
          attr.class("app-tabs"),
          attr.attribute("aria-label", "Membership navigation"),
        ],
        [
          tab("My card", d.ShowCard, !model.details),
          tab("Details", d.ShowDetails, model.details),
        ],
      ),
    ],
  )
}

fn action(
  label: String,
  message: d.Message,
  class: String,
) -> Element(d.Message) {
  h.button([attr.class(class), event.on_click(message)], [h.text(label)])
}

fn tab(label: String, message: d.Message, active: Bool) -> Element(d.Message) {
  h.button(
    [
      event.on_click(message),
      attr.attribute("aria-pressed", case active {
        True -> "true"
        False -> "false"
      }),
    ],
    [h.text(label)],
  )
}
