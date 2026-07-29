import assert from "node:assert/strict";
import { chmod, mkdir, mkdtemp, readdir, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { buildGatewayWebURL, publish, shouldPublishCompletion } from "./index.js";

const successfulEvent = {
  success: true,
  runId: "run-user-turn",
  messages: [],
};

test("builds the official session-level Control UI URL", () => {
  assert.equal(
    buildGatewayWebURL(18789, "agent:main:webchat:conversation-1"),
    "http://127.0.0.1:18789/chat?session=agent%3Amain%3Awebchat%3Aconversation-1",
  );
});

test("publishes a normal user-facing webchat turn", () => {
  assert.equal(
    shouldPublishCompletion(successfulEvent, {
      agentId: "main",
      sessionKey: "agent:main:webchat:conversation-1",
      messageProvider: "webchat",
    }),
    true,
  );
});

test("publishes a user-created cron completion", () => {
  assert.equal(
    shouldPublishCompletion(successfulEvent, {
      agentId: "main",
      sessionKey: "agent:main:cron:daily-report:run:2026-07-27",
      messageProvider: "cron",
    }),
    true,
  );
});

test("filters setup inference probes", () => {
  assert.equal(
    shouldPublishCompletion(
      {
        ...successfulEvent,
        runId: "probe-setup-inference-b8637298-b22f-4f41-ab2d-b7c4d55c73e5",
      },
      {
        agentId: "openclaw",
        sessionKey:
          "temp:setup-inference:probe-setup-inference-b8637298-b22f-4f41-ab2d-b7c4d55c73e5",
        messageProvider: "openclaw",
      },
    ),
    false,
  );
});

test("filters caretaker greetings and plans", () => {
  for (const runId of [
    "openclaw-greeting-11c8c543-cab5-48bd-ad0b-dfb5d8226c9e",
    "openclaw-planner-11c8c543-cab5-48bd-ad0b-dfb5d8226c9e",
  ]) {
    assert.equal(
      shouldPublishCompletion(
        { ...successfulEvent, runId },
        {
          agentId: "openclaw",
          sessionId: `${runId}-session`,
          messageProvider: "openclaw",
        },
      ),
      false,
    );
  }
});

test("filters other OpenClaw system-agent runs by semantic context", () => {
  assert.equal(
    shouldPublishCompletion(successfulEvent, {
      agentId: "openclaw",
      sessionKey: "system-agent-session",
      channel: "openclaw",
    }),
    false,
  );
});

test("does not filter a user-facing webchat solely by agent id", () => {
  assert.equal(
    shouldPublishCompletion(successfulEvent, {
      agentId: "openclaw",
      sessionKey: "agent:openclaw:webchat:conversation-1",
      messageProvider: "webchat",
    }),
    true,
  );
});

test("filters subagent intermediate completions", () => {
  assert.equal(
    shouldPublishCompletion(successfulEvent, {
      agentId: "main",
      sessionKey: "agent:main:subagent:worker-1",
      messageProvider: "webchat",
    }),
    false,
  );
});

test("filters failed or malformed lifecycle events", () => {
  assert.equal(
    shouldPublishCompletion({ ...successfulEvent, success: false }, {}),
    false,
  );
  assert.equal(
    shouldPublishCompletion({ ...successfulEvent, messages: undefined }, {}),
    false,
  );
});

test("publishes into a user-private inbox with a user-private payload", async () => {
  const root = await mkdtemp(join(tmpdir(), "cairn-openclaw-"));
  const inbox = join(root, "Cairn", "inbox");
  try {
    await mkdir(inbox, { recursive: true });
    await chmod(join(root, "Cairn"), 0o755);
    await chmod(inbox, 0o755);
    await publish({ result: "first" }, inbox);
    await publish({ result: "done" }, inbox);
    const filenames = await readdir(inbox);
    assert.equal(filenames.length, 2);
    assert.equal((await stat(join(root, "Cairn"))).mode & 0o777, 0o700);
    assert.equal((await stat(inbox)).mode & 0o777, 0o700);
    for (const filename of filenames) {
      assert.equal((await stat(join(inbox, filename))).mode & 0o777, 0o600);
    }
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
