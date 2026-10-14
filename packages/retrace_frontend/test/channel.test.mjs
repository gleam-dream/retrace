import { test } from "node:test";
import assert from "node:assert/strict";
import {
  trustedOrigin,
  channelPolicy,
  acceptsMessage,
  frameToken,
} from "../src/channel.mjs";
import {
  listen,
  report,
  validateParentOrigin,
} from "../build/dev/javascript/retrace_frontend/replay_ffi.mjs";

test("opaque mode is explicit and never broadens inbound trust", () => {
  assert.deepEqual(channelPolicy("same-origin", "https://staff.example"), {
    receiveOrigin: "https://staff.example",
    targetOrigin: "https://staff.example",
  });
  assert.deepEqual(channelPolicy("opaque", "https://staff.example"), {
    receiveOrigin: "null",
    targetOrigin: "*",
  });
  assert.throws(() => channelPolicy("anything", "https://staff.example"));
  const source = {},
    token = "unique-frame-nonce";
  const event = { source, origin: "null", data: { api: 1, token } };
  assert.equal(acceptsMessage(event, source, "null", token), true);
  for (const changed of [
    { source: {} },
    { origin: "https://staff.example" },
    { data: { api: 1, token: "old-nonce" } },
    { data: { api: 2, token } },
  ])
    assert.equal(
      acceptsMessage({ ...event, ...changed }, source, "null", token),
      false,
    );
  assert.equal(
    acceptsMessage(
      { ...event, data: { api: 1, token: "" } },
      source,
      "null",
      "",
    ),
    false,
  );
});

test("trusted parents must be canonical HTTP origins and token selection is explicit", () => {
  for (const origin of [
    "*",
    "null",
    "https://user:pass@staff.example",
    "https://staff.example/path",
    "https://staff.example/",
    "https://staff.example?token=x",
    "data:text/html,x",
    "https://staff.example#x",
  ])
    assert.equal(validateParentOrigin(origin).isOk(), false);
  assert.equal(trustedOrigin("https://staff.example"), "https://staff.example");
  assert.equal(trustedOrigin("http://127.0.0.1:5050"), "http://127.0.0.1:5050");
  assert.equal(
    frameToken("https://local.example?token=url", "retrace:isolated", false),
    "url",
  );
  assert.equal(
    frameToken("about:srcdoc", "retrace:isolated", true),
    "isolated",
  );
  assert.equal(
    frameToken("https://local.example?token=untrusted", "", true),
    "",
  );
});

test("frame channel validates parent, origin, nonce and API before any reconstruction", () => {
  const saved = Object.fromEntries(
    ["window", "location", "parent"].map((key) => [
      key,
      Object.getOwnPropertyDescriptor(globalThis, key),
    ]),
  );
  const window = new EventTarget();
  window.name = "retrace:isolated-nonce";
  const sent = [],
    loaded = [],
    seeks = [];
  const parent = { postMessage: (...args) => sent.push(args) };
  Object.assign(globalThis, {
    window,
    parent,
    location: new URL("https://local.example?token=local-nonce"),
  });
  const dispatch = (changes = {}) => {
    const event = new Event("message");
    Object.assign(
      event,
      {
        source: parent,
        origin: "https://staff.example",
        data: {
          api: 1,
          token: "isolated-nonce",
          type: "load",
          body: "recording",
        },
      },
      changes,
    );
    window.dispatchEvent(event);
  };
  let stop;
  try {
    stop = listen(
      "build-a",
      (body) => loaded.push(body),
      (sequence) => seeks.push(sequence),
      "https://staff.example",
      true,
    );
    assert.deepEqual(sent[0], [
      { api: 1, token: "isolated-nonce", type: "ready", build: "build-a" },
      "https://staff.example",
    ]);
    for (const changes of [
      { source: {} },
      { origin: "null" },
      { origin: "https://evil.example" },
      { data: { api: 1, token: "wrong", type: "load", body: "bad" } },
    ])
      dispatch(changes);
    assert.deepEqual(loaded, []);
    dispatch();
    assert.deepEqual(loaded, ["recording"]);
    dispatch({
      data: { api: 1, token: "isolated-nonce", type: "seek", sequence: 42 },
    });
    assert.deepEqual(seeks, [42]);
    report("loaded", "metadata");
    assert.equal(sent.at(-1)[1], "https://staff.example");
    stop();
    const count = sent.length;
    dispatch();
    report("loaded", "late");
    assert.equal(sent.length, count);
    assert.deepEqual(loaded, ["recording"]);
    stop = listen(
      "local",
      (body) => loaded.push(body),
      () => {},
    );
    assert.equal(sent.at(-1)[0].token, "local-nonce");
    assert.equal(sent.at(-1)[1], "https://local.example");
  } finally {
    stop?.();
    for (const [key, descriptor] of Object.entries(saved)) {
      if (descriptor) Object.defineProperty(globalThis, key, descriptor);
      else delete globalThis[key];
    }
  }
});

test("viewer creates only explicit script-only opaque frames and fences replaced channels", async () => {
  const { createViewer } = await import("../src/viewer.mjs");
  const keys = [
    "window",
    "location",
    "document",
    "ResizeObserver",
    "cancelAnimationFrame",
    "history",
  ];
  const saved = Object.fromEntries(
    keys.map((key) => [key, Object.getOwnPropertyDescriptor(globalThis, key)]),
  );
  class Element extends EventTarget {
    constructor() {
      super();
      this.dataset = {};
      this.style = {};
      this.attributes = {};
      this.value = "";
    }
    setAttribute(key, value) {
      this.attributes[key] = value;
    }
    removeAttribute(key) {
      delete this[key];
      delete this.attributes[key];
    }
    replaceChildren() {}
    append() {}
  }
  const elements = new Map();
  const root = new Element();
  root.querySelector = (selector) => {
    if (!elements.has(selector)) elements.set(selector, new Element());
    return elements.get(selector);
  };
  root.querySelectorAll = () => [];
  const frame = root.querySelector("iframe"),
    sent = [];
  frame.contentWindow = { postMessage: (...args) => sent.push(args) };
  const window = new EventTarget();
  Object.assign(globalThis, {
    window,
    location: new URL("https://staff.example/?session=one"),
    document: new EventTarget(),
    history: { replaceState() {} },
    cancelAnimationFrame() {},
    ResizeObserver: class {
      observe() {}
      disconnect() {}
    },
  });
  const batch = JSON.stringify({
    session: {
      id: "one",
      build: "immutable",
      user_ref: "opaque",
      platform: "web",
    },
    checkpoint: { sequence: 0 },
    entries: [{ sequence: 1 }],
  });
  const dispatch = (token, overrides = {}) => {
    const event = new Event("message");
    Object.assign(
      event,
      {
        source: frame.contentWindow,
        origin: "null",
        data: { api: 1, token, type: "ready", build: "immutable" },
      },
      overrides,
    );
    window.dispatchEvent(event);
  };
  let stop;
  try {
    stop = createViewer(root, {
      frameMode: "opaque",
      listSessions: async () => [],
      readRange: async () => ({ batches: [batch], next: null }),
      resolveArtifact: async () => ({
        api: 1,
        build: "immutable",
        isolated_html: "<html>verified self-contained frame</html>",
      }),
    });
    await new Promise((resolve) => setImmediate(resolve));
    assert.equal(frame.attributes.sandbox, "allow-scripts");
    assert.equal(frame.referrerPolicy, "no-referrer");
    assert.match(frame.srcdoc, /verified self-contained/);
    assert.equal(frame.src, undefined);
    const first = frame.name.slice(8);
    assert.ok(first);
    dispatch(first, { origin: "https://staff.example" });
    dispatch(first, { source: {} });
    dispatch("old-nonce");
    assert.equal(sent.length, 0);
    dispatch(first);
    assert.equal(sent[0][0].type, "load");
    assert.equal(sent[0][0].body, JSON.stringify([batch]));
    assert.equal(sent[0][1], "*");
    root.querySelector(".reload").dispatchEvent(new Event("click"));
    await new Promise((resolve) => setImmediate(resolve));
    assert.notEqual(frame.name.slice(8), first);
    dispatch(first);
    assert.equal(sent.length, 1);
    dispatch(frame.name.slice(8));
    assert.equal(sent.length, 2);
    stop();
    dispatch(frame.name.slice(8));
    assert.equal(sent.length, 2);
  } finally {
    stop?.();
    for (const [key, descriptor] of Object.entries(saved)) {
      if (descriptor) Object.defineProperty(globalThis, key, descriptor);
      else delete globalThis[key];
    }
  }
});
