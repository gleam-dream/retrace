//// Local object-storage adapter for development and recovery tests.

import retrace_server.{type ObjectStore, type StorageError}

pub fn store(root: String) -> ObjectStore {
  retrace_server.ObjectStore(fn(key, body) { put(root, key, body) }, fn(key) {
    get(root, key)
  })
}

@external(erlang, "retrace_server_ffi", "directory_put")
fn put(root: String, key: String, body: BitArray) -> Result(Nil, StorageError)

@external(erlang, "retrace_server_ffi", "directory_get")
fn get(root: String, key: String) -> Result(BitArray, StorageError)

@external(erlang, "retrace_server_ffi", "directory_remove")
pub fn remove(root: String, key: String) -> Result(Nil, StorageError)

/// The local put writes, syncs and renames inside the calling process, so a put
/// that returned an error has finished and cannot publish later. A put that
/// never returned may be running or lost with its process, which this adapter
/// cannot tell apart, so a host overrides that case from its own supervision.
pub fn quiesced(
  attempt: retrace_server.WriteAttempt,
) -> retrace_server.Quiescence {
  case attempt.state {
    retrace_server.Failed ->
      retrace_server.Quiescent(
        "the local adapter finishes every write before put returns",
      )
    _ -> retrace_server.MayPublish
  }
}
