import retrace_inventory/domain
import retrace_lustre

pub fn mount() -> fn() -> Nil {
  let assert Ok(dispose) =
    retrace_lustre.mount(domain.replay_module(), domain.build, "#app", 5000)
  dispose
}
