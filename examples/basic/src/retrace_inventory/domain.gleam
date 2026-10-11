import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/result
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import retrace/wire
import retrace_lustre

pub const contract = "inventory-v1"

pub const build = "inventory-v1-dev"

pub type Stock {
  Stock(on_hand: Int, reserved: Int)
}

pub type Command {
  Receive
  Reserve
  Release
}

pub type Refusal {
  InsufficientStock
  NothingReserved
}

pub fn initial() -> Stock {
  Stock(4, 0)
}

pub fn reduce(stock: Stock, command: Command) -> Result(Stock, Refusal) {
  case command {
    Receive -> Ok(Stock(..stock, on_hand: stock.on_hand + 1))
    Reserve ->
      case stock.on_hand > stock.reserved {
        True -> Ok(Stock(..stock, reserved: stock.reserved + 1))
        False -> Error(InsufficientStock)
      }
    Release ->
      case stock.reserved > 0 {
        True -> Ok(Stock(..stock, reserved: stock.reserved - 1))
        False -> Error(NothingReserved)
      }
  }
}

pub fn encode(stock: Stock) -> String {
  json.object([
    #("on_hand", json.int(stock.on_hand)),
    #("reserved", json.int(stock.reserved)),
  ])
  |> json.to_string
}

pub fn decode_stock(input: String) -> Result(Stock, String) {
  let decoder = {
    use on_hand <- decode.field("on_hand", decode.int)
    use reserved <- decode.field("reserved", decode.int)
    case on_hand >= 0 && reserved >= 0 && reserved <= on_hand {
      True -> decode.success(Stock(on_hand, reserved))
      False -> decode.failure(initial(), "valid stock quantities")
    }
  }
  json.parse(input, decoder)
  |> result.map_error(fn(_) { "Invalid inventory checkpoint" })
}

pub fn encode_command(command: Command) -> wire.Event {
  wire.Event(
    case command {
      Receive -> "receive"
      Reserve -> "reserve"
      Release -> "release"
    },
    "",
  )
}

pub fn decode_command(event: wire.Event) -> Result(Command, String) {
  case event.kind {
    "receive" -> Ok(Receive)
    "reserve" -> Ok(Reserve)
    "release" -> Ok(Release)
    _ -> Error("Unknown inventory command")
  }
}

pub fn view(stock: Stock) -> Element(Command) {
  html.main([attribute.class("inventory")], [
    html.header([], [
      html.p([], [html.text("WAREHOUSE / BIN A12")]),
      html.h1([], [html.text("Field notebooks")]),
    ]),
    html.section(
      [
        attribute.class("quantities"),
        attribute.attribute("aria-label", "Stock levels"),
      ],
      [
        html.div([], [
          html.h2([], [html.text("On hand")]),
          html.output([attribute.attribute("aria-label", "On hand")], [
            html.text(int.to_string(stock.on_hand)),
          ]),
        ]),
        html.div([], [
          html.h2([], [html.text("Reserved")]),
          html.output([attribute.attribute("aria-label", "Reserved")], [
            html.text(int.to_string(stock.reserved)),
          ]),
        ]),
        html.div([], [
          html.h2([], [html.text("Available")]),
          html.output([attribute.attribute("aria-label", "Available")], [
            html.text(int.to_string(stock.on_hand - stock.reserved)),
          ]),
        ]),
      ],
    ),
    html.nav([attribute.attribute("aria-label", "Inventory actions")], [
      html.button([event.on_click(Receive)], [html.text("Receive one")]),
      html.button(
        [
          event.on_click(Reserve),
          attribute.disabled(stock.reserved >= stock.on_hand),
        ],
        [html.text("Reserve one")],
      ),
      html.button(
        [event.on_click(Release), attribute.disabled(stock.reserved == 0)],
        [html.text("Release one")],
      ),
    ]),
    html.p([attribute.class("note")], [
      html.text("Each accepted change is recorded. Replay uses this same view."),
    ]),
  ])
}

pub fn replay_module() -> retrace_lustre.ReplayModule(Stock, Command, Refusal) {
  retrace_lustre.ReplayModule(
    contract: contract,
    decode_model: decode_stock,
    decode_event: decode_command,
    reduce: reduce,
    equal: fn(a, b) { a == b },
    view: view,
    viewport: fn(_) { retrace_lustre.Viewport(900, 600) },
    label: fn(event) {
      case event.kind {
        "receive" -> "Received a notebook"
        "reserve" -> "Reserved for an order"
        "release" -> "Released a reservation"
        _ -> event.kind
      }
    },
  )
}
