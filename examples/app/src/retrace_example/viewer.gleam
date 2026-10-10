//// Application-specific reconstruction; only the viewer imports timetravel.

import gleam/list
import gleam/result
import gleam/string
import lustre/effect.{type Effect}
import retrace
import retrace/wire
import retrace_example/domain
import timetravel

pub type Player =
  retrace.Player(domain.Model, domain.Message, String)

pub type Inspector =
  timetravel.Model(Player, wire.Event)

pub fn load(batches: List(wire.Batch)) -> Result(Inspector, String) {
  use first <- result.try(
    list.first(batches)
    |> result.map_error(fn(_) { "No recorded events in this session" }),
  )
  case
    first.session.contract == domain.contract
    && first.session.build == domain.build
  {
    False -> Error("This viewer cannot replay that application build")
    True -> {
      use checkpoint <- result.try(decode_checkpoint(first))
      use player <- result.try(
        retrace.replay(checkpoint, domain.contract, domain.reduce)
        |> result.map_error(string.inspect),
      )
      use #(inspector, _) <- result.try(
        timetravel.init_with_capacity(
          arguments: player,
          with: fn(player) { #(player, effect.none()) },
          capacity: 200,
        )
        |> result.map_error(string.inspect),
      )
      list.try_fold(batches, inspector, fn(inspector, batch) {
        use checkpoint <- result.try(decode_checkpoint(batch))
        use _ <- result.try(
          retrace.verify(timetravel.current(inspector), checkpoint, fn(a, b) {
            a == b
          })
          |> result.map_error(string.inspect),
        )
        list.try_fold(batch.entries, inspector, fn(inspector, entry) {
          use message <- result.try(domain.decode_message(entry.event))
          let typed =
            retrace.Entry(
              entry.origin,
              entry.sequence,
              entry.elapsed_ms,
              message,
            )
          use next <- result.try(
            retrace.step(timetravel.current(inspector), typed)
            |> result.map_error(string.inspect),
          )
          let #(inspector, _) =
            timetravel.update(
              model: inspector,
              message: timetravel.App(entry.event),
              with: fn(_, _) { #(next, effect.none()) },
            )
          Ok(inspector)
        })
      })
    }
  }
}

fn decode_checkpoint(
  batch: wire.Batch,
) -> Result(retrace.Checkpoint(domain.Model), String) {
  use model <- result.try(domain.decode_model(batch.checkpoint.model))
  Ok(retrace.Checkpoint(
    batch.checkpoint.origin,
    batch.checkpoint.sequence,
    batch.checkpoint.elapsed_ms,
    model,
  ))
}

pub fn inert(player: Player, _: wire.Event) -> #(Player, Effect(wire.Event)) {
  #(player, effect.none())
}
