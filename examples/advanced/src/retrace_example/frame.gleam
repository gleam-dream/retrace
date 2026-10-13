//// Historical entrypoint: shared view, no capture or native effects.

import retrace_example/api
import retrace_example/replay
import retrace_frontend/replay as frame

pub fn main() -> Nil {
  let assert Ok(_) = frame.mount(replay.module(), api.build(), "#app", 5000)
  Nil
}
