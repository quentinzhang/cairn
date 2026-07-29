import assert from "node:assert/strict";
import test from "node:test";

import cairnPlugin, { completedAssistant, previousUserMessage, relayIdle } from "./index.js";

const user = (text) => ({ info: { role: "user" }, parts: [{ type: "text", text }] });
const assistant = (overrides = {}, parts = [{ type: "text", text: "final answer" }]) => ({
  info: {
    id: "turn-1", role: "assistant", time: { created: 1, completed: 2 },
    path: { cwd: "/tmp/cairn", root: "/tmp/cairn" }, modelID: "gpt-test", ...overrides,
  },
  parts,
});

test("extracts only non-synthetic final text and its preceding user message", () => {
  const messages = [user("first prompt"), assistant({}, [
    { type: "reasoning", text: "private" },
    { type: "text", text: "hidden", synthetic: true },
    { type: "text", text: "visible" },
    { type: "text", text: "ignored", ignored: true },
  ])];
  const final = completedAssistant(messages);
  assert.equal(final.result, "visible");
  assert.equal(previousUserMessage(messages, final.index), "first prompt");
});

test("does not publish unfinished or failed assistant messages", () => {
  assert.equal(completedAssistant([assistant({ time: { created: 1 } })]), null);
  assert.equal(completedAssistant([assistant({ error: { name: "UnknownError" } })]), null);
});

test("relays a completed top-level session with mapped fields", async () => {
  const messages = [user("ship it"), assistant({ id: "turn-9", modelID: "model-9" })];
  const client = { session: {
    get: async () => ({ data: { id: "session-9" } }),
    messages: async () => ({ data: messages }),
  } };
  let published;
  assert.equal(await relayIdle(client, "session-9", async (payload) => { published = payload; }), true);
  assert.deepEqual(
    { source: published.source, result: published.result, session: published.session_id, turn: published.turn_id, cwd: published.cwd, model: published.model, user: published.user_message },
    { source: "opencode", result: "final answer", session: "session-9", turn: "turn-9", cwd: "/tmp/cairn", model: "model-9", user: "ship it" },
  );
});

test("skips idle events from child sessions", async () => {
  const client = { session: {
    get: async () => ({ data: { parentID: "parent" } }),
    messages: async () => { throw new Error("must not query child messages"); },
  } };
  assert.equal(await relayIdle(client, "child", async () => assert.fail("must not publish")), false);
});

test("keeps a shortened result within the inbox protocol limit", async () => {
  const client = { session: {
    get: async () => ({ data: {} }),
    messages: async () => ({ data: [assistant({}, [{ type: "text", text: "x".repeat(50_100) }])] }),
  } };
  let published;
  await relayIdle(client, "session", async (payload) => { published = payload; });
  assert.equal(published.result.length, 50_000);
  assert.match(published.result, /Result shortened by Cairn's OpenCode relay\.$/);
});

test("exports the OpenCode PluginModule server entrypoint", async () => {
  const hooks = await cairnPlugin.server({ client: { session: {} } });
  assert.equal(cairnPlugin.id, "cairn");
  assert.equal(typeof hooks.event, "function");
});
