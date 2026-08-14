import { randomUUID } from "node:crypto";
import { chmod, mkdir, readFile, rename, unlink, writeFile } from "node:fs/promises";
import { readFileSync, realpathSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export const name = "cairn-completion-relay";
export const inject = ["sessions", "webServer"];

export const PLUGIN_VERSION = "0.1.0";
const RESULT_LIMIT = 50_000;
const SHORTENED_SUFFIX = "\n\n… Result shortened by Cairn's DeepSeek Harness relay.";
const LOOPBACK_HOST = "127.0.0.1";
const BUNDLE_PATH = resolve(fileURLToPath(new URL(".", import.meta.url)));

function dshHome(environment = process.env) {
  const configured = environment.DSH_HOME?.trim();
  return configured ? resolve(configured) : join(homedir(), ".dsh");
}

function defaultInbox() {
  return join(homedir(), "Library", "Application Support", "Cairn", "inbox");
}

function defaultMarkerPath(environment = process.env) {
  return join(dshHome(environment), "runtime", "cairn-deepseek-harness.json");
}

function packageVersionAt(path) {
  try {
    const value = JSON.parse(readFileSync(path, "utf8"));
    return value?.name === "@deepseek-ai/dsh" && typeof value.version === "string"
      ? value.version
      : "";
  } catch {
    return "";
  }
}

/** Resolve the actual host version without importing or depending on dsh. */
export function resolveDshVersion(entry = process.argv[1] || "") {
  let resolvedEntry = entry ? resolve(entry) : "";
  try {
    resolvedEntry = resolvedEntry ? realpathSync(resolvedEntry) : "";
  } catch {
    // A non-filesystem argv is harmless; the version gate remains "unknown".
  }
  let directory = resolvedEntry ? dirname(resolvedEntry) : "";
  for (let depth = 0; directory && depth < 8; depth += 1) {
    const version = packageVersionAt(join(directory, "package.json"));
    if (version) return version;
    const parent = dirname(directory);
    if (parent === directory) break;
    directory = parent;
  }
  return "unknown";
}

function textFromContent(content) {
  if (!Array.isArray(content)) return "";
  return content
    .filter((block) => block?.type === "text" && typeof block.text === "string")
    .map((block) => block.text)
    .join("\n")
    .trim();
}

function turnEvents(session, terminalEvent) {
  const events = Array.isArray(session?.events) ? session.events : [];
  let end = events.findIndex((candidate) => candidate?.seq === terminalEvent?.seq);
  if (end < 0) end = events.length - 1;
  let start = -1;
  for (let index = end; index >= 0; index -= 1) {
    const candidate = events[index];
    if (candidate?.type === "turn/start" && candidate.data?.turn === terminalEvent.data.turn) {
      start = index;
      break;
    }
  }
  return events.slice(start + 1, end + 1);
}

function finalAssistant(events, turn) {
  for (let index = events.length - 1; index >= 0; index -= 1) {
    const event = events[index];
    if (event?.type !== "assistant/message" || event.data?.turn !== turn) continue;
    const result = textFromContent(event.data.message?.content);
    if (!result) continue;
    const source = event.data.message?.source;
    return {
      result,
      model: source?.kind === "model" && typeof source.model === "string"
        ? source.model.trim()
        : "",
    };
  }
  return null;
}

function latestHumanMessage(events) {
  for (let index = events.length - 1; index >= 0; index -= 1) {
    const event = events[index];
    if (event?.type !== "user/message" || event.data?.source?.kind !== "user") continue;
    const text = textFromContent(event.data.content);
    if (text) return text;
  }
  return "";
}

export function isTopLevelCompletedTurn(session, event) {
  if (event?.type !== "turn/end" || event.data?.reason?.kind !== "completed") return false;
  const header = session?.header || {};
  return header.origin !== "subagent"
    && header.parentSession === undefined
    && !(Number.isFinite(header.delegationDepth) && header.delegationDepth > 0);
}

/** Build the deliberately small Inbox Protocol v1 projection of one turn. */
export function completionPayload(session, event, webPort) {
  if (!isTopLevelCompletedTurn(session, event)) return null;
  const events = turnEvents(session, event);
  const assistant = finalAssistant(events, event.data.turn);
  if (!assistant) return null;

  let result = assistant.result;
  if (result.length > RESULT_LIMIT) {
    result = `${result.slice(0, RESULT_LIMIT - SHORTENED_SUFFIX.length)}${SHORTENED_SUFFIX}`;
  }
  const sessionID = typeof session.id === "string" ? session.id : session.header?.id;
  if (!sessionID) return null;
  const turnID = String(event.data.turn);
  const cwd = typeof session.header?.cwd === "string" ? session.header.cwd : "";
  const workspace = basename(cwd) || "Agent";
  const eventTime = Number.isFinite(event.time) ? new Date(event.time) : new Date();
  const payload = {
    id: `${sessionID}:${turnID}`,
    version: 1,
    event: "deepseek-harness.turn.completed",
    session_id: sessionID,
    turn_id: turnID,
    cwd,
    title: `DeepSeek Harness completed · ${workspace}`,
    result,
    status: "completed",
    source: "deepseek-harness",
    platform: "web",
    timestamp: eventTime.toISOString(),
    locator: { web_url: `http://${LOOPBACK_HOST}:${String(webPort)}/` },
  };
  const userMessage = latestHumanMessage(events);
  if (userMessage) payload.user_message = userMessage;
  if (assistant.model) payload.model = assistant.model;
  return payload;
}

export async function publish(payload, inbox = defaultInbox()) {
  const support = dirname(inbox);
  await mkdir(support, { recursive: true, mode: 0o700 });
  await chmod(support, 0o700);
  await mkdir(inbox, { recursive: true, mode: 0o700 });
  await chmod(inbox, 0o700);
  const nonce = randomUUID().replaceAll("-", "");
  const stamp = new Date().toISOString().replaceAll(/[-:.]/g, "").replace("Z", "000Z");
  const temporary = join(inbox, `.${nonce}.pending`);
  const destination = join(inbox, `${stamp}-${nonce}.json`);
  await writeFile(temporary, JSON.stringify(payload), {
    encoding: "utf8",
    flag: "wx",
    mode: 0o600,
  });
  await chmod(temporary, 0o600);
  await rename(temporary, destination);
}

export async function writeRuntimeMarker(markerPath, marker) {
  const directory = dirname(markerPath);
  await mkdir(directory, { recursive: true, mode: 0o700 });
  await chmod(directory, 0o700);
  const temporary = join(directory, `.${randomUUID().replaceAll("-", "")}.pending`);
  await writeFile(temporary, JSON.stringify(marker), {
    encoding: "utf8",
    flag: "wx",
    mode: 0o600,
  });
  await chmod(temporary, 0o600);
  await rename(temporary, markerPath);
  await chmod(markerPath, 0o600);
}

/** Remove only the marker written by this exact plugin lifetime. */
export async function removeRuntimeMarker(markerPath, owner) {
  try {
    const marker = JSON.parse(await readFile(markerPath, "utf8"));
    if (marker?.owner !== owner) return false;
    await unlink(markerPath);
    return true;
  } catch (error) {
    if (error?.code === "ENOENT" || error instanceof SyntaxError) return false;
    throw error;
  }
}

function warn(error) {
  const detail = error instanceof Error ? error.message : String(error);
  console.warn(`Cairn could not publish a DeepSeek Harness completion: ${detail}`);
}

/**
 * Own the event queue and marker lifecycle. Exposed so the host contract can
 * be tested without booting a second Harness process.
 */
export function createRelay(ctx, options = {}) {
  const publishCompletion = options.publishCompletion || publish;
  const markerPath = options.markerPath || defaultMarkerPath();
  const owner = options.owner || randomUUID();
  const now = options.now || (() => new Date());
  const seen = new Set();
  let queue = Promise.resolve();

  const enqueue = (operation) => {
    queue = queue.then(operation).catch(warn);
  };

  const marker = {
    schema: 1,
    plugin: "@cairn/deepseek-harness-plugin",
    plugin_version: PLUGIN_VERSION,
    dsh_version: options.dshVersion || resolveDshVersion(),
    pid: process.pid,
    port: ctx.webServer.port,
    started_at: now().toISOString(),
    owner,
    bundle_path: BUNDLE_PATH,
  };
  enqueue(() => writeRuntimeMarker(markerPath, marker));

  const handle = (session, event) => {
    try {
      const payload = completionPayload(session, event, ctx.webServer.port);
      if (!payload || seen.has(payload.id)) return;
      seen.add(payload.id);
      if (seen.size > 1024) seen.delete(seen.values().next().value);
      enqueue(() => publishCompletion(payload));
    } catch (error) {
      warn(error);
    }
  };
  ctx.on("session/event", handle);

  const dispose = async () => {
    await queue;
    try {
      await removeRuntimeMarker(markerPath, owner);
    } catch (error) {
      warn(error);
    }
  };
  return { handle, drain: () => queue, dispose, marker };
}

export function apply(ctx) {
  const relay = createRelay(ctx);
  ctx.effect(() => relay.dispose, "cairn: runtime marker");
}
