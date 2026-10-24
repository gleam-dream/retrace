import retrace

pub fn main() {
  let origin = retrace.Origin("git-consumer", "counter-v1")
  let assert Ok(#(recorder, checkpoint)) = retrace.start(origin, 0)
  let assert Ok(#(_, entry)) = retrace.record(recorder, 3, elapsed_ms: 20)
  let assert Ok(player) =
    retrace.replay(checkpoint, "counter-v1", fn(state, message) {
      Ok(state + message)
    })
  let assert Ok(player) = retrace.step(player, entry)
  assert retrace.model(player) == 3
}
