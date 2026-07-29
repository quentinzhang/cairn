import { randomUUID } from "node:crypto";
import { execFileSync } from "node:child_process";
import { mkdir, rename, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";

const RESULT_LIMIT = 50_000;
const INBOX = join(homedir(), "Library", "Application Support", "Cairn", "inbox");
const SHORTENED_SUFFIX = "\n\n… Result shortened by Cairn's OpenCode relay.";

function textFromParts(parts) {
  if (!Array.isArray(parts)) return "";
  return parts
    .filter((part) => part?.type === "text" && !part.synthetic && !part.ignored)
    .map((part) => (typeof part.text === "string" ? part.text : ""))
    .filter(Boolean)
    .join("\n")
    .trim();
}

export function completedAssistant(messages) {
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const message = messages[index];
    if (message?.info?.role !== "assistant") continue;
    const info = message.info;
    if (info.error || !info.time?.completed) return null;
    const result = textFromParts(message.parts);
    return result ? { index, info, result } : null;
  }
  return null;
}

export function previousUserMessage(messages, before) {
  for (let index = before - 1; index >= 0; index -= 1) {
    const message = messages[index];
    if (message?.info?.role === "user") return textFromParts(message.parts);
  }
  return "";
}

// OpenCode plugins run in the server process. For a directly launched TUI its
// parent chain still reaches the terminal; an externally attached `serve`
// session instead trails back only to that server process. That limitation is
// intentional and documented in docs/inbox-protocol.md's locator contract.
export function buildLocator(environment = process.env, pid = process.pid) {
  const locator = {};
  for (const [environmentKey, payloadKey] of Object.entries({
    TERM_PROGRAM: "term_program",
    TERM_SESSION_ID: "term_session_id",
    ITERM_SESSION_ID: "iterm_session_id",
    TMUX_PANE: "tmux_pane",
    WEZTERM_PANE: "wezterm_pane",
    KITTY_WINDOW_ID: "kitty_window_id",
  })) {
    const value = environment[environmentKey]?.trim();
    if (value) locator[payloadKey] = value;
  }

  try {
    locator.agent_pid = pid;
    let current = pid;
    let tty = "";
    const hostApps = [];
    for (let depth = 0; depth < 15; depth += 1) {
      const row = execFileSync("/bin/ps", ["-o", "ppid=,tty=,comm=", "-p", String(current)], {
        encoding: "utf8",
        timeout: 3000,
      }).trim();
      if (!row) break;
      const [, parentText, processTTY, command = ""] = row.match(/^(\d+)\s+(\S+)(?:\s+(.*))?$/) || [];
      const parent = Number(parentText);
      if (!parentText || !Number.isInteger(parent)) break;
      if (!tty && processTTY && processTTY !== "??") tty = processTTY;
      const marker = command.indexOf(".app/");
      if (marker !== -1 && command.includes("/Contents/MacOS/") && !command.slice(0, marker + 4).includes(".framework/")) {
        const path = command.slice(0, marker + 4);
        if (!hostApps.some((entry) => entry.path === path)) hostApps.push({ path, pid: current });
      }
      if (parent <= 1) break;
      current = parent;
    }
    if (hostApps.length) {
      locator.host_app_path = hostApps[0].path;
      locator.host_app_pid = hostApps[0].pid;
      locator.host_apps = hostApps;
    }
    if (tty) locator.tty = tty;
  } catch {
    // Locator data is optional; it must never interfere with a completion.
  }
  return locator;
}

export async function publish(payload, inbox = INBOX) {
  await mkdir(inbox, { recursive: true });
  const nonce = randomUUID().replaceAll("-", "");
  const stamp = new Date().toISOString().replaceAll(/[-:.]/g, "");
  const temporary = join(inbox, `.${nonce}.pending`);
  const destination = join(inbox, `${stamp}-${nonce}.json`);
  await writeFile(temporary, JSON.stringify(payload), "utf8");
  await rename(temporary, destination);
}

export async function relayIdle(client, sessionID, publishCompletion = publish) {
  const sessionResponse = await client.session.get({ path: { id: sessionID } });
  const session = sessionResponse?.data;
  if (!session || session.parentID) return false;

  const messagesResponse = await client.session.messages({ path: { id: sessionID } });
  const messages = messagesResponse?.data;
  if (!Array.isArray(messages)) return false;
  const assistant = completedAssistant(messages);
  if (!assistant) return false;

  let result = assistant.result;
  if (result.length > RESULT_LIMIT) {
    result = `${result.slice(0, RESULT_LIMIT - SHORTENED_SUFFIX.length)}${SHORTENED_SUFFIX}`;
  }
  const info = assistant.info;
  const payload = {
    id: `opencode:${sessionID}:${info.id}`,
    version: 1,
    event: "opencode.turn.completed",
    session_id: sessionID,
    turn_id: info.id,
    cwd: info.path?.cwd || "",
    title: "OpenCode completed",
    result,
    status: "completed",
    source: "opencode",
    platform: "cli",
    timestamp: new Date().toISOString(),
  };
  const userMessage = previousUserMessage(messages, assistant.index);
  if (userMessage) payload.user_message = userMessage;
  if (info.modelID) payload.model = info.modelID;
  const locator = buildLocator();
  if (Object.keys(locator).length) payload.locator = locator;
  await publishCompletion(payload);
  return true;
}

/**
 * OpenCode 1.18 loads local modules as PluginModule objects, rather than
 * invoking their default export as a plugin function. Keeping `server` here
 * is therefore essential: exporting the function directly makes the host run
 * it as a lifecycle hook without PluginInput, leaving `client` undefined.
 */
export default {
  id: "cairn",
  async server({ client }) {
    return {
      event({ event }) {
        if (event?.type !== "session.idle" || !event.properties?.sessionID) return;
        // OpenCode currently drops the promise returned by an event handler.
        // Own it here so SDK or filesystem failures can never become unhandled.
        void relayIdle(client, event.properties.sessionID).catch((error) => {
          console.warn(`Cairn could not publish an OpenCode completion: ${error instanceof Error ? error.message : String(error)}`);
        });
      },
    };
  },
};
