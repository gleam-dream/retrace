// Public API behavior: recording, replay and recovery with application types.
import gleeunit
import retrace as recording

type Card {
  Card(points: Int, compact: Bool)
}

type Message {
  SetCompact(Bool)
  PointsReceived(Int)
}

type AppError {
  NegativePoints(Int)
}

fn reduce(card: Card, message: Message) -> Result(Card, AppError) {
  case message {
    SetCompact(value) -> Ok(Card(..card, compact: value))
    PointsReceived(value) ->
      case value >= 0 {
        True -> Ok(Card(..card, points: value))
        False -> Error(NegativePoints(value))
      }
  }
}

type PrivateModel {
  PrivateModel(email: String, card: Card)
}

fn projection(model: PrivateModel) -> Card {
  model.card
}

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn recording_and_recovery_test() -> Nil {
  let origin = recording.Origin("device-session-1", "card-v1")
  let private = PrivateModel("never-captured@example.invalid", Card(100, False))
  let assert Ok(#(recorder, initial)) =
    recording.start(origin, projection(private))
  let assert Ok(#(recorder, first)) =
    recording.record(recorder, SetCompact(True), elapsed_ms: 20)
  let assert Ok(#(recorder, second)) =
    recording.record(recorder, PointsReceived(120), elapsed_ms: 30)
  let saved = recording.checkpoint(recorder, Card(120, True))

  // Ordinary use: app-native records and variants, no JSON/HTTP/Lustre runtime.
  let assert Ok(player) = recording.replay(initial, "card-v1", reduce)
  let assert Ok(one) = recording.step(player, first)
  let assert Ok(two) = recording.step(one, second)
  assert recording.model(two) == Card(120, True)
  let assert Ok(Nil) = recording.verify(two, saved, fn(a, b) { a == b })

  // Advanced use: seek from a checkpoint and feed chunks as they arrive.
  let assert Ok(resumed) = recording.replay(saved, "card-v1", reduce)
  let assert Ok(#(_recorder, third)) =
    recording.record(recorder, SetCompact(False), elapsed_ms: 40)
  let assert Ok(three) = recording.step(resumed, third)
  assert recording.model(three) == Card(120, False)
  assert recording.position(three) == 3

  // Missing input fails locally. The caller fetches it and retries the old value.
  let assert Error(recording.OutOfOrder(1, 2)) = recording.step(player, second)
  let assert Ok(recovered) = recording.step(player, first)
  let assert Ok(recovered) = recording.step(recovered, second)
  assert recording.model(recovered) == recording.model(two)

  // Caller error detail is retained rather than rendered to a string.
  let invalid = recording.Entry(origin, 3, 40, PointsReceived(-2))
  let assert Error(recording.ReductionFailed(3, NegativePoints(-2))) =
    recording.step(two, invalid)
  assert recording.position(two) == 2

  let assert Error(recording.DifferentContract("card-v2", "card-v1")) =
    recording.replay(saved, "card-v2", reduce)
  let wrong_recording =
    recording.Entry(
      recording.Origin("device-session-2", "card-v1"),
      3,
      40,
      SetCompact(False),
    )
  let assert Error(recording.DifferentRecording(_, _)) =
    recording.step(two, wrong_recording)
  let assert Error(recording.OutOfOrder(3, 2)) = recording.step(two, second)
  let backwards = recording.Entry(origin, 3, 29, SetCompact(False))
  let assert Error(recording.TimeWentBack(30, 29)) =
    recording.step(two, backwards)
  let corrupted = recording.Checkpoint(origin, 2, 30, Card(999, True))
  let assert Error(recording.CheckpointMismatch(2)) =
    recording.verify(two, corrupted, fn(a, b) { a == b })
  let assert Error(recording.InvalidOrigin) =
    recording.start(recording.Origin("", "card-v1"), Card(0, False))

  // Restart capture from an application-owned durable cursor.
  let assert Ok(restarted) = recording.resume(saved)
  let assert Ok(#(_, after_restart)) =
    recording.record(restarted, SetCompact(False), elapsed_ms: 40)
  assert after_restart.sequence == 3
  let assert Error(recording.TimeWentBack(30, 29)) =
    recording.record(restarted, SetCompact(False), elapsed_ms: 29)
  let invalid_position = recording.Checkpoint(origin, -1, 0, Card(0, False))
  let assert Error(recording.InvalidPosition) =
    recording.resume(invalid_position)
  let assert Error(recording.InvalidPosition) =
    recording.replay(invalid_position, "card-v1", reduce)
  let overflow =
    recording.Checkpoint(origin, 9_007_199_254_740_991, 0, Card(0, False))
  let assert Ok(exhausted) = recording.resume(overflow)
  let assert Error(recording.InvalidPosition) =
    recording.record(exhausted, SetCompact(False), elapsed_ms: 0)

  // A wholly different consumer can use the same package without app types.
  let assert Ok(#(counter, base)) =
    recording.start(recording.Origin("simulation-1", "sum-v1"), 10)
  let assert Ok(#(_, add)) = recording.record(counter, 7, elapsed_ms: 0)
  let assert Ok(counter_player) =
    recording.replay(base, "sum-v1", fn(state: Int, event: Int) -> Result(
      Int,
      Nil,
    ) {
      Ok(state + event)
    })
  let assert Ok(counter_player) = recording.step(counter_player, add)
  assert recording.model(counter_player) == 17
}
