#!/usr/bin/env node
// Copilot Mission Table companion: bridges the GitHub Copilot app and the WoW addon.
//   app -> WoW:  writes Interface/AddOns/CopilotMissionTable/Inbox.lua (picked up on /reload)
//   WoW -> app:  reads WTF/Account/*/SavedVariables/CopilotMissionTable.lua (written on /reload)

import { randomUUID } from "node:crypto";
import {
	cpSync,
	existsSync,
	mkdirSync,
	openSync,
	readdirSync,
	readFileSync,
	readSync,
	closeSync,
	renameSync,
	statSync,
	unwatchFile,
	watchFile,
	writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { CombatLog } from "./combat.mjs";
import { fetchGithub } from "./github.mjs";
import { parseSavedVariables, sanitizeForWow, toLua } from "./lua.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const ADDON_NAME = "CopilotMissionTable";
const COPILOT_HOME = process.env.COPILOT_HOME || join(homedir(), ".copilot");
const STATE_DIR = join(homedir(), ".copilot-mission-table");
const CONFIG_FILE = join(STATE_DIR, "config.json");
const STATE_FILE = join(STATE_DIR, "state.json");
const MAX_IDLE_SESSIONS = 20;
const SEND_TIMEOUT_MS = 8000;

const args = process.argv.slice(2);
const command = args[0] && !args[0].startsWith("--") ? args[0] : "run";
const flag = (name) => {
	const i = args.indexOf(`--${name}`);
	return i >= 0 ? args[i + 1] : undefined;
};

const log = (...parts) =>
	console.log(`\x1b[33m[mission-table ${new Date().toLocaleTimeString()}]\x1b[0m`, ...parts);

// ---------- config ----------

function loadJson(file, fallback) {
	try {
		return JSON.parse(readFileSync(file, "utf8"));
	} catch {
		return fallback;
	}
}

function saveJson(file, value) {
	mkdirSync(dirname(file), { recursive: true });
	const tmp = `${file}.tmp`;
	writeFileSync(tmp, JSON.stringify(value, null, 2));
	renameSync(tmp, file);
}

function resolveWowRoot() {
	const config = loadJson(CONFIG_FILE, {});
	const explicit = flag("wow") || process.env.WOW_PATH || config.wowPath;
	const flavor = flag("flavor") || config.flavor || "_retail_";
	const candidates = explicit
		? [explicit, join(explicit, flavor)]
		: [
				join("/Applications/World of Warcraft", flavor),
				join(homedir(), "Applications/World of Warcraft", flavor),
				join("C:/Program Files (x86)/World of Warcraft", flavor),
				join("C:/Program Files/World of Warcraft", flavor),
			];
	const root = candidates.find((c) => existsSync(join(c, "Interface")) || existsSync(join(c, "WTF")));
	if (!root) {
		console.error(
			`Couldn't find World of Warcraft (${flavor}). Pass --wow "/path/to/World of Warcraft" (and --flavor _classic_ etc.).`,
		);
		process.exit(1);
	}
	if (flag("wow")) saveJson(CONFIG_FILE, { ...config, wowPath: root, flavor });
	return resolve(root);
}

// ---------- install ----------

function install(wowRoot) {
	const src = join(HERE, "..", "addon", ADDON_NAME);
	const dest = join(wowRoot, "Interface", "AddOns", ADDON_NAME);
	mkdirSync(dest, { recursive: true });
	for (const file of readdirSync(src)) {
		if (file === "Inbox.lua" && existsSync(join(dest, file))) continue;
		cpSync(join(src, file), join(dest, file), { recursive: true });
	}
	log(`Installed addon to ${dest}`);
	log("Restart WoW once (new addon files are only discovered at client start), then /reload works.");
}

// ---------- app connection ----------

function readRunFile(name) {
	try {
		return readFileSync(join(COPILOT_HOME, "run", name), "utf8").split("\n")[0].trim();
	} catch {
		return undefined;
	}
}

function appEndpoint() {
	for (const [portFile, tokenFile] of [
		["ws.release.port", "ws.release.token"],
		["ws.port", "ws.token"],
	]) {
		const port = readRunFile(portFile);
		const token = readRunFile(tokenFile);
		if (port && token) return { port, token };
	}
	return undefined;
}

function socketUrl({ port, token }, observer) {
	const url = new URL(`ws://127.0.0.1:${port}/`);
	url.searchParams.set("token", token);
	if (observer) url.searchParams.set("observer", "1");
	return url.toString();
}

// ---------- session model ----------

const state = loadJson(STATE_FILE, { sent: {}, questions: {} });
state.sent ??= {};
state.questions ??= {};
state.stats ??= { toolCalls: 0, turns: 0, misses: 0 };
const combat = new CombatLog(state.combat ?? []);
let github = { loot: [], bosses: [] };
const sessions = new Map();
const aliases = new Map();
let commander;
let connected = false;
let dirty = true;

const persistState = () => {
	const sentIds = Object.keys(state.sent);
	if (sentIds.length > 500) {
		for (const id of sentIds.slice(0, sentIds.length - 500)) delete state.sent[id];
	}
	state.combat = combat.entries;
	saveJson(STATE_FILE, state);
};

function canonicalId(id) {
	return aliases.get(id) ?? id;
}

function upsertWorkspace(w) {
	const id = w.session?.sessionId || w.activeSessionId;
	if (!id) return;
	for (const alias of w.sessionAliases ?? []) {
		const aliasId = typeof alias === "string" ? alias : alias?.sessionId ?? alias?.id;
		if (aliasId && aliasId !== id) aliases.set(aliasId, id);
	}
	const existing = sessions.get(id);
	const s = existing ?? {
		id,
		status: "idle",
		lastMessage: "",
		seeded: false,
	};
	s.workspaceId = w.id;
	s.name = w.name || w.session?.title || "Unnamed mission";
	s.project = w.projectName || "";
	s.branch = w.branch || "";
	s.updatedAt = Date.parse(w.updatedAt || w.session?.updatedAt || "") || s.updatedAt || 0;
	s.archived = Boolean(w.archivedAt);
	s.model = w.session?.model ?? s.model;
	const cw = w.session?.contextWindow;
	if (cw?.tokenLimit) s.context = cw.currentTokens / cw.tokenLimit;
	if (w.session?.wasInterrupted && s.status !== "busy") s.status = "interrupted";
	sessions.set(id, s);
	if (!s.seeded) seedFromDisk(s);
	dirty = true;
}

// The live stream starts empty, so recover recent status and the last report from disk.
function seedFromDisk(s) {
	s.seeded = true;
	const file = join(COPILOT_HOME, "session-state", s.id, "events.jsonl");
	let text;
	let mtime;
	try {
		const { size, mtimeMs } = statSync(file);
		mtime = mtimeMs;
		const length = Math.min(size, 256 * 1024);
		const buf = Buffer.alloc(length);
		const fd = openSync(file, "r");
		readSync(fd, buf, 0, length, size - length);
		closeSync(fd);
		text = buf.toString("utf8");
	} catch {
		return;
	}
	let lastMarker;
	let lastMarkerAt = 0;
	for (const line of text.split("\n")) {
		if (!line.startsWith("{")) continue;
		let ev;
		try {
			ev = JSON.parse(line);
		} catch {
			continue;
		}
		if (ev.type === "assistant.message" && ev.data?.content?.trim()) {
			s.lastMessage = ev.data.content;
			s.lastMessageAt = Date.parse(ev.timestamp) || 0;
		}
		if (
			[
				"user.message",
				"assistant.turn_start",
				"assistant.turn_end",
				"session.shutdown",
				"session.task_complete",
				"session.resume",
			].includes(ev.type)
		) {
			lastMarker = ev.type;
			lastMarkerAt = Date.parse(ev.timestamp) || lastMarkerAt;
		}
	}
	const recentlyActive = Date.now() - mtime < 20_000;
	const midTurn = lastMarker === "user.message" || lastMarker === "assistant.turn_start";
	if (recentlyActive || (midTurn && Date.now() - mtime < 5 * 60_000)) {
		s.status = "busy";
		s.busySince = lastMarkerAt || mtime;
	}
	const pending = state.questions[s.id];
	if (pending) {
		s.question = pending;
		s.status = "input";
	}
	dirty = true;
}

function setStatus(s, status) {
	if (s.status === status) return;
	if (status === "busy") s.busySince = Date.now();
	if (s.status === "busy" && status !== "busy") s.lastFinishedAt = Date.now();
	s.status = status;
	dirty = true;
}

function onSessionEvent(sessionId, ev) {
	const s = sessions.get(canonicalId(sessionId));
	if (!s) return;
	s.updatedAt = Date.now();
	if (combat.onEvent(s, ev)) dirty = true;
	if (ev.type === "tool.execution_complete") {
		state.stats.toolCalls++;
		if (ev.data?.success === false) state.stats.misses++;
	}
	if (ev.type === "assistant.turn_end") state.stats.turns++;
	switch (ev.type) {
		case "user.message":
		case "assistant.turn_start":
		case "tool.execution_start":
			if (!s.question) setStatus(s, "busy");
			break;
		case "session.idle":
			if (!s.question) setStatus(s, "idle");
			break;
		case "abort":
			setStatus(s, "interrupted");
			break;
		case "session.error":
			setStatus(s, "error");
			s.lastError = ev.data?.message;
			break;
		case "assistant.message":
			if (ev.data?.content?.trim()) {
				s.lastMessage = ev.data.content;
				s.lastMessageAt = Date.now();
				dirty = true;
			}
			break;
		case "session.usage_info":
			if (ev.data?.tokenLimit) {
				s.context = ev.data.currentTokens / ev.data.tokenLimit;
				dirty = true;
			}
			break;
		case "session.title_changed":
			if (ev.data?.title) s.name = ev.data.title;
			break;
		case "permission.requested":
			s.permissionPending = true;
			setStatus(s, "input");
			break;
		case "permission.completed":
			s.permissionPending = false;
			if (!s.question) setStatus(s, "busy");
			break;
	}
}

function onQuestion(msg) {
	const s = sessions.get(canonicalId(msg.session_id));
	if (!s) return;
	s.question = {
		requestId: msg.request_id,
		questionId: msg.question_id,
		text: msg.question,
		choices: msg.choices ?? [],
		freeform: msg.allow_freeform !== false,
	};
	state.questions[s.id] = s.question;
	persistState();
	setStatus(s, "input");
	dirty = true;
	log(`Quest available: ${s.name}: ${msg.question.slice(0, 80)}`);
}

function onQuestionResolved(msg) {
	const s = sessions.get(canonicalId(msg.session_id));
	if (!s || s.question?.requestId !== msg.request_id) return;
	s.question = undefined;
	delete state.questions[s.id];
	persistState();
	setStatus(s, "busy");
	dirty = true;
}

// ---------- observer socket ----------

let observer;
function connectObserver() {
	const endpoint = appEndpoint();
	if (!endpoint) {
		setConnected(false);
		setTimeout(connectObserver, 5000);
		return;
	}
	const ws = new WebSocket(socketUrl(endpoint, true));
	observer = ws;
	ws.onopen = () => {
		setConnected(true);
		log(`Connected to the Copilot app on port ${endpoint.port}`);
		ws.send(JSON.stringify({ type: "list_workspaces", request_id: `cmt-${Date.now()}` }));
	};
	ws.onmessage = (event) => {
		let msg;
		try {
			msg = JSON.parse(String(event.data));
		} catch {
			return;
		}
		switch (msg.type) {
			case "workspace_list":
				for (const w of msg.workspaces) upsertWorkspace(w);
				break;
			case "workspace_detail":
				if (msg.workspace) upsertWorkspace(msg.workspace);
				break;
			case "workspace_activity_updated":
				if (msg.name) {
					for (const s of sessions.values()) {
						if (s.workspaceId === msg.workspace_id) {
							s.name = msg.name;
							dirty = true;
						}
					}
				}
				break;
			case "session_event":
				onSessionEvent(msg.session_id, msg.event);
				break;
			case "user_input_request":
				onQuestion(msg);
				break;
			case "user_input_resolved":
				onQuestionResolved(msg);
				break;
			case "github_auth_success":
				commander = msg.user?.login ?? commander;
				dirty = true;
				break;
		}
	};
	ws.onclose = () => {
		if (observer !== ws) return;
		setConnected(false);
		log("Lost the Copilot app; retrying in 5s");
		setTimeout(connectObserver, 5000);
	};
	ws.onerror = () => {};
}

// The app's own list refresh keeps names, branches and new sessions current.
function startWorkspaceRefresh() {
	setInterval(() => {
		if (observer?.readyState === WebSocket.OPEN) {
			observer.send(JSON.stringify({ type: "list_workspaces", request_id: `cmt-${Date.now()}` }));
		}
	}, 60_000);
}

function setConnected(value) {
	if (connected !== value) dirty = true;
	connected = value;
}

// ---------- steering ----------

function sendToApp(order) {
	return new Promise((resolveSend) => {
		const endpoint = appEndpoint();
		if (!endpoint) {
			resolveSend({ ok: false, error: "Copilot app isn't running" });
			return;
		}
		const sessionId = canonicalId(order.sessionId);
		const ws = new WebSocket(socketUrl(endpoint, false));
		const requestId = `wow-${randomUUID()}`;
		let settled = false;
		const finish = (result) => {
			if (settled) return;
			settled = true;
			clearTimeout(timer);
			try {
				ws.close();
			} catch {}
			resolveSend(result);
		};
		// No explicit ack exists for send_message; the echoed user.message is the receipt.
		const timer = setTimeout(() => finish({ ok: true, unconfirmed: true }), SEND_TIMEOUT_MS);
		ws.onopen = () => {
			if (order.kind === "answer") {
				const s = sessions.get(sessionId);
				const q = s?.question;
				ws.send(
					JSON.stringify({
						type: "respond_to_user_input",
						session_id: sessionId,
						request_id: order.requestId,
						answer: order.text,
						was_freeform: !(q?.choices ?? []).includes(order.text),
						question_id: q?.questionId,
						question: q?.text,
						choices: q?.choices,
						allow_freeform: q?.freeform,
					}),
				);
				setTimeout(() => finish({ ok: true }), 1500);
			} else {
				ws.send(
					JSON.stringify({
						type: "send_message",
						session_id: sessionId,
						prompt: order.text,
						delivery_mode: order.mode === "immediate" ? "immediate" : "enqueue",
						request_id: requestId,
					}),
				);
			}
		};
		ws.onmessage = (event) => {
			let msg;
			try {
				msg = JSON.parse(String(event.data));
			} catch {
				return;
			}
			if (msg.type === "error" && (!msg.request_id || msg.request_id === requestId)) {
				finish({ ok: false, error: msg.message || msg.error || "The app rejected the order" });
			}
			if (
				msg.type === "session_event" &&
				canonicalId(msg.session_id) === sessionId &&
				msg.event?.type === "user.message" &&
				msg.event.data?.content?.includes(order.text.slice(0, 40))
			) {
				finish({ ok: true });
			}
		};
		ws.onerror = () => finish({ ok: false, error: "Couldn't reach the Copilot app" });
	});
}

async function processOutbox(file) {
	let db;
	try {
		db = parseSavedVariables(readFileSync(file, "utf8")).CopilotMissionTableDB;
	} catch (error) {
		log(`Couldn't read ${file}: ${error.message}`);
		return;
	}
	const outbox = Array.isArray(db?.outbox) ? db.outbox : [];
	for (const order of outbox) {
		if (!order?.id || state.sent[order.id] || typeof order.text !== "string" || !order.sessionId) continue;
		// WoW edit boxes escape a typed "|" as "||".
		order.text = order.text.replace(/\|\|/g, "|");
		const target = sessions.get(canonicalId(order.sessionId));
		log(`Courier dispatched to "${target?.name ?? order.sessionId}": ${order.text.slice(0, 80)}`);
		const result = await sendToApp(order);
		state.sent[order.id] = { at: Date.now(), ok: result.ok, error: result.error };
		persistState();
		if (result.ok && order.kind === "answer" && target) {
			target.question = undefined;
			delete state.questions[target.id];
			persistState();
			setStatus(target, "busy");
		}
		log(result.ok ? "  delivered" : `  failed: ${result.error}`);
		dirty = true;
	}
}

// ---------- WoW files ----------

function savedVariablesFiles(wowRoot) {
	const accounts = join(wowRoot, "WTF", "Account");
	if (!existsSync(accounts)) return [];
	return readdirSync(accounts)
		.map((a) => join(accounts, a, "SavedVariables", `${ADDON_NAME}.lua`))
		.filter((f) => existsSync(f));
}

const watched = new Set();
function watchSavedVariables(wowRoot) {
	for (const file of savedVariablesFiles(wowRoot)) {
		if (watched.has(file)) continue;
		watched.add(file);
		log(`Watching ${file}`);
		watchFile(file, { interval: 1000 }, (cur, prev) => {
			if (cur.mtimeMs !== prev.mtimeMs) processOutbox(file);
		});
		processOutbox(file);
	}
}

const STATUS_ORDER = { input: 0, error: 1, busy: 2, interrupted: 3, idle: 4 };

function inboxPayload() {
	const live = [...sessions.values()].filter((s) => !s.archived);
	const attention = live.filter((s) => s.status !== "idle");
	const idle = live
		.filter((s) => s.status === "idle")
		.sort((a, b) => b.updatedAt - a.updatedAt)
		.slice(0, MAX_IDLE_SESSIONS);
	const list = [...attention, ...idle].sort(
		(a, b) => STATUS_ORDER[a.status] - STATUS_ORDER[b.status] || b.updatedAt - a.updatedAt,
	);
	const acked = {};
	const failed = {};
	for (const [id, r] of Object.entries(state.sent)) {
		if (r.ok) acked[id] = true;
		else failed[id] = sanitizeForWow(r.error ?? "failed", 120);
	}
	const sec = (ms) => (ms ? Math.floor(ms / 1000) : undefined);
	const byBranch = new Map(live.map((s) => [s.branch, s.id]));
	return {
		version: 2,
		generatedAt: sec(Date.now()),
		connected,
		commander: commander ?? "Commander",
		acked,
		failed,
		stats: { ...state.stats },
		loot: github.loot,
		bosses: github.bosses.map((b) => ({ ...b, sessionId: byBranch.get(b.branch) })),
		defeated: state.defeated ?? [],
		combat: combat.entries.slice(-80),
		sessions: list.map((s) => ({
			id: s.id,
			name: sanitizeForWow(s.name, 80),
			project: sanitizeForWow(s.project, 40),
			branch: sanitizeForWow(s.branch, 60),
			status: s.status,
			busySince: s.status === "busy" ? sec(s.busySince) : undefined,
			updatedAt: sec(s.updatedAt),
			lastFinishedAt: sec(s.lastFinishedAt),
			lastMessage: sanitizeForWow(s.lastMessage || s.lastError || "", 1500),
			context: s.context ? Math.round(s.context * 1000) / 1000 : undefined,
			model: s.model,
			permission: s.permissionPending || undefined,
			question: s.question
				? {
						requestId: s.question.requestId,
						text: sanitizeForWow(s.question.text, 600),
						choices: (s.question.choices ?? []).map((c) => sanitizeForWow(c, 120)),
						rawChoices: s.question.choices ?? [],
						freeform: s.question.freeform,
					}
				: undefined,
		})),
	};
}

function writeInbox(wowRoot) {
	const dest = join(wowRoot, "Interface", "AddOns", ADDON_NAME, "Inbox.lua");
	if (!existsSync(dirname(dest))) return;
	const body = `-- Written by the Copilot Mission Table companion. Do not edit.\nCopilotMissionTable_Inbox = ${toLua(inboxPayload())}\n`;
	const tmp = `${dest}.tmp`;
	writeFileSync(tmp, body);
	renameSync(tmp, dest);
}

// ---------- main ----------

function printBanner() {
	console.log(`\x1b[36m
   ___            _ _     _     __  __ _         _
  / __|___ _ __ _(_) |___| |_  |  \\/  (_)_ _____(_)___ _ _
 | (__/ _ \\ '_ \\ | | / _ \\  _| | |\\/| | (_-<_-<| / _ \\ ' \\
  \\___\\___/ .__/_|_|_\\___/\\__| |_|  |_|_/__/__/|_\\___/_||_|
          |_|              T A B L E   C O M P A N I O N
\x1b[0m`);
}

function startGithubPolling() {
	const poll = async () => {
		try {
			github = await fetchGithub(state);
			persistState();
			dirty = true;
		} catch (error) {
			log(`GitHub scouting failed (is gh signed in?): ${String(error.message).split("\n")[0]}`);
		}
	};
	poll();
	setInterval(poll, 3 * 60_000);
	setInterval(persistState, 30_000);
}

function main() {
	if (command === "status") {
		connectObserver();
		startGithubPolling();
		setTimeout(() => {
			process.stdout.write(`${JSON.stringify(inboxPayload(), null, 2)}\n`, () => process.exit(0));
		}, 8000);
		return;
	}
	const wowRoot = resolveWowRoot();
	if (command === "install") {
		install(wowRoot);
		return;
	}
	printBanner();
	if (!existsSync(join(wowRoot, "Interface", "AddOns", ADDON_NAME))) install(wowRoot);
	log(`WoW: ${wowRoot}`);
	connectObserver();
	startWorkspaceRefresh();
	startGithubPolling();
	watchSavedVariables(wowRoot);
	setInterval(() => watchSavedVariables(wowRoot), 10_000);
	setInterval(() => {
		if (!dirty) return;
		dirty = false;
		try {
			writeInbox(wowRoot);
		} catch (error) {
			log(`Couldn't write the inbox: ${error.message}`);
		}
	}, 1500);
	// Keep "scouted N seconds ago" honest even when nothing changes.
	setInterval(() => {
		dirty = true;
	}, 30_000);
	const shutdown = () => {
		connected = false;
		try {
			writeInbox(wowRoot);
		} catch {}
		for (const f of watched) unwatchFile(f);
		process.exit(0);
	};
	process.on("SIGINT", shutdown);
	process.on("SIGTERM", shutdown);
}

main();
