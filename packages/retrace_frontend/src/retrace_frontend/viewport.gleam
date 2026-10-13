//// Optional CSS viewport observation for browser and Tauri WebViews.

pub type Viewport {
  Viewport(width: Int, height: Int, top: Int, bottom: Int)
}

pub fn read() -> Viewport {
  read_with(Viewport)
}

pub fn observe(callback: fn(Viewport) -> Nil) -> fn() -> Nil {
  observe_with(Viewport, callback)
}

@external(javascript, "../viewport.mjs", "readTyped")
fn read_with(make: fn(Int, Int, Int, Int) -> Viewport) -> Viewport

@external(javascript, "../viewport.mjs", "observeTyped")
fn observe_with(
  make: fn(Int, Int, Int, Int) -> Viewport,
  callback: fn(Viewport) -> Nil,
) -> fn() -> Nil
