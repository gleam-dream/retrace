---
name: Retrace examples
description: Quiet native-style membership app and independent session viewer.
colors:
  primary: "#174d3c"
  app-canvas: "#f5f6f2"
  viewer-canvas: "#f7f8f5"
  panel: "#ffffff"
  stage: "#edf0e9"
  app-ink: "#152820"
  viewer-ink: "#202e28"
  app-muted: "#59695f"
  secondary: "#e6ebe5"
  secondary-ink: "#203e30"
  quiet-ink: "#52685b"
  tab-selected: "#e3ebe4"
  session-selected: "#eaf1e9"
  event-selected: "#e9f1e8"
  viewer-border: "#dfe5de"
  app-focus: "#39866d"
  viewer-focus: "#4f8c70"
typography:
  body:
    fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif'
  app-heading:
    fontSize: "27px"
    fontWeight: 650
    lineHeight: 1.15
    letterSpacing: "-0.025em"
  app-intro:
    fontSize: "14px"
    lineHeight: 1.5
  balance:
    fontSize: "64px"
    fontWeight: 500
    lineHeight: 1
    letterSpacing: "-0.04em"
  session-title:
    fontSize: "19px"
    fontWeight: 600
  identifier:
    fontFamily: "ui-monospace, monospace"
    fontSize: "10px"
rounded:
  viewer-control: "8px"
  app-tab: "10px"
  app-control: "12px"
  member-card: "16px"
components:
  app-button-primary:
    backgroundColor: "{colors.primary}"
    textColor: "{colors.panel}"
    rounded: "{rounded.app-control}"
    padding: "12px 15px"
  app-button-secondary:
    backgroundColor: "{colors.secondary}"
    textColor: "{colors.secondary-ink}"
    rounded: "{rounded.app-control}"
    padding: "12px 15px"
  app-button-quiet:
    backgroundColor: "transparent"
    textColor: "{colors.quiet-ink}"
    rounded: "{rounded.app-control}"
    padding: "12px 15px"
---

# Design System: Retrace examples

## Overview

The membership app and independent session viewer use a quiet near-white canvas,
dark green ink, restrained green emphasis, and platform sans-serif text. The app
feels like a small native application; the viewer is a denser inspection workspace.
Content and explicit controls establish hierarchy.

This record describes the implemented example surfaces in `examples/advanced` and
`examples/advanced/viewer`. The app's complete header, content, and bottom navigation are
shared by live and historical builds through
`examples/advanced/src/retrace_example/screen.gleam`. The viewer is served independently
and surrounds the recorded application with session selection and playback tools.

## Colors

Deep green (`primary`) anchors the membership card, primary app action, viewer
play button, and timeline position. Pale green fills distinguish secondary
controls and selected tabs, sessions, and events. Near-white panels sit against a
slightly darker replay stage. Dark ink carries primary content; muted green-gray
supports explanatory text and metadata.

Use the surface-specific ink and focus tokens. The viewer has separate neutral
values for dense metadata; its full implemented palette lives in
`packages/retrace_frontend/src/style.mjs`. The app palette lives in `examples/advanced/style.css`.

## Typography

Use the platform font stack across both surfaces. The app gives the balance the
largest type and uses compact headings and short explanatory copy. Balance values,
playback clocks, event times, and viewport dimensions use tabular numerals.
Session-list identifiers use the small monospace role.

The app heading reduces to 24px in windows at most 740px high. The compact card
reduces its balance to 44px. The viewer uses a 22px product title, an 18px sessions
heading, and predominantly 12–14px control and event text. Long identifiers wrap
within their panels.

## Layout

### Membership app

The app fills the available viewport with a header, independently scrollable
content, and bottom tabs for My card and Details. The content column has a maximum
width of 560px, centered with 26px horizontal padding. Recorded top and bottom
insets are applied to the complete screen. Header and tabs remain outside the
content scroller.

At a viewport height of 740px or less, horizontal content padding reduces to 22px,
vertical gaps tighten, and the standard membership card becomes shorter. The
bottom tabs remain the app's navigation on both wide and narrow windows.

### Session viewer

A 64px top bar sits above a desktop workspace. Sessions occupy a 240px left rail;
the recorded viewport is centered in the main stage; events occupy a 280px right
rail. The transport and timeline sit below the stage and events. Session and event
lists scroll independently.

At widths of 1100px or less, the rails narrow to 200px and 220px. At 800px or less,
sessions move above the workspace with a horizontally scrollable session list.
At 540px or less, the stage and events stack vertically; the stage is 600px high,
the event list is bounded to 210px, and transport controls wrap. The page scrolls
through this stack, with the timeline after the events.

The historical iframe keeps the selected event's recorded CSS viewport dimensions.
The viewer scales that frame externally to fit the available stage, with a label
showing recorded dimensions, scale, and viewport category. Resizing the viewer
changes the presentation scale; it does not reflow the application to the viewer's
width.

## Elevation & Depth

Thin borders and pale tonal changes separate headers, lists, navigation, and
transport. The membership card is flat. The recorded viewport has a dark frame
and a soft shadow (`0 14px 28px #21382020`) to distinguish it from the surrounding
viewer. Optional open capture diagnostics use a smaller shadow
(`0 8px 24px #17271b18`).

## Shapes

App controls and the membership card have softly rounded corners; viewer controls
use the tighter radius defined above. Event rows form a continuous divided list.
The recorded frame has an 8px border and a 28px radius for viewports narrower than
700px, otherwise an 8px radius. This is viewer framing, not a reproduction of
operating-system chrome.

## Components

### App controls and navigation

App buttons span the content column and have a minimum height of 44px. Primary,
secondary, and quiet treatments communicate emphasis. Hover and active states
slightly darken the control; disabled controls reduce opacity. Focus uses a visible
3px outline with a 3px offset. The selected bottom tab combines pale green fill,
darker text, heavier weight, and `aria-pressed` state.

The card supports tall and compact presentations. Device information occupies a
stable text region below the actions and is announced politely when it changes.
Details replace the card content while retaining the same header and bottom tabs.

Capture diagnostics are hidden by default. Adding `?diagnostics` to the app URL
reveals a collapsible Recording status control above the bottom navigation.
Capture errors use a separate alert near the top of the app.

### Session search and selection

The viewer provides a labeled User reference field and Find action. Search status
sits between the form and results. A selected session gains a pale fill and border;
its row includes user reference, platform/event summary, and wrapped identifier.
The workspace heading shows the selected recording identity and a Reload recording
action. Viewer buttons generally have a 40px minimum height and a visible 3px focus
outline; timeline markers use smaller dedicated targets.

### Recorded viewport and playback

The recorded application is passive. Interaction belongs to the viewer's event
list, markers, scrubber, Previous/Next controls, Play/Pause button, and speed
selector. Selection tint marks the reconstructed event position. Previous/Next
move between distinct event times; events with the same elapsed time reconstruct
together. Nearby timeline markers can cluster with a count.

Playback preserves recorded gaps and ends at the last loaded event. The range
caption explicitly says that the session end is unknown. Empty, loading, and
playback-error messages occupy the stage; failures disable playback controls.
Historical application animations and transitions are disabled.

## Do's and Don'ts

- Do preserve the whole application screen in live and historical views.
- Do keep app navigation and viewer controls in their respective surfaces.
- Do retain recorded viewport dimensions and show the external presentation scale.
- Do use explicit labels, visible focus, selected states, and scrollable content.
- Do keep capture diagnostics optional and recorded application controls passive.
- Don't present the experimental viewer package as a stable published API.
- Don't claim native operating-system pixel fidelity from a browser reconstruction.
- Don't replace real application content with promotional sections or invented metrics.
