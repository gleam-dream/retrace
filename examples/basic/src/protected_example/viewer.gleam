import protected_example/observation
import retrace_frontend/viewer

pub fn main() -> fn() -> Nil {
  let resolver =
    viewer.artifacts("/artifacts")
    |> viewer.with_development(
      observation.build,
      observation.contract,
      "/protected-frame.html",
    )
  let assert Ok(dispose) =
    viewer.new(viewer.collector("http://127.0.0.1:4417"), resolver)
    |> viewer.mount("#viewer")
  dispose
}
