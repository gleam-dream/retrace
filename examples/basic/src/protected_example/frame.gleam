import protected_example/observation
import retrace_frontend/replay

pub fn mount() -> fn() -> Nil {
  let assert Ok(dispose) =
    replay.mount(observation.replay_module(), observation.build, "#app", 5000)
  dispose
}
