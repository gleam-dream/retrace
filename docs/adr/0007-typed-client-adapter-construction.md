# Construct client adapters from Gleam

<a id="adr-0007"></a>

On 2026-10-11 the user accepted making the existing client extension points
usable from Gleam while explicitly excluding archive and build-metadata frameworks.
The disposable experiment established that typed callbacks can compose with the
existing delivery runtime and viewer without application-specific JavaScript glue.

An optional module in retrace_client constructs the existing opaque Storage and
Transport values from typed cold operations. Callers retain provider-specific error
types and select their diagnostic formatter. The private bridge owns Promise and
cancellation translation. The delivery runtime keeps sequencing, retry, deadlines,
receipt checking and shutdown. Storage handles remain borrowed; accepted storage
operations must settle rather than being abandoned on shutdown.

Upload callbacks retain the serialized batch and receipt contract. Automatically
decoding and re-encoding envelopes would change the extension's byte-level behavior
and add a JSON dependency without being needed for typed asynchronous composition.
Applications may use the existing wire codec explicitly when interpreting batches.

The advanced example keeps its local archive and browser IO. Queue limits, duplicate
policy and receipt construction move to Gleam; localStorage binding stays private to
the example. A separate support consumer exercises the public interface with native
provider errors and recovery. Exactly two adoption examples remain.

No generic task framework, archive module, public manifest schema, builder helper,
new external dependency or changed portable recording core is introduced.
