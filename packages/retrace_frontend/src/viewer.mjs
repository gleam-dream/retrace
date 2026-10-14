import { positionAt, advance, clusters, previousTime } from "./timeline.mjs";
import { loadRange } from "./range.mjs";
import { channelPolicy, acceptsMessage } from "./channel.mjs";
const format = (ms) =>
  `${Math.floor(ms / 60000)}:${((ms / 1000) % 60).toFixed(1).padStart(4, "0")}`;
function node(tag, className, text) {
  const element = document.createElement(tag);
  if (className) element.className = className;
  if (text !== undefined) element.textContent = text;
  return element;
}
// Experimental default shell. Callers own reads and artifact resolution; this
// function owns one frame, its clock/listeners and DOM, and returns cleanup.
export function createViewer(
  root,
  {
    listSessions,
    readRange,
    resolveArtifact,
    labelEvent = (e) => e.label || e.kind,
    maxEntries = 5000,
    frameMode = "same-origin",
  },
) {
  const channel = channelPolicy(frameMode, location.origin);
  root.innerHTML = `<header class="topbar"><strong>Retrace</strong><span>Session viewer</span><span class="local">Local development</span></header>
 <div class="layout"><aside class="sessions"><h1>Sessions</h1><form class="search"><label for="user">User reference</label><div><input id="user" autocomplete="off" placeholder="All users"><button type="submit" aria-label="Refresh sessions">Find</button></div></form><p class="search-status" role="status"></p><div class="session-list"></div></aside>
 <main class="workspace"><header class="session-heading"><div><h2>Select a recording</h2><p class="identity">Choose a session to reconstruct its application.</p></div><button class="reload" hidden>Reload recording</button></header>
 <div class="replay-body"><section class="stage" aria-label="Recorded application"><div class="stage-message" role="status">Record some interactions in the app, then find the session here.</div><div class="frame-size" hidden><iframe title="Recorded application" tabindex="-1"></iframe></div><p class="viewport-label"></p></section><aside class="events"><header><h3>Events</h3><span class="count">0</span></header><p class="event-hint">Select an event to seek. Equal-time events appear together.</p><ol></ol></aside></div>
 <footer class="transport"><div class="transport-controls"><button class="previous" aria-label="Previous event" disabled>Previous</button><button class="play" disabled>Play</button><button class="next" aria-label="Next event" disabled>Next</button><output class="clock">0:00.0 / 0:00.0</output><label class="speed-label">Speed <select aria-label="Playback speed"><option value="0.5">0.5×</option><option value="1" selected>1×</option><option value="2">2×</option><option value="4">4×</option></select></label></div>
 <div class="timeline"><div class="markers"></div><input class="scrubber" type="range" min="0" max="1" value="0" step="1" aria-label="Playback position" disabled></div><div class="timeline-caption"><span>Original timing · gaps preserved</span><span class="range-note">No recording loaded</span></div></footer></main></div>`;
  const $ = (s) => root.querySelector(s),
    frame = $("iframe"),
    signal = new AbortController();
  frame.referrerPolicy = "no-referrer";
  if (frameMode === "opaque") frame.setAttribute("sandbox", "allow-scripts");
  let request = 0,
    searchRequest = 0,
    token = "",
    selected = "",
    build = "",
    events = [],
    position = 0,
    time = 0,
    duration = 0,
    playing = false,
    speed = 1,
    raf = 0,
    last = 0,
    timeout,
    rows = [],
    disposed = false,
    reading,
    searching;
  const params = new URL(location.href).searchParams;
  $("#user").value = params.get("user") || "";
  const initialSession = params.get("session"),
    initialTime = Math.max(0, Number(params.get("t")) || 0);
  const on = (target, name, callback) =>
    target.addEventListener(name, callback, { signal: signal.signal });
  function url() {
    const target = new URL(location.href);
    target.searchParams.set("session", selected);
    target.searchParams.set("t", String(Math.floor(time)));
    if ($("#user").value) target.searchParams.set("user", $("#user").value);
    else target.searchParams.delete("user");
    history.replaceState(null, "", target);
  }
  function send(type, extra = {}) {
    frame.contentWindow?.postMessage(
      { api: 1, token, type, ...extra },
      channel.targetOrigin,
    );
  }
  function pause() {
    playing = false;
    cancelAnimationFrame(raf);
    $(".play").textContent = "Play";
    if (events.length) url();
  }
  function fail(message) {
    pause();
    clearTimeout(timeout);
    events = [];
    frame.removeAttribute("src");
    frame.removeAttribute("srcdoc");
    $(".frame-size").hidden = true;
    $(".stage-message").hidden = false;
    $(".stage-message").textContent = message;
    $(".stage-message").setAttribute("role", "alert");
    for (const item of root.querySelectorAll(".transport button,.scrubber"))
      item.disabled = true;
    $(".range-note").textContent = "Playback unavailable";
    $(".viewport-label").textContent = "";
    $(".events ol").replaceChildren();
    $(".markers").replaceChildren();
    $(".count").textContent = "0";
  }
  function fit() {
    if (!events.length) return;
    const v = events[position].viewport,
      stage = $(".stage"),
      scale = Math.min(
        1,
        (stage.clientWidth - 48) / (v.width + 16),
        (stage.clientHeight - 62) / (v.height + 16),
      );
    const safeScale = Math.max(0.05, scale),
      phone = v.width < 700;
    frame.style.width = `${v.width}px`;
    frame.style.height = `${v.height}px`;
    const box = $(".frame-size");
    box.style.width = `${(v.width + 16) * safeScale}px`;
    box.style.height = `${(v.height + 16) * safeScale}px`;
    frame.style.transform = `scale(${safeScale})`;
    frame.style.borderRadius = phone ? "28px" : "8px";
    $(".viewport-label").textContent =
      `${v.width} × ${v.height} CSS px · ${Math.round(safeScale * 100)}% · ${phone ? "phone viewport" : "browser viewport"}`;
  }
  function markers() {
    const layer = $(".markers");
    layer.replaceChildren();
    for (const group of clusters(
      events.slice(1),
      duration,
      layer.clientWidth,
      events[0].elapsed,
    )) {
      const button = node("button", "marker");
      button.style.left = `${((group[0].elapsed - events[0].elapsed) / Math.max(1, duration - events[0].elapsed)) * 100}%`;
      button.title = `${format(group[0].elapsed)} · ${group.map((e) => labelEvent(e)).join(", ")}`;
      button.setAttribute("aria-label", button.title);
      if (group.length > 1) {
        button.textContent = String(group.length);
        button.classList.add("cluster");
      }
      button.onclick = () => seek(group[0].elapsed);
      layer.append(button);
    }
  }
  function render() {
    const previous = position;
    const next = positionAt(events, time);
    if (next !== position) {
      position = next;
      send("seek", { sequence: events[position].sequence, position });
      fit();
    }
    $(".scrubber").value = String(Math.floor(time));
    $(".scrubber").setAttribute(
      "aria-valuetext",
      `${format(time)} of ${format(duration)}`,
    );
    $(".clock").textContent = `${format(time)} / ${format(duration)}`;
    if (previous !== position) {
      rows[previous - 1]?.setAttribute("aria-current", "false");
      rows[position - 1]?.setAttribute("aria-current", "true");
    }
    $(".previous").disabled = time <= (events[0]?.elapsed || 0);
    $(".next").disabled = position === events.length - 1;
  }
  function seek(value) {
    pause();
    time = Math.max(events[0]?.elapsed || 0, Math.min(duration, value));
    render();
    url();
  }
  function tick(now) {
    if (!playing) return;
    time = advance(time, now - last, speed, duration);
    last = now;
    render();
    if (time >= duration) pause();
    else raf = requestAnimationFrame(tick);
  }
  on($(".play"), "click", () => {
    if (playing) return pause();
    if (time >= duration) {
      time = events[0]?.elapsed || 0;
      render();
    }
    playing = true;
    last = performance.now();
    $(".play").textContent = "Pause";
    raf = requestAnimationFrame(tick);
  });
  on($(".scrubber"), "input", (event) => seek(Number(event.target.value)));
  on($("select"), "change", (event) => {
    if (playing) {
      const now = performance.now();
      time = advance(time, now - last, speed, duration);
      last = now;
      render();
    }
    speed = Number(event.target.value);
  });
  on($(".previous"), "click", () => seek(previousTime(events, time)));
  on($(".next"), "click", () =>
    seek(events[Math.min(events.length - 1, position + 1)].elapsed),
  );
  on(document, "visibilitychange", () => {
    if (document.hidden) pause();
  });
  on(window, "message", (event) => {
    const data = event.data;
    if (
      !acceptsMessage(event, frame.contentWindow, channel.receiveOrigin, token)
    )
      return;
    if (data.type === "ready") {
      if (data.build !== build)
        return fail("The artifact build does not match this session.");
      send("load", { body: frame.dataset.recording });
    } else if (data.type === "error") fail(String(data.body));
    else if (data.type === "loaded") {
      clearTimeout(timeout);
      try {
        events = JSON.parse(data.body);
        if (
          !Array.isArray(events) ||
          !events.length ||
          events.some(
            (e, i) =>
              !Number.isSafeInteger(e.elapsed) ||
              e.elapsed < 0 ||
              !Number.isSafeInteger(e.sequence) ||
              e.sequence < 0 ||
              (i && e.sequence !== events[i - 1].sequence + 1) ||
              (i && e.elapsed < events[i - 1].elapsed) ||
              !e.viewport ||
              ![e.viewport.width, e.viewport.height].every(
                (n) => Number.isInteger(n) && n > 0 && n <= 8192,
              ),
          )
        )
          throw Error();
      } catch {
        return fail("Artifact returned invalid timeline metadata.");
      }
      duration = events.at(-1).elapsed;
      position = -1;
      time = Math.max(
        events[0].elapsed,
        Math.min(
          duration,
          frame.dataset.startTime ? Number(frame.dataset.startTime) : 0,
        ),
      );
      $(".stage-message").hidden = true;
      $(".frame-size").hidden = false;
      $(".scrubber").min = String(events[0].elapsed);
      $(".scrubber").max = String(Math.max(1, duration));
      $(".scrubber").disabled = false;
      $(".play").disabled = duration === events[0].elapsed;
      $(".range-note").textContent =
        "Loaded through last event · session end unknown";
      $(".count").textContent = String(events.length - 1);
      const list = $(".events ol");
      list.replaceChildren();
      rows = events.slice(1).map((e) => {
        const li = node("li"),
          button = node("button", "event-row"),
          stamp = node("time", "", format(e.elapsed)),
          label = node("span", "", labelEvent(e)),
          seq = node("small", "", `#${e.sequence}`);
        button.append(stamp, label, seq);
        button.onclick = () => seek(e.elapsed);
        li.append(button);
        list.append(li);
        return button;
      });
      render();
      fit();
      markers();
      url();
    }
  });
  async function open(id, startTime = 0) {
    const generation = ++request;
    reading?.abort();
    reading = new AbortController();
    pause();
    events = [];
    selected = id;
    token = crypto.randomUUID();
    clearTimeout(timeout);
    frame.removeAttribute("src");
    frame.removeAttribute("srcdoc");
    $(".reload").hidden = false;
    $(".frame-size").hidden = true;
    $(".stage-message").hidden = false;
    $(".stage-message").setAttribute("role", "status");
    $(".stage-message").textContent =
      "Loading recording and its application build…";
    $(".session-heading h2").textContent = "Session replay";
    $(".identity").textContent = id;
    $(".events ol").replaceChildren();
    $(".markers").replaceChildren();
    $(".count").textContent = "0";
    $(".clock").textContent = "0:00.0 / 0:00.0";
    $(".range-note").textContent = "Loading recorded range";
    for (const item of root.querySelectorAll(".transport button,.scrubber"))
      item.disabled = true;
    for (const item of root.querySelectorAll(".session-row"))
      item.setAttribute("aria-pressed", String(item.dataset.id === id));
    try {
      const batches = await loadRange(readRange, id, {
        after: Number(new URL(location.href).searchParams.get("after") || 0),
        maxEntries,
        signal: reading.signal,
      });
      if (generation !== request || disposed) return;
      if (!batches.length)
        throw Error("This session has no recorded events yet. Try reloading.");
      const session = JSON.parse(batches[0]).session;
      if (
        session.id !== id ||
        batches.some((b) => JSON.parse(b).session.id !== id)
      )
        throw Error("Storage returned a different session.");
      const artifact = await resolveArtifact(session, {
        signal: reading.signal,
      });
      if (generation !== request || disposed) return;
      if (artifact.api !== 1 || artifact.build !== session.build)
        throw Error("Unsupported artifact protocol or build.");
      let target;
      if (frameMode === "opaque") {
        if (
          typeof artifact.isolated_html !== "string" ||
          !artifact.isolated_html
        )
          throw Error(
            "Opaque replay requires a verified self-contained document.",
          );
      } else {
        target = new URL(artifact.url, location.href);
        if (
          target.origin !== location.origin ||
          target.username ||
          target.password
        )
          throw Error(
            "This local viewer only loads artifacts from its own origin.",
          );
      }
      build = session.build;
      $(".session-heading h2").textContent =
        `${session.user_ref} · ${session.platform === "tauri" ? "Tauri" : "Web"}`;
      $(".identity").textContent =
        `${id} · ${artifact.development ? "mutable development build" : build}`;
      frame.name = `retrace:${token}`;
      frame.dataset.recording = JSON.stringify(batches);
      frame.dataset.startTime = String(startTime);
      if (frameMode === "opaque") frame.srcdoc = artifact.isolated_html;
      else {
        target.searchParams.set("token", token);
        frame.src = target.href;
      }
      timeout = setTimeout(
        () =>
          fail(
            "The replay artifact did not respond. Restore the matching build and retry.",
          ),
        10000,
      );
    } catch (error) {
      if (generation === request && !disposed) fail(error.message);
    }
  }
  on($(".reload"), "click", () => open(selected, time));
  async function search() {
    const generation = ++searchRequest;
    searching?.abort();
    searching = new AbortController();
    $(".search-status").textContent = "Loading sessions…";
    try {
      const sessions = await listSessions($("#user").value, {
        signal: searching.signal,
      });
      if (generation !== searchRequest || disposed) return;
      const list = $(".session-list");
      list.replaceChildren();
      for (const row of sessions) {
        const s = row.session,
          button = node("button", "session-row");
        button.dataset.id = s.id;
        button.setAttribute("aria-pressed", String(s.id === selected));
        button.append(
          node("strong", "", s.user_ref),
          node("span", "", `${s.platform} · ${row.sequence} events`),
          node("small", "", s.id),
        );
        button.onclick = () => open(s.id);
        list.append(button);
      }
      $(".search-status").textContent = sessions.length
        ? `${sessions.length} sessions`
        : "No sessions found. Record an interaction, then find again.";
    } catch (error) {
      if (generation === searchRequest && !disposed)
        $(".search-status").textContent = error.message;
    }
  }
  on($("form"), "submit", (event) => {
    event.preventDefault();
    search();
  });
  const resize = new ResizeObserver(() => {
    if (disposed) return;
    fit();
    if (events.length) markers();
  });
  resize.observe($(".stage"));
  resize.observe($(".markers"));
  search();
  if (initialSession) open(initialSession, initialTime);
  return () => {
    if (disposed) return;
    disposed = true;
    request++;
    pause();
    clearTimeout(timeout);
    signal.abort();
    reading?.abort();
    searching?.abort();
    resize.disconnect();
    root.replaceChildren();
  };
}
