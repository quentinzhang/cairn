import assert from "node:assert/strict";
import { chmod, mkdir, mkdtemp, readFile, readdir, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  completionPayload,
  createRelay,
  publish,
  removeRuntimeMarker,
  writeRuntimeMarker,
} from "./index.js";

const text = (value) => [{ type: "text", text: value }];
const user = (seq, value, source = { kind: "user" }) => ({
  type: "user/message", seq, time: 1000 + seq,
  data: { id: `user-${seq}`, role: "user", content: text(value), source },
});
const assistant = (seq, turn, value, model = "deepseek-test") => ({
  type: "assistant/message", seq, time: 1000 + seq,
  data: {
    turn, step: 1,
    message: {
      id: `assistant-${seq}`, role: "assistant",
      content: [{ type: "reasoning", text: "private" }, ...text(value)],
      source: { kind: "model", provider: "test", model },
    },
  },
});
const completed = (seq = 4, turn = 1) => ({
  type: "turn/end", seq, time: 1_723_600_000_000,
  data: { turn, reason: { kind: "completed" } },
});
const session = (header = {}, end = completed()) => ({
  id: "session-1",
  header: { id: "session-1", cwd: "/tmp/project", ...header },
  events: [
    { type: "turn/start", seq: 0, time: 1000, data: { turn: 1 } },
    user(1, "ship it"),
    user(2, "injected", { kind: "plugin", plugin: "context" }),
    assistant(3, 1, "final answer", "model-1"),
    end,
  ],
});

test("maps one top-level completed turn to the minimal Cairn payload", () => {
  const payload = completionPayload(session(), completed(), 43123);
  assert.deepEqual(
    {
      id: payload.id, source: payload.source, result: payload.result,
      session: payload.session_id, turn: payload.turn_id, cwd: payload.cwd,
      model: payload.model, user: payload.user_message, url: payload.locator.web_url,
    },
    {
      id: "session-1:1", source: "deepseek-harness", result: "final answer",
      session: "session-1", turn: "1", cwd: "/tmp/project",
      model: "model-1", user: "ship it", url: "http://127.0.0.1:43123/",
    },
  );
  assert.equal(payload.timestamp, "2024-08-14T01:46:40.000Z");
  assert.doesNotMatch(JSON.stringify(payload), /private|injected/);
});

test("filters subagents, failures, aborted turns, and empty final text", () => {
  for (const header of [
    { origin: "subagent" },
    { parentSession: "parent" },
    { delegationDepth: 1 },
  ]) {
    assert.equal(completionPayload(session(header), completed(), 3080), null);
  }
  for (const kind of ["aborted", "error", "blocked"]) {
    const end = { ...completed(), data: { turn: 1, reason: { kind } } };
    assert.equal(completionPayload(session({}, end), end, 3080), null);
  }
  const empty = session();
  empty.events[3].data.message.content = [{ type: "reasoning", text: "not final" }];
  assert.equal(completionPayload(empty, completed(), 3080), null);
});

test("publishes a duplicate session/turn only once and contains write failures", async () => {
  const handlers = new Map();
  const ctx = {
    webServer: { port: 3080 },
    on: (event, handler) => handlers.set(event, handler),
  };
  const root = await mkdtemp(join(tmpdir(), "cairn-dsh-relay-"));
  const markerPath = join(root, "runtime", "marker.json");
  const payloads = [];
  let attempts = 0;
  try {
    const relay = createRelay(ctx, {
      markerPath,
      owner: "owner-1",
      dshVersion: "0.1.0-rc.6",
      publishCompletion: async (payload) => {
        attempts += 1;
        if (attempts === 1) throw new Error("inbox unavailable");
        payloads.push(payload);
      },
    });
    const handler = handlers.get("session/event");
    handler(session(), completed());
    await relay.drain();
    handler(session(), completed());
    await relay.drain();
    assert.equal(attempts, 1);
    assert.deepEqual(payloads, []);
    await relay.dispose();
    await assert.rejects(readFile(markerPath), /ENOENT/);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("publishes with private directory and file permissions", async () => {
  const root = await mkdtemp(join(tmpdir(), "cairn-dsh-publish-"));
  const inbox = join(root, "Cairn", "inbox");
  try {
    await mkdir(inbox, { recursive: true });
    await chmod(join(root, "Cairn"), 0o755);
    await chmod(inbox, 0o755);
    await publish({ result: "done" }, inbox);
    const files = await readdir(inbox);
    assert.equal(files.length, 1);
    assert.equal((await stat(join(root, "Cairn"))).mode & 0o777, 0o700);
    assert.equal((await stat(inbox)).mode & 0o777, 0o700);
    assert.equal((await stat(join(inbox, files[0]))).mode & 0o777, 0o600);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("runtime marker cleanup honors the exact lifetime owner", async () => {
  const root = await mkdtemp(join(tmpdir(), "cairn-dsh-marker-"));
  const markerPath = join(root, "runtime", "marker.json");
  try {
    await writeRuntimeMarker(markerPath, { owner: "current", pid: process.pid });
    assert.equal(await removeRuntimeMarker(markerPath, "old"), false);
    assert.equal(JSON.parse(await readFile(markerPath, "utf8")).owner, "current");
    assert.equal(await removeRuntimeMarker(markerPath, "current"), true);

    await mkdir(join(root, "runtime"), { recursive: true });
    await writeFile(markerPath, "not-json", "utf8");
    assert.equal(await removeRuntimeMarker(markerPath, "current"), false);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
