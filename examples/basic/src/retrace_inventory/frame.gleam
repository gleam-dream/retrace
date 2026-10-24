import retrace_frontend/replay
import retrace_inventory/domain

pub fn mount() -> fn() -> Nil {
  let assert Ok(dispose) =
    replay.mount(domain.replay_module(), domain.build, "#app", 5000)
  dispose
}
