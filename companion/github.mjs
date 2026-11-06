// Loot (merged PRs) and raid bosses (open PRs with failing CI), via the gh CLI.
import { execFile } from "node:child_process";
import { sanitizeForWow } from "./lua.mjs";

const QUERY = `query {
  viewer {
    merged: pullRequests(states: MERGED, first: 40, orderBy: {field: UPDATED_AT, direction: DESC}) {
      nodes { id number title url mergedAt additions deletions changedFiles repository { nameWithOwner } }
    }
    open: pullRequests(states: OPEN, first: 40, orderBy: {field: UPDATED_AT, direction: DESC}) {
      nodes { id number title url headRefName isDraft repository { nameWithOwner }
        commits(last: 1) { nodes { commit { statusCheckRollup { state contexts(first: 100) {
          nodes { __typename ... on CheckRun { name status conclusion } ... on StatusContext { context state } } } } } } } }
    }
  }
}`;

const EPITHETS = [
	"the Red Build",
	"Breaker of Main",
	"the Flaky",
	"Devourer of Minutes",
	"the Unmergeable",
	"Herald of Rebase",
	"the Timeout King",
	"Warden of the Pipeline",
];

const FAILED = new Set(["FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE", "ERROR"]);
const PASSED = new Set(["SUCCESS", "NEUTRAL", "SKIPPED"]);

function hash(text) {
	let h = 0;
	for (const ch of text) h = (h * 31 + ch.charCodeAt(0)) >>> 0;
	return h;
}

function ghGraphql() {
	return new Promise((resolve, reject) => {
		execFile("gh", ["api", "graphql", "-f", `query=${QUERY}`], { maxBuffer: 32 * 1024 * 1024 }, (error, stdout) => {
			if (error) reject(error);
			else resolve(JSON.parse(stdout).data.viewer);
		});
	});
}

function checkOutcome(ctx) {
	if (ctx.__typename === "StatusContext") {
		if (ctx.state === "SUCCESS") return "pass";
		if (ctx.state === "PENDING" || ctx.state === "EXPECTED") return "pending";
		return "fail";
	}
	if (ctx.status !== "COMPLETED") return "pending";
	if (FAILED.has(ctx.conclusion)) return "fail";
	if (PASSED.has(ctx.conclusion)) return "pass";
	return "pending";
}

export async function fetchGithub(state) {
	const viewer = await ghGraphql();
	const loot = viewer.merged.nodes.map((pr) => ({
		id: pr.id,
		number: pr.number,
		repo: pr.repository.nameWithOwner,
		title: sanitizeForWow(pr.title, 90),
		mergedAt: Math.floor(Date.parse(pr.mergedAt) / 1000),
		additions: pr.additions,
		deletions: pr.deletions,
		files: pr.changedFiles,
		seed: hash(pr.id) % 1000,
	}));

	state.bossesSeenFailing ??= {};
	state.defeated ??= [];
	const bosses = [];
	const stillOpen = new Set();
	for (const pr of viewer.open.nodes) {
		stillOpen.add(pr.id);
		const contexts = pr.commits.nodes[0]?.commit.statusCheckRollup?.contexts.nodes ?? [];
		let pass = 0;
		let pending = 0;
		const failing = [];
		for (const ctx of contexts) {
			const outcome = checkOutcome(ctx);
			if (outcome === "pass") pass++;
			else if (outcome === "pending") pending++;
			else failing.push(sanitizeForWow(ctx.name ?? ctx.context ?? "check", 50));
		}
		const name = `${sanitizeForWow(pr.title, 60)}, ${EPITHETS[hash(pr.id) % EPITHETS.length]}`;
		if (failing.length > 0) {
			state.bossesSeenFailing[pr.id] = { name, number: pr.number, repo: pr.repository.nameWithOwner };
			bosses.push({
				id: pr.id,
				name,
				number: pr.number,
				repo: pr.repository.nameWithOwner,
				branch: pr.headRefName,
				total: contexts.length,
				passed: pass,
				pending,
				failing,
				draft: pr.isDraft || undefined,
			});
		} else if (state.bossesSeenFailing[pr.id] && pending === 0) {
			defeat(state, pr.id);
		}
	}
	// A failing PR that got merged also counts as a kill.
	const mergedIds = new Set(viewer.merged.nodes.map((pr) => pr.id));
	for (const id of Object.keys(state.bossesSeenFailing)) {
		if (!stillOpen.has(id) && mergedIds.has(id)) defeat(state, id);
		else if (!stillOpen.has(id)) delete state.bossesSeenFailing[id];
	}
	return { loot, bosses };
}

function defeat(state, id) {
	const boss = state.bossesSeenFailing[id];
	delete state.bossesSeenFailing[id];
	state.defeated.unshift({ id: `${id}-${Date.now()}`, name: boss.name, number: boss.number, repo: boss.repo, at: Math.floor(Date.now() / 1000) });
	state.defeated = state.defeated.slice(0, 30);
}
