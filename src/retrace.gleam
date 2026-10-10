//// Typed, portable session recording and reconstruction.
//// Callers own safe projections, persistence, clocks and deterministic reducers.

pub type Origin {
  Origin(recording_id: String, contract_id: String)
}

/// Untrusted candidate data. `step` checks its stream invariants before reducing.
pub type Entry(event) {
  Entry(origin: Origin, sequence: Int, elapsed_ms: Int, event: event)
}

pub type Checkpoint(model) {
  Checkpoint(origin: Origin, sequence: Int, elapsed_ms: Int, model: model)
}

pub opaque type Recorder {
  Recorder(origin: Origin, sequence: Int, elapsed_ms: Int)
}

pub opaque type Player(model, event, error) {
  Player(
    origin: Origin,
    sequence: Int,
    elapsed_ms: Int,
    model: model,
    reduce: fn(model, event) -> Result(model, error),
  )
}

pub type Error(error) {
  InvalidOrigin
  InvalidPosition
  DifferentContract(expected: String, received: String)
  DifferentRecording(expected: String, received: String)
  OutOfOrder(expected: Int, received: Int)
  TimeWentBack(previous_ms: Int, received_ms: Int)
  ReductionFailed(sequence: Int, cause: error)
  CheckpointMismatch(sequence: Int)
}

// JavaScript exact integer bound; the candidate contract is portable to BEAM.
const max_position = 9_007_199_254_740_991

/// Begin at sequence zero. The caller owns the recording ID and clock epoch.
pub fn start(
  origin: Origin,
  initial: model,
) -> Result(#(Recorder, Checkpoint(model)), Error(Nil)) {
  case origin.recording_id == "" || origin.contract_id == "" {
    True -> Error(InvalidOrigin)
    False -> Ok(#(Recorder(origin, 0, 0), Checkpoint(origin, 0, 0, initial)))
  }
}

/// Number an already accepted safe event. Return the next recorder and the
/// entry to enqueue. This is not a persistence acknowledgement: the application
/// must commit recorder progress together with its outbox to survive crashes.
/// Equal timestamps are allowed. Use a monotonic elapsed clock, not wall time.
pub fn record(
  recorder: Recorder,
  event: event,
  elapsed_ms elapsed_ms: Int,
) -> Result(#(Recorder, Entry(event)), Error(Nil)) {
  case elapsed_ms < recorder.elapsed_ms {
    True -> Error(TimeWentBack(recorder.elapsed_ms, elapsed_ms))
    False ->
      case elapsed_ms > max_position || recorder.sequence >= max_position {
        True -> Error(InvalidPosition)
        False -> {
          let sequence = recorder.sequence + 1
          let next = Recorder(recorder.origin, sequence, elapsed_ms)
          Ok(#(next, Entry(recorder.origin, sequence, elapsed_ms, event)))
        }
      }
  }
}

/// The caller supplies the safe state after the recorder's latest entry.
/// This function cannot establish that the supplied model matches the entries.
pub fn checkpoint(recorder: Recorder, model: model) -> Checkpoint(model) {
  Checkpoint(recorder.origin, recorder.sequence, recorder.elapsed_ms, model)
}

/// Restore a recorder after the caller has atomically recovered its checkpoint
/// and outbox. This trusts the supplied cursor; it does not claim exclusive
/// ownership of a recording. Concurrent writers must use different IDs.
pub fn resume(checkpoint: Checkpoint(model)) -> Result(Recorder, Error(Nil)) {
  case valid_position(checkpoint.sequence, checkpoint.elapsed_ms) {
    False -> Error(InvalidPosition)
    True ->
      case
        checkpoint.origin.recording_id == ""
        || checkpoint.origin.contract_id == ""
      {
        True -> Error(InvalidOrigin)
        False ->
          Ok(Recorder(
            checkpoint.origin,
            checkpoint.sequence,
            checkpoint.elapsed_ms,
          ))
      }
  }
}

/// Start replay at a checkpoint supplied by the application. Validate its
/// identity, compatibility and cursor; model validity belongs to the decoder.
pub fn replay(
  checkpoint: Checkpoint(model),
  contract_id: String,
  reduce: fn(model, event) -> Result(model, error),
) -> Result(Player(model, event, error), Error(error)) {
  case valid_position(checkpoint.sequence, checkpoint.elapsed_ms) {
    False -> Error(InvalidPosition)
    True ->
      case checkpoint.origin.recording_id == "" || contract_id == "" {
        True -> Error(InvalidOrigin)
        False ->
          case checkpoint.origin.contract_id == contract_id {
            False ->
              Error(DifferentContract(
                contract_id,
                checkpoint.origin.contract_id,
              ))
            True ->
              Ok(Player(
                checkpoint.origin,
                checkpoint.sequence,
                checkpoint.elapsed_ms,
                checkpoint.model,
                reduce,
              ))
          }
      }
  }
}

/// Consume exactly the next entry. Duplicates and gaps are errors; callers own
/// deduplication and missing-range fetching. On error the old player remains
/// usable. Neither a failed reducer nor an invalid entry advances the cursor.
pub fn step(
  player: Player(model, event, error),
  entry: Entry(event),
) -> Result(Player(model, event, error), Error(error)) {
  case check_next(player, entry) {
    Error(reason) -> Error(reason)
    Ok(Nil) ->
      case player.reduce(player.model, entry.event) {
        Error(cause) -> Error(ReductionFailed(entry.sequence, cause))
        Ok(next) ->
          Ok(
            Player(
              ..player,
              model: next,
              sequence: entry.sequence,
              elapsed_ms: entry.elapsed_ms,
            ),
          )
      }
  }
}

pub fn model(player: Player(model, event, error)) -> model {
  player.model
}

pub fn position(player: Player(model, event, error)) -> Int {
  player.sequence
}

/// Compare reconstructed state with a checkpoint at the same cursor and time.
/// Caller-defined equality is a consistency check, not an authenticity proof.
pub fn verify(
  player: Player(model, event, error),
  checkpoint: Checkpoint(model),
  equal: fn(model, model) -> Bool,
) -> Result(Nil, Error(error)) {
  case same_origin(player.origin, checkpoint.origin) {
    Error(reason) -> Error(reason)
    Ok(Nil) ->
      case
        player.sequence == checkpoint.sequence
        && player.elapsed_ms == checkpoint.elapsed_ms
        && equal(player.model, checkpoint.model)
      {
        True -> Ok(Nil)
        False -> Error(CheckpointMismatch(checkpoint.sequence))
      }
  }
}

fn valid_position(sequence: Int, elapsed_ms: Int) -> Bool {
  sequence >= 0
  && sequence <= max_position
  && elapsed_ms >= 0
  && elapsed_ms <= max_position
}

fn same_origin(
  expected: Origin,
  received: Origin,
) -> Result(Nil, Error(error)) {
  case expected.contract_id == received.contract_id {
    False ->
      Error(DifferentContract(expected.contract_id, received.contract_id))
    True ->
      case expected.recording_id == received.recording_id {
        True -> Ok(Nil)
        False ->
          Error(DifferentRecording(expected.recording_id, received.recording_id))
      }
  }
}

fn check_next(
  player: Player(model, event, error),
  entry: Entry(event),
) -> Result(Nil, Error(error)) {
  case same_origin(player.origin, entry.origin) {
    Error(reason) -> Error(reason)
    Ok(Nil) ->
      case
        valid_position(entry.sequence, entry.elapsed_ms)
        && player.sequence < max_position
      {
        False -> Error(InvalidPosition)
        True ->
          case entry.sequence == player.sequence + 1 {
            False -> Error(OutOfOrder(player.sequence + 1, entry.sequence))
            True ->
              case entry.elapsed_ms >= player.elapsed_ms {
                False ->
                  Error(TimeWentBack(player.elapsed_ms, entry.elapsed_ms))
                True -> Ok(Nil)
              }
          }
      }
  }
}
