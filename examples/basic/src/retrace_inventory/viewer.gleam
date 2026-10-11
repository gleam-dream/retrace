import retrace_inventory/domain
import retrace_viewer as viewer

pub fn main() -> fn() -> Nil {
  let resolver =
    viewer.artifacts("/artifacts")
    |> viewer.with_development(domain.build, domain.contract, "/frame.html")
  let assert Ok(dispose) =
    viewer.new(viewer.collector("http://127.0.0.1:4417"), resolver)
    |> viewer.mount("#viewer")
  dispose
}
