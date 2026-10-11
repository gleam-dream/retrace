//// Optional native adapter. Only importing applications need the npm plugin.

import retrace_client.{type Storage}

@external(javascript, "./tauri_ffi.mjs", "tauriStorage")
pub fn storage() -> Storage
