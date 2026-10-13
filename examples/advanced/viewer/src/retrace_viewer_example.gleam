import retrace_example/local_archive
import retrace_frontend/viewer

pub fn main() -> fn() -> Nil {
  let artifacts =
    viewer.artifacts("/artifacts")
    |> viewer.with_development(
      "membership-screen-v2-dev",
      "membership-screen-v2",
      case local_archive.selected() {
        True -> "/frame.html"
        False -> "/dev-frame.html"
      },
    )
  let source = case local_archive.selected() {
    True -> local_archive.source()
    False -> viewer.collector("http://127.0.0.1:4417")
  }
  let config = viewer.new(source, artifacts)
  let assert Ok(dispose) =
    viewer.Config(..config, max_entries: 2000)
    |> viewer.mount("#viewer")
  dispose
}
