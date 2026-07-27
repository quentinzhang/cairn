import { randomUUID } from "node:crypto";
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, join } from "node:path";

const RESULT_LIMIT = 50_000;
const inbox = join(homedir(), "Library", "Application Support", "Cairn", "inbox");
const INTERNAL_RUN_PREFIXES = [
  "probe-setup-inference-",
  "openclaw-greeting-",
  "openclaw-planner-",
];

function normalized(value) {
  return typeof value === "string" ? value.trim().toLowerCase() : "";
}

function hasInternalRunPrefix(value) {
  const candidate = normalized(value);
  return INTERNAL_RUN_PREFIXES.some((prefix) => candidate.startsWith(prefix));
}

function isSubagentSession(value) {
  return /(^|:)subagent:/i.test(typeof value === "string" ? value.trim() : "");
}

/**
 * `agent_end` is a model-run lifecycle hook, not a user-visible completion
 * hook. OpenClaw also emits it for setup probes, caretaker greetings/plans,
 * and subagents. Cairn should publish only top-level turns that a user could
 * reasonably be waiting to resume.
 */
export function shouldPublishCompletion(event, context = {}) {
  if (!event?.success || !Array.isArray(event.messages)) {
    return false;
  }

  const runID = event.runId || context.runId;
  const sessionKey = context.sessionKey;
  const sessionID = context.sessionId;
  if (
    normalized(sessionKey).startsWith("temp:setup-inference:") ||
    hasInternalRunPrefix(runID) ||
    hasInternalRunPrefix(sessionID) ||
    isSubagentSession(sessionKey)
  ) {
    return false;
  }

  const isSystemAgent = normalized(context.agentId) === "openclaw";
  const isSystemSurface =
    normalized(context.channel) === "openclaw" ||
    normalized(context.messageProvider) === "openclaw";
  return !(isSystemAgent && isSystemSurface);
}

function asMessage(value) {
  if (!value || typeof value !== "object") {
    return null;
  }
  const nested = value.message;
  return nested && typeof nested === "object" ? nested : value;
}

function textFromContent(content) {
  if (typeof content === "string") {
    return content.trim();
  }
  if (!Array.isArray(content)) {
    return "";
  }
  const textBlocks = content.filter(
    (block) =>
      block &&
      typeof block === "object" &&
      (block.type === "text" || block.type === "output_text") &&
      typeof block.text === "string",
  );
  const finalBlocks = textBlocks.filter((block) => block.phase === "final_answer");
  return (finalBlocks.length > 0 ? finalBlocks : textBlocks)
    .map((block) => block.text)
    .join("\n")
    .trim();
}

function latestMessage(messages, expectedRole) {
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const message = asMessage(messages[index]);
    if (message?.role !== expectedRole) {
      continue;
    }
    const text = textFromContent(message.content);
    if (text) {
      return text;
    }
  }
  return "";
}

function titleFor(context) {
  const surface = context.channel || context.messageProvider;
  if (surface) {
    return `OpenClaw completed · ${surface}`;
  }
  const workspace = context.workspaceDir ? basename(context.workspaceDir) : "";
  return `OpenClaw completed · ${workspace || "Agent"}`;
}

function modelFor(context) {
  if (context.modelProviderId && context.modelId) {
    return `${context.modelProviderId}/${context.modelId}`;
  }
  return context.modelId || context.modelProviderId || "";
}

export function buildGatewayWebURL(port, sessionKey) {
  const url = new URL(`http://127.0.0.1:${port}/chat`);
  if (sessionKey) {
    url.searchParams.set("session", sessionKey);
  }
  return url.toString();
}

// OpenClaw conversations surface in a browser tab (webchat) or a chat app —
// there is no local window to trail back to. Capture the official Control UI
// session route so a click on the note can navigate an existing OpenClaw tab
// to the exact conversation without injecting code into the page.
async function gatewayWebURL(sessionKey) {
  try {
    const raw = await readFile(join(homedir(), ".openclaw", "openclaw.json"), "utf8");
    const port = JSON.parse(raw)?.gateway?.port ?? 18789;
    return buildGatewayWebURL(port, sessionKey);
  } catch {
    return buildGatewayWebURL(18789, sessionKey);
  }
}

async function publish(payload) {
  await mkdir(inbox, { recursive: true });
  const nonce = randomUUID().replaceAll("-", "");
  const stamp = new Date().toISOString().replaceAll(/[-:.]/g, "");
  const temporary = join(inbox, `.${nonce}.pending`);
  const destination = join(inbox, `${stamp}-${nonce}.json`);
  await writeFile(temporary, JSON.stringify(payload), { encoding: "utf8" });
  await rename(temporary, destination);
}

export default {
  id: "cairn",
  name: "Cairn Completion Relay",
  description: "Deliver completed OpenClaw turns to the local Cairn macOS inbox.",
  register(api) {
    api.on(
      "agent_end",
      async (event, context) => {
        try {
          if (!shouldPublishCompletion(event, context)) {
            return;
          }
          let result = latestMessage(event.messages, "assistant");
          if (!result) {
            return;
          }
          if (result.length > RESULT_LIMIT) {
            result =
              result.slice(0, RESULT_LIMIT) +
              "\n\n… Result shortened by Cairn's OpenClaw relay.";
          }

          const turnID = event.runId || context.runId || randomUUID();
          const sessionID =
            context.sessionKey || context.sessionId || event.runId || `openclaw-${turnID}`;
          const payload = {
            id: `${sessionID}:${turnID}`,
            version: 1,
            event: "openclaw.turn.completed",
            session_id: sessionID,
            turn_id: turnID,
            cwd: context.workspaceDir || "",
            title: titleFor(context),
            result,
            status: "completed",
            source: "openclaw",
            platform: context.channel || context.messageProvider || "agent",
            timestamp: new Date().toISOString(),
          };
          const userMessage = latestMessage(event.messages, "user");
          if (userMessage) {
            payload.user_message = userMessage;
          }
          const model = modelFor(context);
          if (model) {
            payload.model = model;
          }
          payload.locator = { web_url: await gatewayWebURL(sessionID) };
          await publish(payload);
        } catch (error) {
          api.logger.warn(
            `Cairn could not publish an OpenClaw completion: ${
              error instanceof Error ? error.message : String(error)
            }`,
          );
        }
      },
      { timeoutMs: 5_000 },
    );
  },
};
