import retrace_example/domain
import retrace_lustre/viewport as presentation

@external(javascript, "../example_ffi.mjs", "endpoint")
pub fn endpoint() -> String

@external(javascript, "../example_ffi.mjs", "userRef")
pub fn user_ref() -> String

@external(javascript, "../example_ffi.mjs", "platform")
pub fn platform() -> String

@external(javascript, "../example_ffi.mjs", "device")
pub fn device(callback: fn(String) -> Nil) -> Nil

@external(javascript, "../example_ffi.mjs", "buildId")
pub fn build() -> String

fn from_observation(value: presentation.Viewport) -> domain.Viewport {
  domain.Viewport(value.width, value.height, value.top, value.bottom)
}

pub fn viewport() -> domain.Viewport {
  presentation.read() |> from_observation
}

pub fn observe_viewport(callback: fn(domain.Viewport) -> Nil) -> fn() -> Nil {
  presentation.observe(fn(value) { callback(from_observation(value)) })
}
