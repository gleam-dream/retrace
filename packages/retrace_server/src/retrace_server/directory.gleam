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
