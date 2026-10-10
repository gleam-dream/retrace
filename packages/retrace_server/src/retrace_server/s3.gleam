//// S3 adapter using bucket's signed requests and a bounded request timeout.
//// Credentials are supplied by the host; this module never reads the environment.

import bucket
import bucket/create_bucket
import bucket/get_object
import bucket/put_object
import gleam/httpc
import gleam/result
import retrace_server.{type ObjectStore, type StorageError, Missing, Unavailable}

pub fn store(credentials: bucket.Credentials, name: String) -> ObjectStore {
  let transport = httpc.configure() |> httpc.timeout(5000)
  retrace_server.ObjectStore(
    fn(key, body) {
      use response <- result.try(
        put_object.request(name, key, body)
        |> put_object.build(credentials)
        |> httpc.dispatch_bits(transport, _)
        |> result.map_error(fn(_) { Unavailable }),
      )
      put_object.response(response)
      |> result.replace(Nil)
      |> result.map_error(fn(_) { Unavailable })
    },
    fn(key) {
      use response <- result.try(
        get_object.request(name, key)
        |> get_object.build(credentials)
        |> httpc.dispatch_bits(transport, _)
        |> result.map_error(fn(_) { Unavailable }),
      )
      case get_object.response(response) {
        Ok(get_object.Found(body)) -> Ok(body)
        Ok(get_object.NotFound) -> Error(Missing)
        Error(_) -> Error(Unavailable)
      }
    },
  )
}

/// Explicit setup helper for a local example, not part of ordinary admission.
pub fn create(
  credentials: bucket.Credentials,
  name: String,
) -> Result(Nil, StorageError) {
  use response <- result.try(
    create_bucket.request(name)
    |> create_bucket.build(credentials)
    |> httpc.dispatch_bits(httpc.configure() |> httpc.timeout(5000), _)
    |> result.map_error(fn(_) { Unavailable }),
  )
  // Existing buckets should normally be provisioned by the host.
  case response.status {
    200 | 409 -> Ok(Nil)
    _ -> Error(Unavailable)
  }
}
