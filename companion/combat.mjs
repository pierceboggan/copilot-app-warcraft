// Turns tool calls into a WoW-style combat log.
import { basename } from "node:path";
import { sanitizeForWow } from "./lua.mjs";

const SCHOOL = {
	physical: "ffff00",
	holy: "ffe680",
	fire: "ff8000",
	nature: "4dff4d",
	frost: "80ffff",
	shadow: "a080ff",
	arcane: "ff80ff",
};

const SPELLS = {
	bash: ["Shell Shock", "fire"],
	powershell: ["Shell Shock", "fire"],
	shell: ["Shell Shock", "fire"],
	view: ["Far Sight", "arcane"],
	read: ["Far Sight", "arcane"],
	edit: ["Transmute", "nature"],
	apply_patch: ["Transmute", "nature"],
	str_replace_editor: ["Transmute", "nature"],
	create: ["Conjure File", "arcane"],
	grep: ["Detect Magic", "arcane"],
	rg: ["Detect Magic", "arcane"],
	glob: ["Track Files", "physical"],
	task: ["Summon Minion", "shadow"],
	read_agent: ["Commune", "holy"],
	write_agent: ["Whisper", "holy"],
	web_fetch: ["Mind Vision", "shadow"],
	web_search: ["Scrying", "frost"],
	sql: ["Rune Strike", "frost"],
	ask_user: ["Call for Aid", "holy"],
	store_memory: ["Tome of Knowledge", "holy"],
	send_session_message: ["Sending", "holy"],
	report_intent: ["Battle Shout", "physical"],
};

function spellFor(tool) {
	const known = SPELLS[tool];
	if (known) return known;
	const pretty = String(tool || "Mystery")
		.replace(/^[a-z0-9-]+-/i, "")
		.split(/[_-]/)
		.map((w) => w.charAt(0).toUpperCase() + w.slice(1))
		.join(" ");
	return [pretty, "physical"];
}

function targetFor(args) {
	if (!args || typeof args !== "object") return "";
	if (args.path) return basename(String(args.path));
	if (args.pattern) return `"${String(args.pattern).slice(0, 24)}"`;
	if (args.command) {
		const words = String(args.command).split(/\s+/).filter((w) => w && !/^[A-Z_]+=/.test(w));
		return (words[0] ?? "").slice(0, 24);
	}
	if (args.url) {
		try {
			return new URL(args.url).hostname;
		} catch {
			return "";
		}
	}
	if (args.query) return `"${String(args.query).slice(0, 24)}"`;
	if (args.description) return String(args.description).slice(0, 24);
	return "";
}

const color = (hex, text) => `|cff${hex}${text}|r`;

export class CombatLog {
	constructor(entries = []) {
		this.entries = entries;
		this.pending = new Map();
	}

	push(text) {
		const last = this.entries[this.entries.length - 1];
		const now = Math.floor(Date.now() / 1000);
		if (last && last.text === text && now - last.t < 5) return;
		this.entries.push({ t: now, text });
		if (this.entries.length > 120) this.entries.splice(0, this.entries.length - 120);
	}

	// Returns true when the log changed.
	onEvent(session, ev) {
		const who = color("ffd100", sanitizeForWow(session.name, 40));
		switch (ev.type) {
			case "tool.execution_start": {
				const id = ev.data?.toolCallId;
				if (id) this.pending.set(id, { tool: ev.data.toolName, args: ev.data.arguments, at: Date.now() });
				if (this.pending.size > 500) this.pending.delete(this.pending.keys().next().value);
				return false;
			}
			case "tool.execution_complete": {
				const call = this.pending.get(ev.data?.toolCallId);
				if (!call) return false;
				this.pending.delete(ev.data.toolCallId);
				const [spell, school] = spellFor(call.tool);
				const spellText = color(SCHOOL[school], spell);
				const target = sanitizeForWow(targetFor(call.args), 30);
				const on = target ? ` ${target}` : "";
				if (ev.data.success === false) {
					this.push(`${who}'s ${spellText} misses${on}.`);
				} else {
					const result = ev.data.result?.content ?? ev.data.result?.detailedContent ?? "";
					const dmg = Math.max(1, String(result).length);
					const crit = dmg > 8000 ? color("ff2020", " (Critical)") : "";
					this.push(`${who}'s ${spellText} hits${on || " the codebase"} for ${dmg}.${crit}`);
				}
				return true;
			}
			case "user.message":
				this.push(`${who} gains ${color("7ee787", "[Orders]")}.`);
				return true;
			case "session.idle":
				this.push(`${who} leaves combat.`);
				return true;
			case "abort":
				this.push(`${who}'s cast is ${color("ff8000", "interrupted")}.`);
				return true;
			case "session.error":
				this.push(`${who} ${color("ff2020", "dies")}.`);
				return true;
			case "subagent.started":
				this.push(`${who} summons a ${color(SCHOOL.shadow, "minion")}.`);
				return true;
			default:
				return false;
		}
	}
}
