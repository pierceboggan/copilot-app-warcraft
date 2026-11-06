// Minimal Lua literal reader/writer for WoW SavedVariables files.

export function parseSavedVariables(source) {
	const result = {};
	const p = new Parser(source);
	p.skip();
	while (!p.done()) {
		const name = p.identifier();
		p.skip();
		p.expect("=");
		result[name] = p.value();
		p.skip();
	}
	return result;
}

class Parser {
	constructor(src) {
		this.src = src;
		this.i = 0;
	}
	done() {
		return this.i >= this.src.length;
	}
	peek() {
		return this.src[this.i];
	}
	skip() {
		for (;;) {
			while (!this.done() && /\s|;|,/.test(this.peek())) this.i++;
			if (this.src.startsWith("--", this.i)) {
				const nl = this.src.indexOf("\n", this.i);
				this.i = nl === -1 ? this.src.length : nl + 1;
				continue;
			}
			return;
		}
	}
	expect(ch) {
		if (this.peek() !== ch) {
			throw new Error(`Expected "${ch}" at ${this.i}, found "${this.peek()}"`);
		}
		this.i++;
	}
	identifier() {
		const m = /^[A-Za-z_][A-Za-z0-9_]*/.exec(this.src.slice(this.i, this.i + 256));
		if (!m) throw new Error(`Expected identifier at ${this.i}`);
		this.i += m[0].length;
		return m[0];
	}
	value() {
		this.skip();
		const ch = this.peek();
		if (ch === "{") return this.table();
		if (ch === '"' || ch === "'") return this.string();
		if (this.src.startsWith("[[", this.i) || this.src.startsWith("[=", this.i)) {
			return this.longString();
		}
		const word = /^(true|false|nil)\b/.exec(this.src.slice(this.i, this.i + 5));
		if (word) {
			this.i += word[0].length;
			return word[0] === "true" ? true : word[0] === "false" ? false : null;
		}
		const num = /^-?(0x[0-9a-fA-F]+|\d+\.?\d*(e[+-]?\d+)?|\.\d+|inf|nan)/i.exec(
			this.src.slice(this.i, this.i + 64),
		);
		if (num) {
			this.i += num[0].length;
			return Number(num[0]);
		}
		throw new Error(`Unexpected "${ch}" at ${this.i}`);
	}
	// Lua strings are byte strings: collect bytes, then decode UTF-8 once.
	string() {
		const quote = this.peek();
		this.i++;
		const bytes = [];
		const pushText = (text) => {
			for (const b of Buffer.from(text, "utf8")) bytes.push(b);
		};
		while (!this.done()) {
			const ch = this.src[this.i++];
			if (ch === quote) return Buffer.from(bytes).toString("utf8");
			if (ch !== "\\") {
				pushText(ch);
				continue;
			}
			const esc = this.src[this.i++];
			const simple = { n: 10, t: 9, r: 13, a: 7, b: 8, f: 12, v: 11 };
			if (esc in simple) bytes.push(simple[esc]);
			else if (esc === "\n") bytes.push(10);
			else if (/\d/.test(esc)) {
				let digits = esc;
				while (digits.length < 3 && /\d/.test(this.peek())) digits += this.src[this.i++];
				bytes.push(Number(digits) & 0xff);
			} else pushText(esc);
		}
		throw new Error("Unterminated string");
	}
	longString() {
		const m = /^\[(=*)\[/.exec(this.src.slice(this.i, this.i + 64));
		const close = `]${m[1]}]`;
		const start = this.i + m[0].length;
		const end = this.src.indexOf(close, start);
		this.i = end + close.length;
		return this.src.slice(start, end).replace(/^\n/, "");
	}
	table() {
		this.expect("{");
		const entries = [];
		let arrayIndex = 1;
		let isArray = true;
		for (;;) {
			this.skip();
			if (this.peek() === "}") {
				this.i++;
				break;
			}
			let key;
			if (this.peek() === "[" && !this.src.startsWith("[[", this.i)) {
				this.i++;
				key = this.value();
				this.skip();
				this.expect("]");
				this.skip();
				this.expect("=");
			} else {
				const save = this.i;
				const ident = /^[A-Za-z_][A-Za-z0-9_]*\s*=/.exec(this.src.slice(this.i, this.i + 256));
				if (ident && !/^(true|false|nil)\s*=/.test(ident[0])) {
					key = this.identifier();
					this.skip();
					this.expect("=");
				} else {
					this.i = save;
					key = arrayIndex++;
				}
			}
			if (typeof key !== "number") isArray = false;
			entries.push([key, this.value()]);
		}
		if (isArray) {
			const arr = [];
			for (const [k, v] of entries) arr[k - 1] = v;
			return arr;
		}
		return Object.fromEntries(entries);
	}
}

// WoW's default fonts can't draw emoji or most symbols; keep text renderable.
export function sanitizeForWow(text, maxLength = 1200) {
	if (typeof text !== "string") return "";
	let clean = text
		.replace(/\r\n?/g, "\n")
		.replace(/```[a-z]*\n?/gi, "")
		.replace(/\*\*(.+?)\*\*/g, "$1")
		.replace(/`([^`]+)`/g, "$1")
		.replace(/\[([^\]]+)\]\([^)]+\)/g, "$1")
		.replace(/[\u2018\u2019]/g, "'")
		.replace(/[\u201C\u201D]/g, '"')
		.replace(/[\u2013\u2014]/g, "-")
		.replace(/\u2026/g, "...")
		.replace(/[\u2022\u25CF]/g, "*")
		.replace(/[^\x09\x0A\x20-\x7E\u00A0-\u024F]/g, "")
		.replace(/\|/g, "||")
		.replace(/\n{3,}/g, "\n\n")
		.trim();
	if (clean.length > maxLength) clean = `${clean.slice(0, maxLength - 3).trimEnd()}...`;
	return clean;
}

export function toLua(value, indent = "") {
	if (value === null || value === undefined) return "nil";
	if (typeof value === "boolean") return value ? "true" : "false";
	if (typeof value === "number") return Number.isFinite(value) ? String(value) : "0";
	if (typeof value === "string") return luaString(value);
	const inner = `${indent}\t`;
	if (Array.isArray(value)) {
		if (value.length === 0) return "{}";
		return `{\n${value.map((v) => `${inner}${toLua(v, inner)},`).join("\n")}\n${indent}}`;
	}
	const keys = Object.keys(value).filter((k) => value[k] !== undefined && value[k] !== null);
	if (keys.length === 0) return "{}";
	return `{\n${keys.map((k) => `${inner}[${luaString(k)}] = ${toLua(value[k], inner)},`).join("\n")}\n${indent}}`;
}

function luaString(s) {
	let out = '"';
	for (const ch of s) {
		const code = ch.codePointAt(0);
		// Always three digits: "\9" followed by "10" would otherwise read as "\910".
		const byteEscape = (b) => `\\${String(b).padStart(3, "0")}`;
		if (ch === '"') out += '\\"';
		else if (ch === "\\") out += "\\\\";
		else if (ch === "\n") out += "\\n";
		else if (code < 32 || code === 127) out += byteEscape(code);
		else if (code < 128) out += ch;
		else for (const byte of Buffer.from(ch, "utf8")) out += byteEscape(byte);
	}
	return `${out}"`;
}
