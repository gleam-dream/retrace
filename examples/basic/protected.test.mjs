import { test } from "node:test";
import assert from "node:assert/strict";
import {
  Result$Ok,
  Result$Error,
  toList,
} from "./build/dev/javascript/retrace_inventory/gleam.mjs";
import * as live from "./build/dev/javascript/retrace_inventory/protected_example/live.mjs";
import * as screen from "./build/dev/javascript/retrace_inventory/protected_example/screen.mjs";
import * as observation from "./build/dev/javascript/retrace_inventory/protected_example/observation.mjs";
import * as capture from "./build/dev/javascript/retrace_frontend/retrace_frontend/capture.mjs";
import { Config } from "./build/dev/javascript/retrace_frontend/retrace_frontend/client.mjs";
import { load } from "./build/dev/javascript/retrace_frontend/retrace_frontend/replay.mjs";
import { decode_batch } from "./build/dev/javascript/retrace/retrace/wire.mjs";
import { perform } from "./build/dev/javascript/lustre/lustre/effect.mjs";
import { to_string } from "./build/dev/javascript/lustre/lustre/element.mjs";
import { None } from "./build/dev/javascript/gleam_stdlib/gleam/option.mjs";

const app = observation.replay_module();
const short = "§";
const secret = "PRIVATE-LABEL-SENTINEL-7f61";
const run = (effect, dispatch) =>
  perform(effect, dispatch, ...Array(6).fill(() => {}));
const until = async (done) => {
  for (let attempt = 0; attempt < 200; attempt++) {
    if (done()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw Error("Timed out waiting for capture");
};

function decodeAll(bodies) {
  return toList(
    bodies.map((body) => {
      const decoded = decode_batch(body);
      assert.ok(decoded.isOk());
      return decoded[0];
    }),
  );
}

// Real capture/client queue with in-memory storage and acknowledging transport.
// Observe both persistence and upload boundaries, before decoding anything.
async function recordScenario() {
  let state,
    effect,
    clock = 0;
  const persisted = [],
    uploaded = [],
    rows = new Map();
  [state, effect] = capture.start_with_clock(
    capture.session(
      "opaque-reference",
      observation.build,
      observation.contract,
      "web",
    ),
    new Config("local", "protected-test", 100, 1_048_576),
    async () => ({
      all: async () => [...rows].map(([key, body]) => ({ key, body })),
      put: async (key, body) => {
        persisted.push(body);
        rows.set(key, body);
      },
      remove: async (key) => void rows.delete(key),
    }),
    async (body) => {
      uploaded.push(body);
      const batch = JSON.parse(body);
      return JSON.stringify({
        session_id: batch.session.id,
        ack: batch.entries.at(-1).sequence,
      });
    },
    () => clock,
  )[0];
  const dispatch = (message) => {
    state = capture.update(state, message);
  };
  run(effect, dispatch);
  let model = live.initial();
  const expected = [live.project(model)[0]];
  const commands = [];
  try {
    const messages = [
      new live.Act(new screen.Edit(short)),
      new live.Act(new screen.Submit()),
      new live.Act(new screen.ToggleDetails()),
      new live.Act(new screen.Edit(secret)),
      new live.Act(new screen.Submit()),
      new live.Checked(Result$Error(undefined)),
      new live.Act(new screen.Submit()),
      new live.Checked(Result$Ok(undefined)),
      new live.Act(new screen.ToggleLock()),
      new live.Act(new screen.ToggleDetails()),
    ];
    for (const message of messages) {
      const [after, nextCommands] = live.update(model, message);
      commands.push(...nextCommands.toArray());
      clock += 100;
      [state, effect] = capture.observe_projected(
        state,
        live.transition(model, after),
        observation.encode,
        observation.encode_event,
      );
      run(effect, dispatch);
      model = after;
      expected.push(live.project(model)[0]);
    }
    await until(
      () =>
        capture.info(state).saved === messages.length &&
        uploaded.length === messages.length,
    );
    assert.ok(capture.info(state).failure instanceof None);
    return { persisted, uploaded, expected, commands };
  } finally {
    run(capture.stop(state), dispatch);
  }
}

test("placeholder validation diverges; observation replay keeps the original invalid decision through one view", async () => {
  const { uploaded, expected, commands } = await recordScenario();
  assert.deepEqual(live.validate(short), new screen.Invalid());
  assert.deepEqual(
    live.validate(observation.display(new observation.Present())),
    new screen.Valid(),
  );
  const loaded = load(app, decodeAll(uploaded), observation.build, 100);
  assert.ok(loaded.isOk());
  const snapshots = loaded[0].toArray();
  assert.deepEqual(
    snapshots.map((s) => s.model),
    expected,
  );
  assert.equal(commands.length, 2); // Commands exist only on the live path.
  const invalid = snapshots[2].model;
  assert.deepEqual(invalid.validation, new screen.Invalid());
  const html = to_string(app.view(invalid));
  assert.match(html, /Protected content/);
  assert.match(html, /Use at least 3 characters/);
  assert.match(html, /aria-invalid="true"/);
  assert.equal(
    html.replace("<!-- lustre:map -->", ""),
    to_string(screen.view(invalid, observation.display)),
  );
  assert.match(to_string(app.view(snapshots[5].model)), /Checking…/);
  assert.match(to_string(app.view(snapshots[6].model)), /Check unavailable/);
  assert.match(to_string(app.view(snapshots[8].model)), /Check confirmed/);
  assert.match(to_string(app.view(snapshots[9].model)), /Unlock/);
  // A range starting at a later checkpoint still retains the same decisions.
  const suffix = load(
    app,
    decodeAll(uploaded.slice(2)),
    observation.build,
    100,
  );
  assert.ok(suffix.isOk());
  assert.equal(suffix[0].toArray()[0].sequence, 2);
  assert.deepEqual(
    suffix[0].toArray().map((s) => s.model),
    expected.slice(2),
  );
});

test("private sentinels never enter checkpoints, events, persisted rows or upload bodies", async () => {
  const { persisted, uploaded } = await recordScenario();
  assert.deepEqual(persisted, uploaded);
  for (const body of [...persisted, ...uploaded]) {
    for (const sentinel of [short, secret])
      assert.equal(body.includes(sentinel), false);
    const batch = JSON.parse(body);
    for (const encoded of [
      batch.checkpoint.model,
      ...batch.entries.map((e) => e.payload),
    ]) {
      const value = JSON.parse(encoded);
      assert.equal(typeof value.present, "boolean");
      assert.deepEqual(Object.keys(value).sort(), [
        "expanded",
        "locked",
        "present",
        "progress",
        "validation",
        "version",
      ]);
    }
  }
});

test("malformed checkpoints and observations fail closed with no partial range and corrected retry succeeds", async () => {
  const invalid = new screen.State(
    new observation.Absent(),
    new screen.Valid(),
    new screen.Loading(),
    false,
    false,
  );
  assert.equal(observation.adopt(observation.initial(), invalid).isOk(), false);
  const invalidLive = new screen.State(
    "",
    new screen.Valid(),
    new screen.Loading(),
    false,
    false,
  );
  assert.equal(live.project(invalidLive).isOk(), false);
  const { uploaded } = await recordScenario();
  const malformed = [
    { version: 2 },
    { validation: "private-error" },
    { progress: "unknown" },
    { present: secret },
    { locked: "false" },
    { expanded: null },
    { raw: secret },
    { validation: "unchecked", progress: "loading" },
    { present: false, validation: "valid" },
  ];
  for (const mutation of malformed) {
    for (const location of ["checkpoint", "event"]) {
      const bodies = uploaded.map(JSON.parse);
      const index = location === "checkpoint" ? 0 : 5;
      const target =
        location === "checkpoint"
          ? bodies[index].checkpoint
          : bodies[index].entries[0];
      const key = location === "checkpoint" ? "model" : "payload";
      target[key] = JSON.stringify({ ...JSON.parse(target[key]), ...mutation });
      const failed = load(
        app,
        decodeAll(bodies.map(JSON.stringify)),
        observation.build,
        100,
      );
      assert.equal(
        failed.isOk(),
        false,
        JSON.stringify({ location, mutation }),
      );
      assert.equal("model" in failed[0], false);
    }
  }
  const raw = JSON.parse(observation.encode(observation.initial()));
  delete raw.present;
  assert.equal(
    observation.decode_observation(JSON.stringify(raw)).isOk(),
    false,
  );
  const unknown = uploaded.map(JSON.parse);
  unknown[0].entries[0].kind = "submit-live-command";
  assert.equal(
    load(
      app,
      decodeAll(unknown.map(JSON.stringify)),
      observation.build,
      100,
    ).isOk(),
    false,
  );
  assert.equal(
    load(app, decodeAll(uploaded), "another-build", 100).isOk(),
    false,
  );
  const changed = uploaded.map(JSON.parse);
  const before = JSON.parse(changed[2].checkpoint.model);
  changed[2].checkpoint.model = JSON.stringify({
    ...before,
    validation: "unchecked",
  });
  assert.equal(
    load(
      app,
      decodeAll(changed.map(JSON.stringify)),
      observation.build,
      100,
    ).isOk(),
    false,
  );
  assert.ok(load(app, decodeAll(uploaded), observation.build, 100).isOk());
});
