//// Historical entrypoint: shared view, no capture or native effects.

import retrace_example/api
import retrace_example/replay
import retrace_lustre

pub fn main() -> Nil {
  let assert Ok(_) =
    retrace_lustre.mount(replay.module(), api.build(), "#app", 5000)
  Nil
}
