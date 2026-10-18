# Context map

## Contexts

- [Recording](design/recording/CONTEXT.typ) owns sessions, entries, checkpoints, batches, acknowledgements, client delivery and capture coordination.
- [Archive](design/archive/CONTEXT.typ) owns batch receipts, archive generations, deletion fences and the server-side path from admission to erasure.
- [Replay](design/replay/CONTEXT.typ) owns replay modules, replay artifacts, the viewer and build identity.

## Relationships

- Recording to Archive: customer/supplier. Recording supplies batches and defines the acknowledgement. Archive supplies the acknowledgement after a durable commit.
- Recording to Replay: conformist. Replay uses the session, batch, checkpoint and replay-contract terms exactly as Recording defines them.
- Archive to Replay: customer/supplier. Replay requests ordered pages of verified batches, and Archive supplies them without knowing application types.
