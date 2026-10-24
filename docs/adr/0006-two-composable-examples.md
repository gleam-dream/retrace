# Keep two composable adoption examples

<a id="adr-0006"></a>

On 2026-10-10 the user requested exactly two examples: basic and advanced,
with interfaces that let consumers assemble their own systems easily.

The basic inventory example demonstrates the provided capture, storage,
transport and viewer APIs without handwritten FFI or native dependencies.
The advanced membership example retains Tauri and historical build artifacts,
and also demonstrates a custom local archive through the same public storage,
transport, source and resolver boundaries. It owns its viewer as a separate
entrypoint within that example, rather than presenting a third application.

The shared Mist collector moves into development tooling. The backend fault
consumer remains an isolated test harness. Both live under support/ because
Gleam recursively compiles dev/ and test/ within an owning package; separate
consumer dependencies must not enter the portable core’s compilation. These relocations preserve runtime and fault
evidence without presenting infrastructure harnesses as additional adoption
examples. This supersedes the example folder layout described in ADRs 0003–0005.

No new example-specific library wrapper is introduced. Applications retain
native domain types and pure reducers. Package defaults and public extension
points keep the same validation, bounds and explicit cleanup contracts.
Historical replay assets and stored sessions are preserved during relocation.

Example presentation conventions (palette, typography, layout and component
treatment) are defined by the example stylesheets. No separate style document is
maintained, so the stylesheets are the single source for presentation.
